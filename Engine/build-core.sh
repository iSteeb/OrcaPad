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
# INCREMENTAL: obj/ persists across runs; see needs_build + flags stamp.
mkdir -p "$BUILD/gen/libslic3r" "$BUILD/obj" "$OUT/Headers"

CFLAGS=(
    -target "$TARGET" -isysroot "$SDK"
    -std=c++17 -O2 -DNDEBUG -Wno-deprecated-declarations
    # ORDER MATTERS: shims FIRST so adapter headers (boost/log, boost/nowide,
    # tbb, openssl, occt) win over symlinked real boost headers in gen/.
    -I"$ROOT/Engine/shim" -I"$ROOT/Engine/shim/occt-stub"
    -I"$SRC" -I"$SRC/libslic3r" -I"$BUILD/gen"
    -I"$DEPS" -I"$DEPS/admesh"
    -I"$DEPS/qhull/src"
    -I"$DEPS/glu-libtess/include"
    -I"$DEPS/libigl" -I"$ROOT/Engine/cache/Orca-deps-libnoise/src"
    -I"$DEPS/libnest2d/include"
    -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat/expat/lib"
    -I"$DEPS/miniz"
    -I"$ROOT/Engine/engine-cxx"
    -DSLIC3R_APP_KEY='"OrcaSlicer"' -DSLIC3R_APP_NAME='"OrcaSlicer"'
)
CONLY_FLAGS=(
    -target "$TARGET" -isysroot "$SDK"
    -O2 -DNDEBUG -Wno-deprecated-declarations
    -include limits.h
    -I"$DEPS" -I"$DEPS/qhull/src" -I"$DEPS/glu-libtess/include"
    -I"$DEPS/libigl" -I"$ROOT/Engine/cache/Orca-deps-libnoise/src"
    -I"$DEPS/libnest2d/include"
    -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat/expat/lib"
    -I"$DEPS/miniz"
)

# Host boost/eigen + fetched cereal headers exposed via symlinks (NEVER
# -I/usr/include — glibc headers must not shadow the Darwin SDK).
CEREAL="$ROOT/Engine/cache/cereal/include/cereal"
if [ ! -f "$CEREAL/access.hpp" ]; then
    echo "==> fetching cereal v1.3.0 (OrcaSlicer's pin) into Engine/cache/" >&2
    mkdir -p "$ROOT/Engine/cache"
    git clone -q --depth 1 -b v1.3.0 https://github.com/USCiLab/cereal "$ROOT/Engine/cache/cereal"
fi
[ -f "$CEREAL/access.hpp" ] || { echo "FATAL: cereal fetch failed" >&2; exit 1; }
ln -sfn /usr/include/boost "$BUILD/gen/boost"
ln -sfn /usr/include/eigen3/Eigen "$BUILD/gen/Eigen"
ln -sfn /usr/include/eigen3/unsupported "$BUILD/gen/unsupported"
ln -sfn "$CEREAL" "$BUILD/gen/cereal"
ln -sfn /usr/include/CGAL "$BUILD/gen/CGAL"
ln -sfn "$ROOT/Engine/cache/Orca-deps-libnoise/src" "$BUILD/gen/libnoise"
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

compile_one() { # compile_one <src> <obj> <compiler+flags...>
    # Phase 1: record the command; execution is parallel (phase 2, below).
    local src="$1" o="$2"; shift 2
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
    local p=0
    while IFS= read -r cmd; do
        nice -n 15 bash -c "$cmd" &
        p=$((p + 1))
        if (( p >= maxjobs )); then wait -n; p=$((p - 1)); fi
    done < "$JOBS"
    wait
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
    [ "$failed" -eq 0 ] || exit 1
}

compile() { # compile <srcfile> (C++, extra flags after src)
    local src="$1"; shift
    local o="$OBJ/$(echo "$src" | sed 's|/|_|g').o"
    compile_one "$src" "$o" "$CLANG" "${CFLAGS[@]}" "$@"
}
compile_c() { # compile_c <srcfile> (C)
    local src="$1"
    local o="$OBJ/$(echo "$src" | sed 's|/|_|g').o"
    compile_one "$src" "$o" "${CLANG%++}" "${CONLY_FLAGS[@]}"
}

OBJS=()

