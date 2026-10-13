# PLANS.md — OrcaPad roadmap

The port in one line: **OrcaSlicer's engine, a native shell, Metal instead of
OpenGL, touch instead of mouse.** Phases have acceptance criteria; a phase is
done when its criteria pass on the physical device, not in imagination.

Upstream contact surface (keep it this small): engine APIs + config defs +
G-code data semantics. When OrcaSlicer tags a release, rebasing must cost days,
not weeks. `ARCHITECTURE.md` is the normative design.

---

## Architecture Gate A — Three-module foundation (in progress)
**Goal:** clean the proof-of-concept into Swift Client → Bridge → Untouched
Engine before feature breadth makes the current coupling permanent.

- [x] Document module responsibilities, dependency rules, failure semantics,
  state ownership, capabilities, and migration order
- [x] Align repository and Swift target names with explicit Bridge ownership
- [x] Replace diagnostic-string success checks with one typed bridge result
- [x] Remove shared static bridge result strings and define data ownership
- [x] Introduce stable engine object/instance IDs and document revisions
- [x] Replace mutable index-coupled Swift scene mirroring with immutable snapshots
- [x] Move orchestration/filesystem/slicing state out of `PlaterView`
- [x] Add bridge contract tests (host C-ABI suite, 183 checks) + static
  architecture audit; Swift-domain unit tests remain (need a host-runnable
  Swift module or Mac CI — tracked below)
- [ ] Swift-domain contract tests (DocumentStore/CoordinateMapper) — blocked
  on a Linux-runnable Swift test target or a Mac runner (CI now has a hosted
  macOS runner, Gate D: unblocked)

**Gate A close-out:** one authoritative C++ document; raw ABI confined to the
Bridge; Swift and Metal consume revisioned derived state; all failures are
typed and loud; host contract tests, static audit, and the physical-device
slice loop all green.

Build-system reproducibility remains a later upstreaming gate. The current
machine-local build is accepted while this architecture is cleaned up, but new
work must not deepen hidden-cache or fake-symbol dependencies.

**Accept:** one authoritative C++ document model; raw ABI use confined to the
Bridge; Swift and Metal consume revisioned derived state; all failures are
typed and loud; current physical-device slice behavior remains green.

## Gate D — CI + TestFlight distribution (in progress)
**Goal:** every `main` push is verified and reaches the user's devices via
TestFlight, with no Mac on the user's side.

- [x] Public GitHub repo `iSteeb/OrcaPad`: AGPL-3.0 LICENSE, history on the
      GitHub noreply address
- [x] Engine archive is a valid Apple static library (Darwin format with a
      `__.SYMDEF` index; build-core.sh and the audit enforce it)
- [x] Workflow `.github/workflows/testflight.yml`: Linux audit + parity gate;
      release build with xtool on the hosted `xcode-27` runner; main builds
      signed with the App Store profile and uploaded with `altool`
      (`Distribution/package-testflight.sh`)
- [x] App Store requirements: asset-catalog icon (user artwork), privacy
      manifest checked against the release binary's required-reason APIs,
      truthful DT* toolchain keys, ITSAppUsesNonExemptEncryption=NO
- [ ] First build processed and installed from TestFlight on iPoke
- [ ] Host contract tests in CI (Ubuntu 26.04 container + ccache)
- [ ] Engine cross-build in CI (reproducible archive; stop committing it)

**Accept:** a push to `main` yields a TestFlight build that installs and
slices on the device; a red audit or parity check blocks the upload.

## Gate C — Four-tab desktop-parity UX (in progress)
**Goal:** the app reads like desktop OrcaSlicer: Plate → Prepare → Preview →
Device, each tab a clean feature module over the same stores.

- [x] C1: RootView glass TabView, `Features/{Plate,Prepare,Preview,Device}`,
      global status overlay, Device stub (`a32dac4`)
- [x] C2: Prepare desktop parity v1 — Simple/Advanced/Expert (schema `mode`),
      engine-derived kind membership, category accordions, typed editors,
      modified badges + per-key/per-kind reset, Slice in the toolbar;
      ABI v4 overrides on edited presets (`df05d73`)
