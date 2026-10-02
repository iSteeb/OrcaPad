#!/usr/bin/env bash
# Cross-builds the OrcaCore static library (libslic3r geometry subset +
# vendored admesh + vendored qhull) for iOS arm64 from Linux, packs it as a
# hand-rolled xcframework under Prebuilt/.
#
# Sources of truth:
#   upstream/orcaslicer          git submodule, tag v2.4.2 (never patched)
#   Engine/engine-cxx/           our C++ boundary (orca_core.*)
#   Engine/shim/                 adapter headers standing in for un-built libs
#
# Excluded upstream deps (not needed by this subset): CGAL, OpenCV, OCCT,
# draco, JPEG, freetype, OpenSSL, PNG, expat, TBB, cereal, boost-compiled.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SRC="$ROOT/upstream/orcaslicer/src"
DEPS="$ROOT/upstream/orcaslicer/deps_src"
SDK="${SDK:-$HOME/.config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk}"
CLANG="${CLANG:-$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin/clang++}"
TARGET="arm64-apple-ios17.0"

BUILD="$ROOT/Engine/build-ios"
OUT="$ROOT/Prebuilt/OrcaCore.xcframework/ios-arm64"
rm -rf "$BUILD"
mkdir -p "$BUILD/gen/libslic3r" "$BUILD/obj" "$OUT/Headers"

CFLAGS=(
    -target "$TARGET" -isysroot "$SDK"
    -std=c++17 -O2 -Wno-deprecated-declarations
    # ORDER MATTERS: shims FIRST so adapter headers (boost/log, boost/nowide,
    # tbb, openssl, occt) win over symlinked real boost headers in gen/.
    -I"$ROOT/Engine/shim" -I"$ROOT/Engine/shim/occt-stub"
    -I"$SRC" -I"$SRC/libslic3r" -I"$BUILD/gen"
    -I"$DEPS" -I"$DEPS/admesh"
    -I"$DEPS/qhull/src"
    -I"$DEPS/glu-libtess/include"
    -I"$ROOT/Engine/engine-cxx"
    -DSLIC3R_APP_KEY='"OrcaSlicer"' -DSLIC3R_APP_NAME='"OrcaSlicer"'
)
CONLY_FLAGS=(
    -target "$TARGET" -isysroot "$SDK"
    -O2 -Wno-deprecated-declarations
    -include limits.h
    -I"$DEPS" -I"$DEPS/qhull/src" -I"$DEPS/glu-libtess/include"
)

# Host boost/eigen + fetched cereal headers exposed via symlinks (NEVER
# -I/usr/include — glibc headers must not shadow the Darwin SDK).
CEREAL="$ROOT/Engine/cache/cereal/include/cereal"
if [ ! -f "$CEREAL/access.hpp" ]; then
    echo "FATAL: cereal cache missing — git clone USCiLab/cereal v1.3.0 into Engine/cache/" >&2; exit 1
fi
ln -sfn /usr/include/boost "$BUILD/gen/boost"
ln -sfn /usr/include/eigen3/Eigen "$BUILD/gen/Eigen"
ln -sfn /usr/include/eigen3/unsupported "$BUILD/gen/unsupported"
ln -sfn "$CEREAL" "$BUILD/gen/cereal"
ln -sfn /usr/include/CGAL "$BUILD/gen/CGAL"
ln -sfn /usr/include/x86_64-linux-gnu/gmp.h "$BUILD/gen/gmp.h"
ln -sfn /usr/include/x86_64-linux-gnu/mpfr.h "$BUILD/gen/mpfr.h"

# --- 1. generated version header (normally done by CMake configure) ---
# Written to BOTH locations: bare name (same-dir include style) and
# prefixed (libslic3r/... include style).
for vpath in "$BUILD/gen/libslic3r_version.h" "$BUILD/gen/libslic3r/libslic3r_version.h"; do
    sed -e 's/@SLIC3R_VERSION@/2.4.2/g' \
        -e 's/@SLIC3R_BUILD_ID@/OrcaPad-2.4.2/g' \
        -e 's/@SLIC3R_APP_KEY@/OrcaSlicer/g' \
        -e 's/@SLIC3R_APP_NAME@/OrcaSlicer/g' \
        -e 's/@BBL_INTERNAL_TESTING@/0/g' \
        -e 's/@ORCA_CHECK_GCODE_PLACEHOLDERS@/0/g' \
        "$SRC/libslic3r/libslic3r_version.h.in" > "$vpath"
done

# --- 2. compile sources ---
# Hard-fail semantics: a failed compile MUST abort the build (command
# substitution swallows exit codes; compile() exits explicitly instead).
OBJ="$BUILD/obj"
MANIFEST="$BUILD/objects.txt"
: > "$MANIFEST"

