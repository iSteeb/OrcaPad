#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
# Host-side Bridge contract tests: compiles the SAME engine closure as
# build-core.sh (via Bridge/engine-sources.sh) for the local Linux host,
# links Bridge/tools/contract_tests.cpp, and RUNS the resulting executable.
#
# Differences from the iOS archive build:
#   - no -target/-isysroot (native host toolchain, glibc)
#   - Bridge/shim-host is on the include path FIRST (host md5 override)
#   - links archive-style (mirrors iOS member-pull semantics)
#   - -O2 -DNDEBUG mirrors the SHIPPED archive exactly: upstream GCode.hpp
#     enables extra placeholder validation in debug builds that even
#     upstream's own bundled presets fail — contract tests verify the
#     production configuration, not upstream's debug-mode quirks.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/upstream/orcaslicer/src"
DEPS="$ROOT/upstream/orcaslicer/deps_src"
CXX="${CXX:-$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin/clang++}"
BUILD="$ROOT/Bridge/build-host"
OUT="$BUILD/contract_tests"
mkdir -p "$BUILD/gen/libslic3r" "$BUILD/obj"

CFLAGS=(
    -std=c++17 -O2 -DNDEBUG -Wno-deprecated-declarations
    # ORDER MATTERS: shim-host FIRST (host md5 override), then the shared
    # platform shims (boost/log, boost/nowide, tbb, occt stub).
    -I"$ROOT/Bridge/shim-host"
    -I"$ROOT/Bridge/shim" -I"$ROOT/Bridge/shim/occt-stub"
    -I"$SRC" -I"$SRC/libslic3r" -I"$BUILD/gen"
    -I"$DEPS" -I"$DEPS/admesh"
    -I"$DEPS/qhull/src"
    -I"$DEPS/glu-libtess/include"
    -I"$DEPS/libigl" -I"$ROOT/Bridge/cache/Orca-deps-libnoise/src"
    -I"$DEPS/libnest2d/include"
    -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat"
    -I"$DEPS/miniz"
    -I"$ROOT/Bridge/cache/cereal/include"
    -I/usr/include/eigen3
    -I"$ROOT/Bridge/engine-cxx"
    -DSLIC3R_APP_KEY='"OrcaSlicer"' -DSLIC3R_APP_NAME='"OrcaSlicer"'
)
CONLY_FLAGS=(
    -O2 -DNDEBUG -Wno-deprecated-declarations
    -include limits.h
    -I"$DEPS" -I"$DEPS/qhull/src" -I"$DEPS/glu-libtess/include"
    -I"$DEPS/libigl" -I"$ROOT/Bridge/cache/Orca-deps-libnoise/src"
    -I"$DEPS/libnest2d/include"
    -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat"
    -I"$DEPS/miniz"
)

# fetched cereal headers (same fetch guard as build-core.sh)
CEREAL="$ROOT/Bridge/cache/cereal/include/cereal"
if [ ! -f "$CEREAL/access.hpp" ]; then
    echo "==> fetching cereal v1.3.0 into Bridge/cache/" >&2
    mkdir -p "$ROOT/Bridge/cache"
    git clone -q --depth 1 -b v1.3.0 https://github.com/USCiLab/cereal "$ROOT/Bridge/cache/cereal"
fi
[ -f "$CEREAL/access.hpp" ] || { echo "FATAL: cereal fetch failed" >&2; exit 1; }

# --- generated version header (same content as the iOS build) ---
# libnoise is addressed as <libnoise/noise.h> (iOS build exposes it via the
# gen/ symlink tree; mirror that here).
ln -sfn "$ROOT/Bridge/cache/Orca-deps-libnoise/src" "$BUILD/gen/libnoise"
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

# --- incremental compile machinery (mirrors build-core.sh) ---
OBJ="$BUILD/obj"
MANIFEST="$BUILD/objects.txt"
: > "$MANIFEST"

FLAGS_HASH="$(printf '%s\n' "${CFLAGS[@]}" "${CONLY_FLAGS[@]}" "$CXX" | sha256sum | cut -c1-16)"
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
    [ -f "$d" ] || return 0
    while IFS= read -r p; do
        [ -z "$p" ] && continue
        [ -e "$p" ] && [ "$p" -nt "$o" ] && return 0
    done < <(sed '1s/[^:]*://' "$d" | tr '\\ ' '\n\n' | sed '/^$/d')
    return 1
}

JOBS="$BUILD/jobs.sh"
PENDING_OBJS="$BUILD/pending-objs.txt"
: > "$JOBS"
: > "$PENDING_OBJS"
PENDING=0
declare -A SEEN_OBJS=()

compile_one() { # compile_one <src> <obj> <compiler+flags...>
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

run_jobs_parallel() {
    [ "$PENDING" -gt 0 ] || return 0
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
    return 0
}

source "$ROOT/Bridge/engine-sources.sh"
engine_fetch_deps

while IFS=$'\t' read -r kind src extra_str; do
    [ -n "${src:-}" ] || continue
    extra_args=()
    [ -n "${extra_str:-}" ] && read -ra extra_args <<< "$extra_str"
    o="$OBJ/$(echo "$src" | sed 's|/|_|g').o"
    if [ "$kind" = "cxx" ]; then
        compile_one "$src" "$o" "$CXX" "${CFLAGS[@]}" "${extra_args[@]}"
    else
        compile_one "$src" "$o" "${CXX%++}" "${CONLY_FLAGS[@]}" "${extra_args[@]}"
    fi
done < <(engine_sources)

# the contract test TU itself
compile_one "$ROOT/Bridge/tools/contract_tests.cpp" \
    "$OBJ/contract_tests.o" "$CXX" "${CFLAGS[@]}"

run_jobs_parallel

# --- link (archive-style, mirroring iOS member-pull semantics) ---
# A host executable links ALL raw objects, which surfaces undefined
# references inside archive members that iOS never pulls (dead TUs like
# Thread.cpp/FlushVolCalc.cpp). Packing objects into a static archive first
# reproduces the shipped behavior exactly: only referenced members are linked.
mapfile -t OBJS < <(grep -v 'contract_tests\.o$' "$MANIFEST")
[ "${#OBJS[@]}" -gt 0 ] || { echo "FATAL: no objects" >&2; exit 1; }
HOST_ARCHIVE="$BUILD/libengine-host.a"
rm -f "$HOST_ARCHIVE"
ar rcs "$HOST_ARCHIVE" "${OBJS[@]}"
"$CXX" -o "$OUT" "$OBJ/contract_tests.o" "$HOST_ARCHIVE" \
    -lpthread -lm -lgmp -lmpfr -latomic
file "$OUT"

# --- run ---
export ORCAPAD_TEST_PROFILES_DIR="$ROOT/upstream/orcaslicer/resources/profiles"
echo "==> running contract tests" >&2
"$OUT"