- [x] C3: Preview v1 — upstream GCodeProcessor → compact toolpath (ABI v5),
      feature-colored Metal lines, layer scrubber, remaining-time estimate;
      real Thumbnails.cpp + jpeg adapter; brass interop fix (`78f9920`)
- [x] C4: Preview parity — vertical dual layer-range slider, in-layer move
      scrubber + tool marker, color schemes (line type / speed / layer height /
      line width / fan / temperature), legend with feature toggles + per-feature
      time share, travel toggle, width-true ribbons (budgeted), range drawing
      without rebuilds; ABI v6 (`b0960d2`, `b5dc9c0`)
- [x] C5: Prepare parity v1 — desktop page → optgroup layout EXTRACTED from
      pinned upstream Tab.cpp (`extract_settings_layout.py`), process pages
      inline, printer/filament settings screens, tooltips, units, range
      validation, single-element vectors edited as scalars, multiline G-code
      editor (`f09d26b`)
- [x] C5b: user presets — save (desktop SavePresetDialog rules, detach) /
      delete via `PresetCollection`, persisted + reloaded; unsaved-changes
      prompt; user/project groups in pickers (ABI v12, `343eed2`)
- [x] C6: Plate v1 — left gizmo toolbar (Move/Rotate/Scale) with on-canvas
      gizmos (axes, ring + angle tick, bounding box), ring-drag rotation with
      5° snap, vertical-drag scale kept on bed, desktop Object manipulation
      panel (X/Y/RotZ/Scale/size, quick actions), copy/delete; FIXED picking
      (points vs pixels) that broke tap-select and drag-move (`cc85933`)
- [x] C6b: engine Arrange — Arrange.cpp + libnest2d + NLopt 2.5.0 in the
      closure (`gen_nlopt.py` headers verified vs CMake), ArrangeJob param
      flow; plus Orient (ABI v13, `8277409`)
- [x] C6c-1: ABI v7 full transforms — XYZ Euler + per-axis scale in the
      snapshot/set contract, engine matrix in snapshots, world-axis
      `orca_plater_instance_rotate` (wraps through 360°), engine rest-on-bed;
      mode panels (Move X/Y/center, Rotate axis picker + ±15° + reset, Scale
      per-axis + uniform lock); Preview controls in a left dock (`8d4cdaf`)
- [x] C6c-2: Lay flat — facet-pick tap → engine rotate-to-down + rest on bed
      (ABI v13; hull-plane highlighting still missing)
- [x] C7: plate type (v8), cancel/validate/warnings (v9), import of all
      formats (v10), 3MF projects (v11), preview v14 (markers, all schemes,
      filament totals), physical printers + OctoPrint/Moonraker upload (v15),
      G-code/3MF thumbnails (v16) — see PARITY.md
- [x] Programmatic parity checker (`Bridge/tools/parity-check.py`): desktop
      surface extracted from upstream (551 items, 14 surfaces), manifest
      evidence verified, PARITY.md generated + commit-gated
- [ ] Parity backlog: generated PARITY.md "Remaining work" (priority order)
- [x] Device tab: printer web UI (user-allowed 2026-10-07, scoped AGENTS.md
      exception): selected physical printer's own page in a WKWebView,
      device UI URL = print_host_webui (ABI v17), native picker/reload/
      send/manage around it; LAN ATS + local-network keys in App-Info.plist

**Accept:** device walkthrough of all four tabs; edits in Prepare change the
sliced gcode (verified in Preview + resolved config); Preview scrubs layers.

## Gate B — Config-driven placement, preset UX, resolved config ✅
**Goal:** make WHAT YOU SEE match WHAT WILL SLICE: placement tied to the
selected machine's bed, presets grouped/filtered by engine compatibility, and
the full resolved config inspectable.

