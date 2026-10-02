# CONTINUITY — OrcaPad

## PLAN

- Goal: native iOS/iPadOS port of OrcaSlicer — engine as-is (C++), GUI from
  scratch (SwiftUI + Metal). See PLANS.md for phases.
- Acceptance (Phase 1, this push): status chip shows
  `OrcaCore: STL load+repair ok · 12 tris · 8000 mm³` on iPoke.
- Next steps:
  1. [USER] Verify STL import + slice line on device (deployed `3a94ce7`).
  2. Full G-code pipeline session (map below): add Model.cpp + Format/OBJ
     (+objparser) + GCode family; shims: tbb pipeline trio, nowide/iostream;
     stub-adapter TU: load_3mf/load_step/load_amf → throw 'unsupported'.
  3. Then PrintConfig/Print/PrintObject chain → first real slice → Files.

## G-code pipeline dep map (static analysis 2026-10-02) [CODE]

- Model.cpp externals: Eigen ✓, boost headers ✓ (needs nowide/iostream shim),
  log shim ✓. Calls: load_stl ✓ compiled, load_obj (easy: OBJ.cpp+objparser,
  no new deps), load_amf (expat+miniz vendored ✓), load_3mf (WALL: draco not
  vendored, curl — stub it), load_step (OCCT — stub it).
- GCode.cpp: tbb/parallel_pipeline.h + tbb/pipeline.h + tbb/version.h
  (new shim surface — sequential pipeline ~40 lines), boost/beast base64
  (header-only, verify in apt boost), Shiny (profile-guarded).
- Expected adds: GCode.cpp GCodeWriter PlaceholderParser CustomGCode Time
  Thread Semver PrintBase Print PrintApply PrintObject PrintObjectSlice
  PrintRegion Layer LayerRegion PrintConfig Extruder✓ Flow✓ WipeTower2
  WipeTower GCodeProcessor PressureEqualizer GCode/Thumbnails ThumbnailData
  MinAreaBoundingBox ElephantFootCompensation Brim... (closure-driven; 15-25
  files). Walls: none hard — draco/curl/OCCT stay stubbed, freetype not needed
  for slicing, PNG only for thumbnails (stub-able).
- Strategy unchanged: shims + stub-adapters in Engine/, upstream untouched.

## DECISIONS

- [USER] Strategy B: engine as-is + native GUI, Metal only, skip exotic tools.
- Name `OrcaPad`, bundle `ie.duz.OrcaPad`. iPad-first. iOS 17, Swift 6.
- Runtime MSL compilation (Linux can't build .metallib). [TOOL]
- Upstream NEVER patched — adapters only: Engine/shim headers, -include
  force-includes, wrapper TUs in Engine/engine-cxx/. I18N::translate_fn
  identity-adapter lives in orca_core.cpp (utils.cpp needs macOS libproc.h).
- Sequential TBB shims (parallel_for/reduce serial) — swap for real oneTBB
  iOS build when slicing perf matters.
- Cross-build via raw clang scripts (build-core.sh), NOT CMake, NOT lld
  linking — static archives only; final link = SwiftPM/xtool. [TOOL]
- [USER-mandated] Process: no build without a passing static audit first;
  no one-error-at-a-time cycles; builds are expensive (~200s) — earn them.
- Incremental compiles in build-core.sh (depfiles + mtime + flags stamp).

## PROGRESS

- [2026-10-02] P2 vertical slice deployed (`3a94ce7`): document picker →
  security-scoped copy → EngineMesh.load (off-main) → flat-shaded Metal
  render of the REAL mesh + camera auto-framing; slice_mesh_ex report
  (8 z-levels, mid-layer islands+area) in the status chip.
- [2026-10-02] Engine/build-ios untracked (incremental cache), obj cache
  survived exclusion cycles (corrections cost 0 compiles).

- [2026-10-02] Phase 0 done: app + Metal viewer verified on iPoke (60fps).
- [2026-10-02] Interop gate green: static lib → xcframework → Swift .Cxx.
- [2026-10-02] OrcaSlicer v2.4.2 shallow submodule at upstream/orcaslicer.
- [2026-10-02] OrcaCore: 82-object static archive cross-compiled from Linux.
  Subset: geometry core (Point→ExPolygon, Clipper, Voronoi family, MedialAxis,
  ShortestPath, Tesselate, ExtrusionEntity*, Flow, TriangleMesh+Slicer, STL),
  vendored admesh+qhull+glu-libtess, CGAL header-only for VoronoiUtilsCgal.
  Shims: boost::log, boost::nowide, tbb (sequential), openssl/md5→CommonCrypto,
  OCCT stubs (STEP.hpp parse-only). External symbol debt: benign only.
- [2026-10-02] Tooling: Engine/tools/closure.py (BFS closure + duplicate audit).
- [2026-10-02] Root causes fixed: ar rcs ghost members (archive never dropped
  exclusions — now rm -f + member-count guard); Debian multiarch gmp.h.
- BLOCKERS (2 real T-T duplicates): __gl_pqHeap* (priorityq.c vs
  priorityq-heap.c — pick one per upstream CMake); TriangleMesh::~TriangleMesh
  (orca_core.cpp.o + Format_STL.cpp.o — investigate owner).

## DISCOVERIES

- SwiftPM binaryTarget caching is FAITHFUL (md5-identical copy of Prebuilt) —
  earlier "stale cache" suspicion disproven. [TOOL]
- xtool's app link uses lld with a WARNING "does not support platform iOS —
  proceed at your own risk" — it proceeds and works (device-verified P0).
- `ar rcs` only replaces/adds members; stale members survive exclusions.
- deps_src/ vendors: admesh clipper2 libnest2d miniz qhull glu-libtess expat
  semver qoi earcut agg nanosvg libigl mcut + more — external deps shrink to
  boost/eigen/cereal/tbb/opencv/occt/draco/jpeg/png/freetype/openssl.
- Format/STEP.hpp is included unconditionally by Model.hpp → OCCT stub headers
  suffice (parse-only; STEP.cpp never compiled in core subset). [CODE]
- On-device bundle id `XTL-C93C0481.ie.duz.OrcaPad`; launch manually only.

## OUTCOMES

- [2026-10-02] Phase 0 complete: Linux→iPhone loop + Metal + interop proven.
- [2026-10-02] **Phase 1 gate complete**: 79-object OrcaSlicer engine subset
  (TriangleMesh/admesh/clipper/voronoi/qhull/tess) loads + repairs an STL
  ON DEVICE (12 tris, 8000 mm³ cube, user-verified). Crash→fix cycle
  established (crash report pull → exact frame → targeted fix → 1-file
  incremental rebuild → redeploy).
