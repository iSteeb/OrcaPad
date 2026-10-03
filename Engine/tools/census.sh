#!/usr/bin/env bash
# Census compile: attempts each candidate file INDEPENDENTLY with the engine's
# exact flags and reports the FULL error surface in one pass. No archive, no
# build — pure recon. Fixes then land in build-core.sh in one batch.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/upstream/orcaslicer/src"
DEPS="$ROOT/upstream/orcaslicer/deps_src"
SDK="${SDK:-$HOME/.config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk}"
CLANG="${CLANG:-$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin/clang++}"
TARGET="arm64-apple-ios17.0"
BUILD="$ROOT/Engine/build-ios"
WORK="$(mktemp -d)"

CFLAGS=(
    -target "$TARGET" -isysroot "$SDK"
    -std=c++17 -O1 -Wno-deprecated-declarations -fsyntax-only
    -I"$ROOT/Engine/shim" -I"$ROOT/Engine/shim/occt-stub"
    -I"$SRC" -I"$SRC/libslic3r" -I"$BUILD/gen"
    -I"$DEPS" -I"$DEPS/admesh" -I"$DEPS/qhull/src" -I"$DEPS/glu-libtess/include" -I"$DEPS/libigl" -I"$ROOT/Engine/cache/Orca-deps-libnoise/src" -I"$DEPS/libnest2d/include" -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat/expat/lib" -I"$DEPS/miniz"
    -I"$DEPS/expat/expat/lib" -I"$DEPS/miniz"
    -I"$ROOT/Engine/engine-cxx"
    -DSLIC3R_APP_KEY='"OrcaSlicer"' -DSLIC3R_APP_NAME='"OrcaSlicer"'
)

pass=0; fail=0; failed_files=()
for f in "$@"; do
    err="$("$CLANG" "${CFLAGS[@]}" "$f" 2>&1)"
    if [ $? -eq 0 ]; then
        pass=$((pass+1))
    else
        fail=$((fail+1)); failed_files+=("$f")
        echo "──────── FAIL: $f"
        echo "$err" | grep -E "error:" | head -3 | sed 's/^/    /'
    fi
done
echo ""
echo "═══ CENSUS: $pass pass, $fail fail ═══"
for f in "${failed_files[@]:-}"; do [ -n "$f" ] && echo "  $f"; done
rm -rf "$WORK"