compile() { # compile <srcfile> (C++, extra flags after src)
    local src="$1"; shift
    local o="$OBJ/$(echo "$src" | sed 's|/|_|g').o"
    if ! "$CLANG" "${CFLAGS[@]}" "$@" -c "$src" -o "$o" 2>"$o.err"; then
        cat "$o.err" >&2; echo "FAILED: $src" >&2; exit 1
    fi
    rm -f "$o.err"
    echo "$o" >> "$MANIFEST"
}
compile_c() { # compile_c <srcfile> (C)
    local src="$1"
    local o="$OBJ/$(echo "$src" | sed 's|/|_|g').o"
    if ! "${CLANG%++}" "${CONLY_FLAGS[@]}" -c "$src" -o "$o" 2>"$o.err"; then
        cat "$o.err" >&2; echo "FAILED: $src" >&2; exit 1
    fi
    rm -f "$o.err"
    echo "$o" >> "$MANIFEST"
}

OBJS=()

# vendored admesh (mesh read/repair)
for f in connect normals shared stl_io stlinit util; do
    compile "$DEPS/admesh/$f.cpp"
done

# vendored qhull (convex hull): C core + C++ wrappers
for f in "$DEPS"/qhull/src/libqhull_r/*.c; do
    case "$f" in
        *userprintf_r.c) continue ;; # qh_fprintf also defined in libqhullcpp/QhullQh.cpp — keep exactly one
    esac
    compile_c "$f"
done
for f in "$DEPS"/qhull/src/libqhullcpp/*.cpp; do
    case "$f" in
        *qt-qhull.cpp) continue ;;          # Qt shim, not needed
        *userprintf_r-cpp.cpp) continue ;; # duplicates C qh_fprintf from libqhull_r
    esac
    # upstream quirk: usermem_r-cpp.cpp relies on transitive stdarg/stdio —
    # force-include instead of patching the vendored source
    compile "$f" -include stdarg.h -include stdio.h
done

# libslic3r geometry subset (grows link-error-driven)
for f in libslic3r.cpp Point.cpp Line.cpp MultiPoint.cpp Polygon.cpp Polyline.cpp \
         BoundingBox.cpp ExPolygon.cpp ClipperUtils.cpp clipper.cpp \
         Circle.cpp ArcFitter.cpp Geometry.cpp Geometry/ConvexHull.cpp \
         Geometry/MedialAxis.cpp Geometry/Voronoi.cpp Geometry/VoronoiUtils.cpp \
         Geometry/VoronoiUtilsCgal.cpp Geometry/VoronoiOffset.cpp ShortestPath.cpp \
         Tesselate.cpp ExtrusionEntity.cpp ExtrusionEntityCollection.cpp Flow.cpp \
         LocalesUtils.cpp TriangleMesh.cpp TriangleMeshSlicer.cpp Format/STL.cpp; do
    extra=()
    case "$f" in
        LocalesUtils.cpp) extra+=(-include sstream) ;; # upstream relies on transitive include
        Geometry/VoronoiUtilsCgal.cpp) extra+=(-include boost/multiprecision/gmp.hpp) ;; # CGAL CORE/BigInt needs full gmp_int, not fwd-decl
    esac
    compile "$SRC/libslic3r/$f" "${extra[@]:-}"
done

# vendored glu-libtess (triangulation backend for Tesselate.cpp)
for f in "$DEPS"/glu-libtess/src/*.c; do
    compile_c "$f"
done

# our C boundary
compile "$ROOT/Engine/engine-cxx/orca_core.cpp"

# --- 3. archive + xcframework ---
mapfile -t OBJS < "$MANIFEST"
if [ "${#OBJS[@]}" -eq 0 ]; then echo "FATAL: no objects compiled" >&2; exit 1; fi
# CRITICAL: ar rcs only replaces/adds members — stale members from previous
# builds survive exclusions. Always start from a clean archive.
rm -f "$OUT/libOrcaCore.a"
ar rcs "$OUT/libOrcaCore.a" "${OBJS[@]}"
actual=$(ar t "$OUT/libOrcaCore.a" | wc -l)
if [ "$actual" -ne "${#OBJS[@]}" ]; then
    echo "FATAL: archive has $actual members, manifest has ${#OBJS[@]} — stale members leaked" >&2; exit 1
fi
cp "$ROOT/Engine/engine-cxx/orca_core.h" "$OUT/Headers/orca_core.h"
cat > "$OUT/Headers/module.modulemap" <<'EOF'
module OrcaCore {
    header "orca_core.h"
    export *
}
EOF
file "$OUT/libOrcaCore.a"
echo "==> done: $OUT/libOrcaCore.a ($(wc -l < "$MANIFEST") objects)"
