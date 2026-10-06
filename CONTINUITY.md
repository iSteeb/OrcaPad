# CONTINUITY — OrcaPad

## PLAN

- Goal: migrate the working proof to the normative three-module architecture
  in `ARCHITECTURE.md`: Swift Client → Bridge → Untouched Engine.
- Current acceptance: preserve the verified on-device STL/preset/G-code path
  while eliminating stringly results, unstable index identity, competing
  mutable scene state, and `PlaterView` orchestration.
- Next steps:
  1. Align repository/package names with the Bridge boundary.
  2. Introduce one typed C result/error contract and migrate Swift wrappers.
  3. Add stable engine IDs, document revisions, and authoritative snapshots.
  4. Extract document/preset/slice orchestration from `PlaterView`.
  5. Add contract tests, then resume feature-parity work.
- Build reproducibility is explicitly deferred; the machine-local build stays
  green but is not the current architecture milestone. [USER]

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
- Historical bring-up strategy: shims + stub-adapters outside the untouched
  upstream tree. Architecture Gate A now replaces patch-by-patch growth with
  explicit Bridge contracts; this map remains evidence, not future policy.

## DECISIONS

- [2026-10-06 USER] Exactly three conceptual modules: untouched Engine,
  Bridge, and Swift Client; dependency direction is Client → Bridge → Engine.
  Prefer simplicity, loud failures, and complete cross-cutting solutions over
  individual patches. Feature parity where appropriate remains the goal.
