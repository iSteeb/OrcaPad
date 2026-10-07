#!/usr/bin/env bash
# Shared engine compile list — the single source of truth consumed by BOTH
# Bridge/build-core.sh (iOS archive) and Bridge/build-host-tests.sh (host
# contract tests). The two builds must never drift apart: the duplicate
# archive-member bug of 2026-10-06 came from lists diverging.
#
# Each record is one line:
#   cxx<TAB>/absolute/path.cpp<TAB>extra flags (space separated, optional)
#   c  <TAB>/absolute/path.c
engine_sources() {
    local ROOT SRC DEPS f
    ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
    SRC="$ROOT/upstream/orcaslicer/src"
    DEPS="$ROOT/upstream/orcaslicer/deps_src"

    # vendored admesh (mesh read/repair)
    for f in connect normals shared stl_io stlinit util; do
        printf 'cxx\t%s\n' "$DEPS/admesh/$f.cpp"
    done

    # vendored qhull — EXACT file lists from deps_src/qhull/CMakeLists.txt
    # (libqhull_SOURCES). Do not glob, do not "fix": the C/C++ hook split
    # (qh_fprintf vs qh_malloc vs qh_fprintf_rbox ownership) is deliberate.
    for f in global_r stat_r geom2_r poly2_r merge_r libqhull_r geom_r poly_r \
             qset_r mem_r random_r usermem_r io_r user_r rboxlib_r; do
        printf 'c\t%s\n' "$DEPS/qhull/src/libqhull_r/$f.c"
    done
    for f in Coordinates PointCoordinates Qhull QhullFacet QhullFacetList \
             QhullFacetSet QhullHyperplane QhullPoint QhullPointSet QhullPoints \
             QhullQh QhullRidge QhullSet QhullStat QhullVertex QhullVertexSet \
             RboxPoints RoadError RoadLogEvent; do
        printf 'cxx\t%s\n' "$DEPS/qhull/src/libqhullcpp/$f.cpp"
    done

    # libslic3r geometry subset (grows link-error-driven)
    for f in libslic3r.cpp Point.cpp Line.cpp MultiPoint.cpp Polygon.cpp Polyline.cpp \
             BoundingBox.cpp ExPolygon.cpp ClipperUtils.cpp clipper.cpp \
             Circle.cpp ArcFitter.cpp Geometry.cpp Geometry/ConvexHull.cpp \
             Geometry/MedialAxis.cpp Geometry/Voronoi.cpp Geometry/VoronoiUtils.cpp \
             Geometry/VoronoiUtilsCgal.cpp Geometry/VoronoiOffset.cpp ShortestPath.cpp \
             Tesselate.cpp ExtrusionEntity.cpp ExtrusionEntityCollection.cpp Flow.cpp \
             LocalesUtils.cpp TriangleMesh.cpp TriangleMeshSlicer.cpp Format/STL.cpp; do
        case "$f" in
            LocalesUtils.cpp) printf 'cxx\t%s\t-include sstream\n' "$SRC/libslic3r/$f" ;;
            Geometry/VoronoiUtilsCgal.cpp) printf 'cxx\t%s\t-include boost/multiprecision/gmp.hpp\n' "$SRC/libslic3r/$f" ;;
            *) printf 'cxx\t%s\n' "$SRC/libslic3r/$f" ;;
        esac
    done

    # files needing force-includes (transitive-include quirks / CGAL gmp_int)
    printf 'cxx\t%s\t-include thread\n' "$SRC/libslic3r/Feature/FuzzySkin/FuzzySkin.cpp"
    printf 'cxx\t%s\n' "$SRC/libslic3r/MinimumSpanningTree.cpp"
    printf 'cxx\t%s\t-include boost/multiprecision/gmp.hpp\n' "$SRC/libslic3r/Triangulation.cpp"

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
             IntersectionPoints.cpp FlushVolPredictor.cpp Geometry/Circle.cpp Clipper2Utils.cpp TriangleSetSampling.cpp FaceDetector.cpp TriangleSelector.cpp BuildVolume.cpp Extruder.cpp PrincipalComponents2D.cpp MultiMaterialSegmentation.cpp FilamentGroup.cpp ContourZ.cpp Feature/Interlocking/InterlockingGenerator.cpp Feature/Interlocking/VoxelUtils.cpp calib.cpp MaterialType.cpp FlushVolCalc.cpp NormalUtils.cpp \
             Preset.cpp PresetBundle.cpp AppConfig.cpp; do
        case "$f" in
            # host libstdc++ does not leak <memory> transitively into this
            # header (Darwin libc++ does) — same adapter pattern as LocalesUtils
            Format/objparser.cpp) printf 'cxx\t%s\t-include memory\n' "$SRC/libslic3r/$f" ;;
            *) printf 'cxx\t%s\n' "$SRC/libslic3r/$f" ;;
        esac
    done

    # infills
    for f in Fill.cpp FillBase.cpp FillConcentric.cpp FillConcentricInternal.cpp \
             FillCrossHatch.cpp FillGyroid.cpp FillHoneycomb.cpp Fill3DHoneycomb.cpp \
             FillAdaptive.cpp FillLightning.cpp FillLine.cpp FillPlanePath.cpp \
             FillRectilinear.cpp FillTpmsD.cpp FillTpmsFK.cpp \
             Lightning/Generator.cpp Lightning/Layer.cpp Lightning/DistanceField.cpp \
             Lightning/TreeNode.cpp; do
        printf 'cxx\t%s\n' "$SRC/libslic3r/Fill/$f"
    done

    # supports
    for f in SupportCommon.cpp SupportMaterial.cpp SupportSpotsGenerator.cpp \
             TreeSupport.cpp TreeSupport3D.cpp TreeModelVolumes.cpp; do
        printf 'cxx\t%s\n' "$SRC/libslic3r/Support/$f"
    done

    # Arachne wall generator
    for f in WallToolPaths.cpp SkeletalTrapezoidation.cpp SkeletalTrapezoidationGraph.cpp \
             utils/ExtrusionLine.cpp utils/PolylineStitcher.cpp utils/SquareGrid.cpp \
             BeadingStrategy/BeadingStrategy.cpp BeadingStrategy/BeadingStrategyFactory.cpp \
             BeadingStrategy/DistributedBeadingStrategy.cpp BeadingStrategy/LimitedBeadingStrategy.cpp \
             BeadingStrategy/OuterWallInsetBeadingStrategy.cpp BeadingStrategy/RedistributeBeadingStrategy.cpp \
             BeadingStrategy/WideningBeadingStrategy.cpp; do
        printf 'cxx\t%s\n' "$SRC/libslic3r/Arachne/$f"
    done

    # vendored glu-libtess (triangulation backend for Tesselate.cpp)
    # File list mirrors upstream deps_src/glu-libtess/CMakeLists.txt EXACTLY:
    # priorityq-heap.c / priorityq-sort.c are NOT standalone TUs upstream —
    # compiling them duplicates __gl_pqHeap* strong C symbols.
    for f in dict geom memalloc mesh normal priorityq render sweep tess tessmono; do
        printf 'c\t%s\n' "$DEPS/glu-libtess/src/$f.c"
    done

    # vendored semver (version parsing)
    printf 'c\t%s\n' "$DEPS/semver/semver.c"

    # vendored clipper1 Z-variant (VoronoiUtils / MM segmentation)
    printf 'cxx\t%s\n' "$DEPS/clipper/clipper_z.cpp"

    # vendored clipper2 (Clipper2Utils / Fill paths)
    for f in clipper.engine clipper.offset clipper.rectclip clipper.minkowski; do
        [ -f "$DEPS/clipper2/Clipper2Lib/src/$f.cpp" ] &&
            printf 'cxx\t%s\n' "$DEPS/clipper2/Clipper2Lib/src/$f.cpp"
    done

    # vendored expat (XML for AMF/3mf metadata)
    for f in xmlparse xmltok xmlrole; do
        printf 'c\t%s\n' "$DEPS/expat/$f.c"
    done

    # vendored miniz (zip I/O)
    printf 'c\t%s\n' "$DEPS/miniz/miniz.c"

    # libnoise (fuzzy skin) — full source set
    for f in "$ROOT"/Bridge/cache/Orca-deps-libnoise/src/*.cpp \
             "$ROOT"/Bridge/cache/Orca-deps-libnoise/src/model/*.cpp \
             "$ROOT"/Bridge/cache/Orca-deps-libnoise/src/module/*.cpp; do
        [ -f "$f" ] && printf 'cxx\t%s\n' "$f"
    done

    # boost::filesystem compiled bits — real upstream source (tag matches the
    # installed headers). The preset system (Preset.cpp / PresetBundle.cpp)
    # pulls path iteration + directory ops that headers alone don't provide.
    # windows_file_codecvt is Windows-only.
    for f in path operations directory exception path_traits portability \
             unique_path codecvt_error_category utf8_codecvt_facet; do
        printf 'cxx\t%s\t-std=c++20\n' "$ROOT/Bridge/cache/boost-filesystem-1.90/src/$f.cpp"
    done

    # adapter stubs (3MF/STEP — loud throws, upstream untouched)
    printf 'cxx\t%s\n' "$ROOT/Bridge/engine-cxx/format_stubs.cpp"
    # real thumbnail parse/encode (PNG via miniz, QOI vendored; JPEG hits the
    # loud adapter below)
    printf 'cxx\t%s\n' "$SRC/libslic3r/GCode/Thumbnails.cpp"
    printf 'cxx\t%s\n' "$ROOT/Bridge/engine-cxx/jpeg_stubs.cpp"
    printf 'c\t%s\n' "$DEPS/qoi/qoilib.c"

    # our C Bridge boundary
    # (boost_filesystem_shim.cpp is retired: its POSIX implementations were
    # fully superseded by the real boost-filesystem-1.90 sources above, and
    # keeping both defined the same symbols — dead weight on iOS and a
    # multiple-definition hazard whenever both members get linked.)
    # orca_bridge.cpp resolves the full config through vendored nlohmann/json.
    printf 'cxx\t%s\t-I%s\n' "$ROOT/Bridge/engine-cxx/orca_bridge.cpp" \
        "$DEPS/nlohmann"
}