# vendored admesh (mesh read/repair)
for f in connect normals shared stl_io stlinit util; do
    compile "$DEPS/admesh/$f.cpp"
done

# vendored qhull — EXACT file lists from deps_src/qhull/CMakeLists.txt
# (libqhull_SOURCES). Do not glob, do not "fix": the C/C++ hook split
# (qh_fprintf vs qh_malloc vs qh_fprintf_rbox ownership) is deliberate.
for f in global_r stat_r geom2_r poly2_r merge_r libqhull_r geom_r poly_r \
         qset_r mem_r random_r usermem_r io_r user_r rboxlib_r; do
    compile_c "$DEPS/qhull/src/libqhull_r/$f.c"
done
for f in Coordinates PointCoordinates Qhull QhullFacet QhullFacetList \
         QhullFacetSet QhullHyperplane QhullPoint QhullPointSet QhullPoints \
         QhullQh QhullRidge QhullSet QhullStat QhullVertex QhullVertexSet \
         RboxPoints RoadError RoadLogEvent; do
    # upstream quirk: usermem_r-cpp.cpp relies on transitive stdarg/stdio —
    # (file is NOT in upstream's list, but this fix pattern stays for reference)
    compile "$DEPS/qhull/src/libqhullcpp/$f.cpp"
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
        LocalesUtils.cpp) extra+=(-include sstream) ;;
        Geometry/VoronoiUtilsCgal.cpp) extra+=(-include boost/multiprecision/gmp.hpp) ;;
    esac
    compile "$SRC/libslic3r/$f" "${extra[@]:-}"
done

# files needing force-includes (transitive-include quirks / CGAL gmp_int)
compile "$SRC/libslic3r/Feature/FuzzySkin/FuzzySkin.cpp" -include thread
compile "$SRC/libslic3r/MinimumSpanningTree.cpp"
compile "$SRC/libslic3r/Triangulation.cpp" -include boost/multiprecision/gmp.hpp

# --- full slicing pipeline (census-verified 2026-10-02) ---
for f in Model.cpp PrintConfig.cpp PrintBase.cpp Print.cpp PrintApply.cpp \
         PrintObject.cpp PrintObjectSlice.cpp PrintRegion.cpp \
         Layer.cpp LayerRegion.cpp PerimeterGenerator.cpp \
         Surface.cpp SurfaceCollection.cpp Slicing.cpp SlicingAdaptive.cpp \
         ElephantFootCompensation.cpp Brim.cpp BridgeDetector.cpp EdgeGrid.cpp \
         MinAreaBoundingBox.cpp MutablePolygon.cpp VariableWidth.cpp \
         PlaceholderParser.cpp GCodeWriter.cpp GCodeReader.cpp Time.cpp Thread.cpp \
         Semver.cpp ObjectID.cpp Config.cpp CustomGCode.cpp GCode.cpp Format/OBJ.cpp Format/objparser.cpp Format/AMF.cpp \
         GCode/WipeTower2.cpp GCode/GCodeProcessor.cpp GCode/ThumbnailData.cpp \
         GCode/AdaptivePAInterpolator.cpp GCode/AdaptivePAProcessor.cpp \
         GCode/PchipInterpolatorHelper.cpp GCode/FanMover.cpp \
         GCode/SmallAreaInfillFlowCompensator.cpp GCode/PrintExtents.cpp \
         GCode/RetractWhenCrossingPerimeters.cpp GCode/AvoidCrossingPerimeters.cpp \
         GCode/ConflictChecker.cpp GCode/SeamPlacer.cpp GCode/TimelapsePosPicker.cpp \
         GCode/CoolingBuffer.cpp GCode/SpiralVase.cpp GCode/PressureEqualizer.cpp \
         GCode/ToolOrdering.cpp GCode/ToolOrderUtils.cpp GCode/WipeTower.cpp \
         Algorithm/LineSplit.cpp Algorithm/RegionExpansion.cpp \
         SLA/IndexedMesh.cpp SVG.cpp \
         FilamentGroupUtils.cpp ParameterUtils.cpp ShortEdgeCollapse.cpp \
         IntersectionPoints.cpp FlushVolPredictor.cpp Geometry/Circle.cpp Clipper2Utils.cpp Triangulation.cpp TriangleSetSampling.cpp          FaceDetector.cpp TriangleSelector.cpp BuildVolume.cpp Extruder.cpp SVG.cpp PrincipalComponents2D.cpp MultiMaterialSegmentation.cpp FilamentGroup.cpp ContourZ.cpp Feature/Interlocking/InterlockingGenerator.cpp Feature/Interlocking/VoxelUtils.cpp Feature/FuzzySkin/FuzzySkin.cpp calib.cpp MaterialType.cpp FlushVolCalc.cpp NormalUtils.cpp; do
    compile "$SRC/libslic3r/$f"