- [USER] Strategy B: engine as-is + native GUI, Metal only, skip exotic tools.
- Name `OrcaPad`, bundle `ie.duz.OrcaPad`. iPad-first. iOS 17, Swift 6.
- Runtime MSL compilation (Linux can't build .metallib). [TOOL]
- No private upstream patches. Current shims/wrapper TUs are temporary Bridge
  mechanisms; generic portability seams may be contributed upstream. Slicing
  algorithms are never duplicated outside the Engine.
- Sequential TBB shims (parallel_for/reduce serial) — swap for real oneTBB
  iOS build when slicing perf matters.
- Cross-build via raw clang scripts (build-core.sh), NOT CMake, NOT lld
  linking — static archives only; final link = SwiftPM/xtool. [TOOL]
- [USER-mandated] Process: no build without a passing static audit first;
  no one-error-at-a-time cycles; builds are expensive (~200s) — earn them.
- Incremental compiles in build-core.sh (depfiles + mtime + flags stamp).

## PROGRESS

- [2026-10-06] THREE-MODULE DESIGN SPEC LANDED: `ARCHITECTURE.md` is normative;
  AGENTS/PLANS/LESSONS now enforce Client → Bridge → untouched Engine, typed
  loud failures, authoritative revisioned state, broad fixes over patches, and
  deferred build reproducibility. Static audit + `xtool dev build` green.
- [2026-10-05] PRESET SELECTION FIXED & VERIFIED END-TO-END: root cause =
  headless PresetBundle leaves variant-less vendor machines INVISIBLE
  (293 loaded / 29 selectable; select_preset_by_name rejects invisible) →
  show-all pass on system printers + update_compatible after machine select.
  Probe-verified 293/293; device-verified: Positron machine+process land in
  gcode (printer_model, printable_area 180x180, 0.12mm Fine process, 16MB,
  2h10m est); desktop loads it. Host probe toolchain (/tmp/build-host-engine.sh
  + probe2) = fast engine-debugging loop; 259-file host engine build green.
- [2026-10-05] INTEROP CLOSED ✅: preset-sliced gcode (incl. 60MB 0.05mm
  Voron-process monster) loads in desktop OrcaSlicer. Presets live on
  device via writable Documents/orcapad-data (system symlink → bundle,
  recreated each launch — bundle UUID changes per install). OPEN: machine
  preset not landing in output (printer_model empty; filament/process do
  land) — awaiting user info whether machine was actually selected; also
  want compatibility filtering (process nozzle vs machine) + first-run
  defaults that don't pick 0.05mm Voron profiles.
- [2026-10-04] P3 PRESET SYSTEM LANDED (`7286c58`, device test pending):
  upstream PresetBundle+Preset+AppConfig compiled into engine (inheritance
  resolved by upstream code — never reimplemented); boost::filesystem
  compiled from boostorg source tag 1.90 (was the missing compiled lib);
  12,006 profile JSONs bundled read-only at Resources/system → data_dir()
  points at the bundle; Settings sheet (machine/filament/process pickers,
  search, @AppStorage persistence); slicing via full_config() of selection
  with is_BBL_printer = bundle.is_bbl_vendor(). Desktop interop should now
  be correct BY CONSTRUCTION (real machine presets set nozzle_type/density).
  TODO: verify on device + desktop; measure preset load time (12k files).
- [2026-10-03 late] PLATER MVP IMPLEMENTED (build green, NOT yet device-tested —
  phone away): engine plater API (objects/instances/transforms/ensure-on-bed/
  plater-slicing; anchors = matrix*pivot so Swift renders T·Ry·S); Swift
  EnginePlater (locked, @unchecked Sendable); PlaterView rebuilt on plater
  state (object list sheet, selection HUD ±45/±15 rotate, copy/del instance);
  Renderer multi-object×instance draws + Möller–Trumbore picking + bed-plane
  move gesture. Device test pending: import→select→move→rotate→copy→slice.
- [2026-10-03 eve] Interop fixes: producer header, filament_density 1.24,
  nozzle_type brass (mutation-in-place, not type-swap), is_BBL_printer=false.
  Desktop crash root causes all found via mutation tests + gdb-attach:
  density=0 AND empty nozzle_type both segfault desktop viewer
  (update_slice_warnings OOB). UNCONFIRMED: on-device slice failure AFTER
  fixes (user-reported; no crash .ips — engine returned error string; need
  syslog when phone returns).
- [2026-10-03 eve] Interop fix landed: header_slic3r_generated() now returns
  `OrcaSlicer 2.4.2` (upstream-identical producer marker; desktop
  GCodeProcessor refuses unrecognized producers). Build pressure fixed:
  12 parallel clang jobs OOM-froze the 14GiB box (killed a pi session
  mid-build) → ORCAPAD_JOBS=6 default + nice 15. Engine archive verified
  (old literal absent, 250/250 members); app relinked green. Awaiting user
  desktop validation.

- [2026-10-02] P2 vertical slice deployed & USER-VERIFIED (`763e337`):
  document picker → sandbox copy → EngineMesh.load (off-main) → flat-shaded
  Metal render of the REAL mesh + auto-framing; slice_mesh_ex report in chip.
  Two render bugs fixed same night: leftover test-cube model matrix (20×
  scale); face-duplicated verts fed shared-vertex indices (garbled mesh).
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

- [2026-10-06 CODE] Architecture audit: Swift reaches a custom C ABI
  (`orca_core.h`), not direct C++ interop; the clean v2.4.2 submodule supplies
  153/215 libslic3r implementation TUs. The device-only archive is built from
  a manual source list plus include shims/stub symbols, has 3 duplicate object
  members, and depends on ignored caches that a fresh clone cannot recreate.
  No project tests/CI exist; 12,006 byte-identical profile JSONs are duplicated.
- `system_preset_names()` returns std::vector BY VALUE — returning
  c_str() into it = dangling pointer → garbled UI text. C-API rule:
  strings must be copied to session-owned storage before return.
- Bundle DIRECTORY resources aren't addressable via Bundle.url(forResource:)
  (iOS quirk) — compose path from bundleURL + FileManager.fileExists.
- App bundle path changes UUID on EVERY xtool install → symlinks into the
  bundle dangle after reinstall; recreate per launch. fileExists() returns
  FALSE for dangling symlinks (bites the exists-check pattern).
- PresetBundle REQUIRES a writable data_dir with system/ + user/default/;
  pointing it at the read-only bundle throws directory_iterator ENOENT.

- 2026-10-03 machine-freeze root cause: 12-way parallel clang++ on heavy
  CGAL/Eigen TBB TUs vs 14GiB RAM+4GiB swap → swap-death. 6+nice survives.
  [TOOL]
- A full sed-regen of libslic3r_version.h invalidates ~every object (114
  stale after the SoftFever_VERSION add) — expect ~10min niced rebuilds when
  touching that header. [TOOL]

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

- [2026-10-03] **PHASE 1 COMPLETE — FULL SLICE ON DEVICE**: user's 483,772-tri
  STL sliced end-to-end (admesh → slicing → Arachne perimeters → infills →
  supports → GCodeProcessor → .gcode in Documents). Zero crashes in final
  build. G-code visibility in Files fixed via UIFileSharingEnabled (`99b048a`).
  Desktop-parity: engine built with -DNDEBUG (assert semantics identical to
  desktop Release). Build tooling: parallel engine builds (20min→70s),
  crash-diagnosis chain (.ips→frame→binary-string extraction) proven 3×.

- [2026-10-02] Phase 0 complete: Linux→iPhone loop + Metal + interop proven.
- [2026-10-02] Phase 1 gate complete: engine subset runs on device (STL
  load+repair, 12 tris/8000 mm³ cube, user-verified).
- [2026-10-02] **Phase 2 vertical slice complete**: real STL → real mesh in
  the Metal viewer + real slice_mesh_ex cross-sections on device
  (user-verified `763e337`). Full G-code = next session, map banked.
