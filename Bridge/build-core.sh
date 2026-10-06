#!/usr/bin/env bash
# Cross-builds OrcaBridgeCore (untouched libslic3r sources + the C++ Bridge)
# for iOS arm64 from Linux and packs a hand-rolled xcframework under Prebuilt/.
# This machine-local build is temporary; ARCHITECTURE.md defines the boundary.
#
# Sources of truth:
#   upstream/orcaslicer          git submodule, tag v2.4.2 (never patched)
#   Bridge/engine-cxx/           C++ Bridge boundary (orca_bridge.*)
#   Bridge/shim/                 temporary platform/dependency adapters

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/upstream/orcaslicer/src"
DEPS="$ROOT/upstream/orcaslicer/deps_src"
SDK="${SDK:-$HOME/.config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk}"
CLANG="${CLANG:-$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin/clang++}"
TARGET="arm64-apple-ios17.0"

source "$ROOT/Bridge/engine-sources.sh"

BUILD="$ROOT/Bridge/build-ios"
OUT="$ROOT/Prebuilt/OrcaBridgeCore.xcframework/ios-arm64"
# INCREMENTAL: obj/ persists across runs; see needs_build + flags stamp.
mkdir -p "$BUILD/gen/libslic3r" "$BUILD/obj" "$OUT/Headers"

CFLAGS=(
    -target "$TARGET" -isysroot "$SDK"
    -std=c++17 -O2 -DNDEBUG -Wno-deprecated-declarations
    # ORDER MATTERS: shims FIRST so adapter headers (boost/log, boost/nowide,
    # tbb, openssl, occt) win over symlinked real boost headers in gen/.
    -I"$ROOT/Bridge/shim" -I"$ROOT/Bridge/shim/occt-stub"
    -I"$SRC" -I"$SRC/libslic3r" -I"$BUILD/gen"
    -I"$DEPS" -I"$DEPS/admesh"
    -I"$DEPS/qhull/src"
    -I"$DEPS/glu-libtess/include"
    -I"$DEPS/libigl" -I"$ROOT/Bridge/cache/Orca-deps-libnoise/src"
    -I"$DEPS/libnest2d/include"
    -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat/expat/lib"
    -I"$DEPS/miniz"
    -I"$ROOT/Bridge/engine-cxx"
    -DSLIC3R_APP_KEY='"OrcaSlicer"' -DSLIC3R_APP_NAME='"OrcaSlicer"'
)
CONLY_FLAGS=(
    -target "$TARGET" -isysroot "$SDK"
    -O2 -DNDEBUG -Wno-deprecated-declarations
    -include limits.h
    -I"$DEPS" -I"$DEPS/qhull/src" -I"$DEPS/glu-libtess/include"
    -I"$DEPS/libigl" -I"$ROOT/Bridge/cache/Orca-deps-libnoise/src"
    -I"$DEPS/libnest2d/include"
    -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat/expat/lib"
    -I"$DEPS/miniz"
)

# Host boost/eigen + fetched cereal headers exposed via symlinks (NEVER
# -I/usr/include — glibc headers must not shadow the Darwin SDK).
CEREAL="$ROOT/Bridge/cache/cereal/include/cereal"
if [ ! -f "$CEREAL/access.hpp" ]; then
    echo "==> fetching cereal v1.3.0 (OrcaSlicer's pin) into Bridge/cache/" >&2
    mkdir -p "$ROOT/Bridge/cache"
    git clone -q --depth 1 -b v1.3.0 https://github.com/USCiLab/cereal "$ROOT/Bridge/cache/cereal"
fi
[ -f "$CEREAL/access.hpp" ] || { echo "FATAL: cereal fetch failed" >&2; exit 1; }
ln -sfn /usr/include/boost "$BUILD/gen/boost"
ln -sfn /usr/include/eigen3/Eigen "$BUILD/gen/Eigen"
ln -sfn /usr/include/eigen3/unsupported "$BUILD/gen/unsupported"
ln -sfn "$CEREAL" "$BUILD/gen/cereal"
ln -sfn /usr/include/CGAL "$BUILD/gen/CGAL"
ln -sfn "$ROOT/Bridge/cache/Orca-deps-libnoise/src" "$BUILD/gen/libnoise"
ln -sfn /usr/include/x86_64-linux-gnu/gmp.h "$BUILD/gen/gmp.h"
ln -sfn /usr/include/x86_64-linux-gnu/mpfr.h "$BUILD/gen/mpfr.h"

