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
- [ ] Add bridge/domain architecture contract tests

Build-system reproducibility remains a later upstreaming gate. The current
machine-local build is accepted while this architecture is cleaned up, but new
work must not deepen hidden-cache or fake-symbol dependencies.

**Accept:** one authoritative C++ document model; raw ABI use confined to the
Bridge; Swift and Metal consume revisioned derived state; all failures are
typed and loud; current physical-device slice behavior remains green.

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
- [ ] 3MF import via engine (blocked on stub/dep decisions — see map)
- [x] Basic move/rotate controls, object list, multi-instance copy/delete,
  and CPU ray-cast picking implemented (device acceptance still required)
- [ ] Snap, lay-flat, and auto-arrange (engine algorithms — never reimplement)
- [x] Replace index-coupled scene state with stable snapshot identity
- [ ] Replace O(triangle × instance) picking before treating large plates as
  production-ready

**Accept:** import a real-world STL, arrange 3 copies, zoom/inspect, slice.

## Phase 3 — Config & presets (in progress)
**Goal:** the ~2,000-settings problem solved by generation, not typing.

- [x] Upstream PresetBundle, inheritance, machine/filament/process selection,
  search, and preset-aware slicing verified on device and desktop
- [ ] Stop duplicating profile JSON; package the canonical upstream resources
- [ ] Expose stable preset IDs, compatibility metadata, and rejection reasons
- [ ] Extract versioned ConfigOptionDefs schema → generate SwiftUI forms
- [ ] Preset switching diffs and modified-values badges
- [ ] Immutable background slice jobs: progress, cancel, plate estimate

**Accept:** pick printer + preset → slice → estimates match desktop Orca
within a few % for same model/settings.

## Phase 4 — G-code preview & output
**Goal:** see what you sliced, get it out.

- Split reusable G-code/toolpath data semantics from libvgcode's OpenGL
  renderer; do not port its GL backend to iOS
- Implement the toolpath renderer in Metal: feature primitives, scrubber,
  layer range, speed/type coloring
- Export .gcode / .3mf (share sheet + Files); open-in from Mail/Files

**Accept:** scrub a real print's toolpath at 60fps; exported gcode loads
in desktop OrcaSlicer identically.

## Phase 5 — Printers & polish
**Goal:** a product.

- LAN send (Bambu MQTT/SSM path), basic printer status (temp, camera frame)
- Calibration subset (flow/PA passes generating their own gcode)
- Memory hardening (jetsam budgeting, streaming), iPad keyboard/pointer,
  landscape lock review, App Store asset pipeline workaround for icons
- TestFlight via Mac (xtool can't upload — plan the handoff)

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
