# PLANS.md — OrcaPad roadmap

The port in one line: **OrcaSlicer's engine, a native shell, Metal instead of
OpenGL, touch instead of mouse.** Phases have acceptance criteria; a phase is
done when its criteria pass on the physical device, not in imagination.

Upstream contact surface (keep it this small): `libslic3r` + config defs +
`libvgcode`. When OrcaSlicer tags a release, rebasing must cost days, not weeks.

---

## Phase 0 — Scaffold + Metal proof ✅ (in progress)
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

- [x] Cross-compile real libslic3r subset from Linux (79-object static lib:
  geometry core + admesh + qhull + glu-libtess + header-only CGAL)
- [x] Swift↔C++ interop layer in `Engine/` with hardened extern-C boundary
  (Swift owns paths; exceptions/errors → status strings, never crashes)
- [x] On-device proof: STL load + admesh repair verified on iPhone
  (12 tris / 8000 mm³ cube, user-confirmed 2026-10-02)
- [ ] CMake+xcframework for full libslic3r incl. deps (current subset is
  hand-curated; grows link-driven toward Print pipeline)
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
- [ ] Instance transform gizmos: move / rotate / snap, lay-flat, auto-arrange
  (arrange algorithm from engine — never reimplement)
- [ ] Object list UI; multi-instance; delete/duplicate
- [ ] Picking (ray-cast against meshes on CPU or via GPU id buffer)

**Accept:** import a real-world STL, arrange 3 copies, zoom/inspect, slice.

## Phase 3 — Config & presets
**Goal:** the ~2,000-settings problem solved by generation, not typing.

- Extract ConfigOptionDefs at build time → JSON → generate SwiftUI forms
- Printer/filament/process preset bundles (ship Orca's profiles as resources)
- Preset switching diffs, search, modified-values badges
- Background slice job UI: progress, cancel, plate estimate (time/filament)

**Accept:** pick printer + preset → slice → estimates match desktop Orca
within a few % for same model/settings.

## Phase 4 — G-code preview & output
**Goal:** see what you sliced, get it out.

- Port `libvgcode` (already standalone) → xcframework
- Toolpath renderer in Metal: line primitives by feature type, scrubber,
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
| Upstream drift | Engine consumed as submodule at tags, never patched in place |

## Explicit non-goals (for now)

Seam/support painting, MMU segmentation painting, CAD/parametric editing,
remote rendering/streaming desktop UI, iPhone layout, watch/tv/vision targets.