# --- 1. generated version header (normally done by CMake configure) ---
# Written to BOTH locations: bare name (same-dir include style) and
# prefixed (libslic3r/... include style). Content-conditional write so the
# mtime (and thus incremental rebuilds) stay stable across no-op runs.
for vpath in "$BUILD/gen/libslic3r_version.h" "$BUILD/gen/libslic3r/libslic3r_version.h"; do
    sed -e 's/@SLIC3R_VERSION@/2.4.2/g' \
        -e 's/@SoftFever_VERSION@/2.4.2/g' \
        -e 's/@SLIC3R_BUILD_ID@/OrcaPad-2.4.2/g' \
        -e 's/@SLIC3R_APP_KEY@/OrcaSlicer/g' \
        -e 's/@SLIC3R_APP_NAME@/OrcaSlicer/g' \
        -e 's/@BBL_INTERNAL_TESTING@/0/g' \
        -e 's/@ORCA_CHECK_GCODE_PLACEHOLDERS@/0/g' \
        "$SRC/libslic3r/libslic3r_version.h.in" > "$vpath.tmp"
    if [ ! -f "$vpath" ] || ! cmp -s "$vpath.tmp" "$vpath"; then mv "$vpath.tmp" "$vpath"; else rm -f "$vpath.tmp"; fi
done

# --- 2. incremental compile machinery ---
OBJ="$BUILD/obj"
MANIFEST="$BUILD/objects.txt"
: > "$MANIFEST"

# Flags stamp: toolchain/flag changes force a full rebuild.
FLAGS_HASH="$(printf '%s\n' "${CFLAGS[@]}" "${CONLY_FLAGS[@]}" "$CLANG" "$SDK" | sha256sum | cut -c1-16)"
if [ -f "$BUILD/flags.sha" ] && [ "$(cat "$BUILD/flags.sha")" != "$FLAGS_HASH" ]; then
    echo "==> flags/toolchain changed — full rebuild" >&2
    rm -rf "$OBJ"
fi
mkdir -p "$OBJ"
echo "$FLAGS_HASH" > "$BUILD/flags.sha"

needs_build() { # needs_build <src> <obj> — true if recompile required
    local src="$1" o="$2"
    [ -f "$o" ] || return 0
    [ "$src" -nt "$o" ] && return 0
    local d="$o.d" p
    [ -f "$d" ] || return 0   # no depfile → conservative rebuild
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -e "$p" ] && [ "$p" -nt "$o" ] && return 0
    done < <(sed '1s/[^:]*://' "$d" | tr '\\ ' '\n\n' | sed '/^$/d')
    return 1                    # NOTE: paths with spaces unsupported (none here)
}

JOBS="$BUILD/jobs.sh"
PENDING_OBJS="$BUILD/pending-objs.txt"
: > "$JOBS"
: > "$PENDING_OBJS"
PENDING=0
declare -A SEEN_OBJS=()

compile_one() { # compile_one <src> <obj> <compiler+flags...>
    # Phase 1: record the command; execution is parallel (phase 2, below).
    local src="$1" o="$2"; shift 2
    if [[ -n "${SEEN_OBJS[$o]+present}" ]]; then
        echo "FATAL: duplicate compile source maps to $o" >&2
        exit 1
    fi
    SEEN_OBJS[$o]=1
    if needs_build "$src" "$o"; then
        {
            printf '%q ' "$@" -MD -MF "$o.d" -c "$src" -o "$o"
            printf ' 2>%q\n' "$o.err"
        } >> "$JOBS"
        echo "$o" >> "$PENDING_OBJS"
        PENDING=$((PENDING + 1))
    fi
    echo "$o" >> "$MANIFEST"
}