- [x] Bridge ABI v3: `center_around_origin()` + bed-centered import; preset
      entries (name + vendor + is_compatible from the engine's own flags);
      typed print volume (`printable_area` bbox — origin is machine-dependent,
      604 corner-style vs 53 centered profiles); resolved-config JSON dump
      (`PresetBundle::full_config()` exactly as sliced)
- [x] Client placement: bed rectangle from the selected machine drives the
      viewer grid and the engine↔viewer frame; drag auto-selects + moves;
      rotate/±15/±45 around the object center
- [x] Regenerate `Resources/config-schema.json` (751 options) from
      `print_config_def` via the host extractor and commit it
- [x] Settings: machines grouped by manufacturer, filaments grouped by
      manufacturer, processes filtered to engine-compatible with the selected
      machine (+ show-all toggle)
- [x] Config viewer: searchable, schema-generated, resolved values with
      modified-value highlighting and a selection/bed summary
- [x] Contract tests for every new ABI (10900 checks); census + device install
      (`80ce347` on iPoke, user acceptance pending)

**Accept:** import lands centered on the SELECTED machine's bed; rotate spins
about the object center by exact degrees; drag moves; preset lists grouped and
process-filtered per engine flags; resolved config view matches slice output.

## Phase 0 — Scaffold + Metal proof ✅
**Goal:** project skeleton, meta-files, Metal pipeline live on device.

- [x] xtool project scaffold (Swift 6, iOS 17)
- [x] SwiftUI plater shell (toolbar, status overlay)
- [x] Metal viewer: MTKView, orbit camera, bed grid, lit test cube
- [x] Runtime MSL compilation (Linux can't build .metallib)
- [x] Builds green via `xtool dev build` (0 warnings)
- [x] Installs + renders on iPoke; syslog shows renderer online
  (verified 2026-10-02: `renderer online` <600ms after launch, visual
  confirm by user)

**Accept:** dark 3D scene w/ 256mm bed grid + orange cube; 1-finger orbit,
2-finger pan, pinch zoom all smooth at ~60fps.

## Phase 1 — Engine bring-up (the proving ground) ✅ (core gate passed)
**Goal:** libslic3r running on iOS, called from Swift.

- [x] Cross-compile the real FFF libslic3r pipeline and dependencies from Linux
  (current archive: 259 members / 259 unique sources)
- [x] Initial extern-C bridge proving Swift can drive the C++ engine
- [x] Harden that proof into the typed Bridge contract in Architecture Gate A
- [x] On-device proof: STL load + admesh repair verified on iPhone
  (12 tris / 8000 mm³ cube, user-confirmed 2026-10-02)
- [ ] Later upstreaming gate: reproducible CMake+xcframework for required
  libslic3r capabilities and dependencies (current build is machine-local)
- [x] Slice runs off-main (Task.detached + engine status callback → chip)
- [x] **ACCEPTED ON DEVICE 2026-10-03**: 483k-tri STL → G-code in Documents
  (user-confirmed slice completion; Files visibility via UIFileSharingEnabled)

**Accept:** ✅ met 2026-10-03 (483k-tri model; sequential-TBB so minutes not
seconds — acceptable for Phase 1; parallelism is a Phase 2 perf item).

## Phase 2 — Plater MVP (in progress)
**Goal:** it looks and works like a slicer.

- [x] Document picker import: STL (binary+ASCII via engine/admesh) — DONE
  2026-10-02, user-verified on device
- [x] Mesh rendering in Metal (indexed triangle meshes, flat shading,
  bed-anchored, auto-framing) — DONE (cube fallback retired on import)
- [x] Real slicing geometry on-device: slice_mesh_ex probe (8 z-levels,
  mid-layer islands+area in status chip) — DONE
- [x] 3MF import via engine (real 3mf/bbs_3mf TUs, ABI v10/v11)
- [x] Basic move/rotate controls, object list, multi-instance copy/delete,
  and CPU ray-cast picking implemented (device acceptance still required)
- [x] Lay-flat and auto-arrange through engine algorithms (ABI v13); snap
      still open
- [x] Replace index-coupled scene state with stable snapshot identity
- [ ] Replace O(triangle × instance) picking before treating large plates as
  production-ready

**Accept:** import a real-world STL, arrange 3 copies, zoom/inspect, slice.

## Phase 3 — Config & presets (in progress)
**Goal:** the ~2,000-settings problem solved by generation, not typing.

- [x] Upstream PresetBundle, inheritance, machine/filament/process selection,
  search, and preset-aware slicing verified on device and desktop
- [ ] Stop duplicating profile JSON; package the canonical upstream resources
      (`Sources/OrcaPad/Resources/system/` is still a copy)
- [x] Compatibility metadata (engine `is_compatible` + vendor, ABI v3)
- [ ] Stable preset IDs and compatibility rejection reasons (names only today)
- [x] Extract versioned ConfigOptionDefs schema → generate SwiftUI forms
      (Gate B schema, C2/C5 generated editor + extracted desktop layout)
- [x] Modified-value badges, per-key/per-kind reset, unsaved-changes prompt
      (C2, C5b)
- [ ] Preset compare/diff view (PARITY.md §2)
- [x] Background slice jobs: progress, cancel, validate, estimates; results
      carry their source revision (ABI v9/v14)
- [ ] Edit while slicing (ARCHITECTURE §5): today edits are rejected while a
      slice runs instead of slicing a captured immutable revision

**Accept:** pick printer + preset → slice → estimates match desktop Orca
within a few % for same model/settings.

## Phase 4 — G-code preview & output
**Goal:** see what you sliced, get it out.

- [x] Split reusable G-code/toolpath data semantics from libvgcode's OpenGL
  renderer; do not port its GL backend to iOS (upstream GCodeProcessor via
  ABI v5/v6/v14, engine ExtrusionRole/EMoveType values)
- [x] Implement the toolpath renderer in Metal: feature primitives, scrubber,
  layer range, speed/type coloring (Gate C3/C4, all color schemes)
- [x] Export .gcode / .3mf (share sheet + Files)
- [ ] Open-in from Mail/Files (no document types declared yet)
- [ ] Acceptance: 60fps scrub of a real print on device; exported G-code
  compared in desktop OrcaSlicer

**Accept:** scrub a real print's toolpath at 60fps; exported gcode loads
in desktop OrcaSlicer identically.

## Phase 5 — Printers & polish
**Goal:** a product.

- [x] Print-host send: OctoPrint + Moonraker upload/start (ABI v15)
- [ ] Remaining print hosts (PrusaLink/Connect, Duet, Repetier, …)
- [ ] Printer status (temps, progress, camera frame); Bambu MQTT/LAN is a
  proprietary-plugin path (➖ in PARITY.md)
- [ ] Calibration subset — deferred by user 2026-10-07 (upstream calibration
  models are `.drc`, so Draco must enter the closure first)
- Memory hardening (jetsam budgeting, streaming), iPad keyboard/pointer,
  landscape lock review, App Store asset pipeline workaround for icons
- [x] TestFlight without a local Mac: CI signs and uploads every main build
  (Gate D)

**Accept:** a stranger can go from STL → printed part with only the iPad.

---

## Risk register (live)

| Risk | Mitigation |
|---|---|
| Deps (OCCT/OpenVDB) too heavy for first bring-up | Phase 1 uses minimal link set; heavy deps enter only when a feature demands them |
| TBB unsupported on iOS | Swap to libdispatch-based pool behind engine's thread API; measure first |
| Runtime MSL compile cost grows with shader count | Cache `MTLLibrary` in Caches dir once offline compile is possible (Mac collaborator) |
| Backgrounding kills long slices | Foreground slicing + `beginActivity`; chunked resume later |
| jetsam on huge multi-plate jobs | 64-bit arm64 fine; budget memory, stream gcode, warn user |
| Upstream drift | Engine consumed at pinned tags, never privately patched; generic seams go upstream |
| Competing scene authorities | C++ session is authoritative; Swift snapshots and Metal caches carry revisions |
| Patch-by-patch bridge debt | Solve typed results, platform services, capabilities, IDs, and jobs as broad contracts |

## Explicit non-goals (for now)

Deferred until the core loop and architecture are complete: seam/support
painting, MMU segmentation painting, and CAD/parametric editing. Remote desktop
UI streaming is not planned. iPhone, watch, tv, and vision remain separate
product decisions; appropriate desktop feature parity is still the destination.