done

# infills
for f in Fill.cpp FillBase.cpp FillConcentric.cpp FillConcentricInternal.cpp \
         FillCrossHatch.cpp FillGyroid.cpp FillHoneycomb.cpp Fill3DHoneycomb.cpp \
         FillAdaptive.cpp FillLightning.cpp FillLine.cpp FillPlanePath.cpp \
         FillRectilinear.cpp FillTpmsD.cpp FillTpmsFK.cpp \
         Lightning/Generator.cpp Lightning/Layer.cpp Lightning/DistanceField.cpp \
         Lightning/TreeNode.cpp; do
    compile "$SRC/libslic3r/Fill/$f"
done

# supports
for f in SupportCommon.cpp SupportMaterial.cpp SupportSpotsGenerator.cpp \
         TreeSupport.cpp TreeSupport3D.cpp TreeModelVolumes.cpp; do
    compile "$SRC/libslic3r/Support/$f"
done

# Arachne wall generator
for f in WallToolPaths.cpp SkeletalTrapezoidation.cpp SkeletalTrapezoidationGraph.cpp \
         utils/ExtrusionLine.cpp utils/PolylineStitcher.cpp utils/SquareGrid.cpp \
         BeadingStrategy/BeadingStrategy.cpp BeadingStrategy/BeadingStrategyFactory.cpp \
         BeadingStrategy/DistributedBeadingStrategy.cpp BeadingStrategy/LimitedBeadingStrategy.cpp \
         BeadingStrategy/OuterWallInsetBeadingStrategy.cpp BeadingStrategy/RedistributeBeadingStrategy.cpp \
         BeadingStrategy/WideningBeadingStrategy.cpp; do
    compile "$SRC/libslic3r/Arachne/$f"
done

# vendored glu-libtess (triangulation backend for Tesselate.cpp)
# File list mirrors upstream deps_src/glu-libtess/CMakeLists.txt EXACTLY:
# priorityq-heap.c / priorityq-sort.c are NOT standalone TUs upstream —
# compiling them duplicates __gl_pqHeap* strong C symbols.
for f in dict geom memalloc mesh normal priorityq render sweep tess tessmono; do
    compile_c "$DEPS/glu-libtess/src/$f.c"
done

# vendored semver (version parsing)
compile_c "$DEPS/semver/semver.c"

# vendored clipper1 Z-variant (VoronoiUtils / MM segmentation)
compile "$DEPS/clipper/clipper_z.cpp"

# vendored clipper2 (Clipper2Utils / Fill paths)
for f in clipper.engine clipper.offset clipper.rectclip clipper.minkowski; do
    [ -f "$DEPS/clipper2/Clipper2Lib/src/$f.cpp" ] && compile "$DEPS/clipper2/Clipper2Lib/src/$f.cpp"
done

# vendored expat (XML for AMF/3mf metadata)
for f in xmlparse xmltok xmlrole; do
    compile_c "$DEPS/expat/$f.c"
done

# vendored miniz (zip I/O)
compile_c "$DEPS/miniz/miniz.c"

# libnoise (fuzzy skin) — full source set
for f in "$ROOT"/Engine/cache/Orca-deps-libnoise/src/*.cpp \
         "$ROOT"/Engine/cache/Orca-deps-libnoise/src/model/*.cpp \
         "$ROOT"/Engine/cache/Orca-deps-libnoise/src/module/*.cpp; do
    [ -f "$f" ] && compile "$f"
done

# adapter stubs (3MF/STEP/thumbnails — loud throws, upstream untouched)
compile "$ROOT/Engine/engine-cxx/format_stubs.cpp"

# our C boundary
compile "$ROOT/Engine/engine-cxx/boost_filesystem_shim.cpp"
compile "$ROOT/Engine/engine-cxx/orca_core.cpp"

run_jobs_parallel

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