run_jobs_parallel() { # phase 2: bounded-parallel compile + hard verification
    [ "$PENDING" -gt 0 ] || return 0
    # 2026-10-03: 12 parallel clang++ jobs on this 14-core/14GiB box OOMed
    # into swap during the CGAL/Eigen-heavy rebuild and froze the machine
    # (a pi session died mid-build). Keep concurrency low + nice the jobs;
    # override for unattended runs with ORCAPAD_JOBS=N.
    local maxjobs="${ORCAPAD_JOBS:-6}"
    echo "==> compiling $PENDING files, $maxjobs parallel (niced)" >&2
    local p=0 job_failed=0
    while IFS= read -r cmd; do
        nice -n 15 bash -c "$cmd" &
        p=$((p + 1))
        if (( p >= maxjobs )); then
            if ! wait -n; then job_failed=1; fi
            p=$((p - 1))
        fi
    done < "$JOBS"
    while (( p > 0 )); do
        if ! wait -n; then job_failed=1; fi
        p=$((p - 1))
    done
    # hard verification: every pending .o must exist; every .err must be empty
    # 2026-10-03: parsing "-o <path>" back out of the %q-quoted job line left a
    # trailing space ("path.o  2>…"), so [ -f "$o" ] failed on GOOD builds —
    # phantom "FAILED (no object)" on freshly compiled objects. Object paths
    # are recorded directly at enqueue time now; zero string surgery.
    local failed=0 o
    while IFS= read -r o; do
        [ -n "$o" ] || continue
        if [ ! -f "$o" ]; then
            echo "FAILED (no object): ${o}" >&2; head -8 "${o}.err" 2>/dev/null >&2; failed=1
        elif grep -q ' error:' "${o}.err" 2>/dev/null; then
            echo "FAILED (compiler error): ${o}" >&2; grep -m8 ' error:' "${o}.err" >&2; failed=1
        else
            rm -f "${o}.err"
        fi
    done < "$PENDING_OBJS"
    [ "$failed" -eq 0 ] && [ "$job_failed" -eq 0 ] || exit 1
}

# --- 2b. compile the shared engine source list ---
# Single source of truth: Bridge/engine-sources.sh (shared verbatim with the
# host contract-test build — lists must never drift apart again).
# Records: cxx<TAB>path<TAB>[extra flags...] | c<TAB>path
while IFS=$'\t' read -r kind src extra_str; do
    [ -n "${src:-}" ] || continue
    extra_args=()
    [ -n "${extra_str:-}" ] && read -ra extra_args <<< "$extra_str"
    o="$OBJ/$(echo "$src" | sed 's|/|_|g').o"
    if [ "$kind" = "cxx" ]; then
        compile_one "$src" "$o" "$CLANG" "${CFLAGS[@]}" "${extra_args[@]}"
    else
        compile_one "$src" "$o" "${CLANG%++}" "${CONLY_FLAGS[@]}"
    fi
done < <(engine_sources)

run_jobs_parallel

# --- 3. archive + xcframework ---
mapfile -t OBJS < "$MANIFEST"
if [ "${#OBJS[@]}" -eq 0 ]; then echo "FATAL: no objects compiled" >&2; exit 1; fi
# CRITICAL: ar rcs only replaces/adds members — stale members from previous
# builds survive exclusions. Always start from a clean archive.
rm -f "$OUT/libOrcaBridgeCore.a"
ar rcs "$OUT/libOrcaBridgeCore.a" "${OBJS[@]}"
actual=$(ar t "$OUT/libOrcaBridgeCore.a" | wc -l)
if [ "$actual" -ne "${#OBJS[@]}" ]; then
    echo "FATAL: archive has $actual members, manifest has ${#OBJS[@]} — stale members leaked" >&2; exit 1
fi
cp "$ROOT/Bridge/engine-cxx/orca_bridge.h" "$OUT/Headers/orca_bridge.h"
cat > "$OUT/Headers/module.modulemap" <<'EOF'
module OrcaBridgeCore {
    header "orca_bridge.h"
    export *
}
EOF
file "$OUT/libOrcaBridgeCore.a"
echo "==> done: $OUT/libOrcaBridgeCore.a ($(wc -l < "$MANIFEST") objects)"
