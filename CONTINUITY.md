# CONTINUITY — OrcaPad

## PLAN

- Current goal: desktop feature parity over the three-module architecture
  (Swift Client → Bridge → untouched Engine). [USER 2026-10-07: "complete
  feature parity, highest priority first, mark completions in the .md files"]
- Done through ABI v16 (`8edb8a6`): all 8 ranked PARITY items + thumbnails.
  Source of truth for what's left: `Bridge/tools/parity-manifest.toml` ->
  generated PARITY.md "Remaining work" (551 desktop items, 152 features,
  21% parity at ABI v16).
- [2026-10-07 USER] Order: (1) docs + cleanup, (2) programmatic parity
  checker (desktop features extracted from upstream vs implemented),
  (3) Klipper printer web UI in the Device tab + install on iPoke, then
  plate/object editing → prepare/presets → Files integration → preview.
  Goal stays full parity; respect the architecture.
- [2026-10-07 USER] Device tab may embed the printer's own web page
  (scoped AGENTS.md exception). Deferred by user: STEP/SVG, Draco,
  Calibration menu, mesh boolean. v16 installed on iPoke; user device
  verification of v8–v16 still pending.

## DECISIONS

- [2026-10-06 USER] Three modules, one-way deps; engine never patched; raw ABI
  only in `Sources/OrcaBridge`; C++ session is the sole authority; lock order
  plater → presets; engine entry process-serialized (`ObjectBase` IDs).
- Desktop logic living in GUI code is reimplemented at the matching layer:
  presentation → client; engine orchestration (ArrangeJob/OrientJob/project
  load flows) → Bridge C++ calling the engine's own helpers.
- [2026-10-07] Import recenters the imported GROUP on the bed (file layout
  kept); project open keeps exact placements (new document id).
- [2026-10-07] Arrange overflow is parked beside the bed + counted (no
  PartPlate yet). Lay flat = tap any facet (no hull-plane highlighting).
- [2026-10-07] Physical printers live in the engine's PhysicalPrinterCollection
  under `<data_dir>/user/default/physical_machine` (this fork's GUI owns the
  load path; OrcaPad's convention, documented in the Bridge).
- [2026-10-07] Upload = URLSession per host (desktop does libcurl in its GUI
  layer); only OctoPrint + Moonraker enabled, others typed rejections.
- Thumbnails: client renders the plate once offscreen; Bridge box-filters to
  each engine-requested size (bottom-up rows, the GL convention upstream flips).

## PROGRESS

- [2026-10-07 CODE][TOOL] ABI v23: printable toggle (greyed render),
  instance count, clone (+arrange), instance->object, assemble, scale to
  build volume, unit conversion. Host tests 50,951 PASS.
- [2026-10-07 CODE][TOOL] ABI v22: per-object / per-part setting overrides
  (desktop allowed-key rule, dump/set/erase, override counts in snapshots);
  ObjectSettingsSheet reuses the Prepare row editor, seeds from the
  resolved config. Host tests 50,908 PASS.
- [2026-10-07 CODE][TOOL] ABI v21: group transforms (instances_set /
  instances_rotate, one undo step); client multi-selection (long-press
  toggle, select all, group move/rotate/delete, per-instance previews).
  v20 installed on iPoke. Host tests 50,881 PASS.
- [2026-10-07 CODE][TOOL] ABI v20: mirror (left-handed instances in
  snapshots + renderer normal-sign flip), object copy/paste clipboard,
  camera view presets (client), copy/paste keyboard shortcuts.
  Host tests 50,862 PASS. Parity 27% (30 done). Phone disconnected:
  v18-v20 NOT installed yet (v17 is on the device).
- [2026-10-07 CODE][TOOL] ABI v19: volumes in snapshots (per-volume id/name/
  role/extruder + own meshes for non-parts), split to objects/parts,
  shape objects + shape/file volumes, volume type/delete/rename; renderer
  translucent volume pass (desktop GLVolume colors); object list with
  volume rows + Add shape menu. Host tests 50,841 PASS. Parity 25%.
  [TOOL] xtool darwin SDK record (~/.swiftpm/swift-sdks) got lost during
  a crashed concurrent build; restored by symlinking the artifactbundle
  (xtool then skips its NIO-based generator, which cannot epoll here).
- [2026-10-07 CODE][TOOL] ABI v18: transactional mutations (OrcapadMutation),
  64-step undo/redo with labels in the snapshot, rename, delete all,
  session-unique mesh revisions; Plate undo/redo buttons (cmd-Z), object
  list rename + delete all. Host tests 50,770 PASS. Parity 24%.
- [2026-10-07 CODE][TOOL] Parity checker (`2974b83`): 551 desktop items, 152
  features, PARITY.md generated + gated. ABI v17: physical printer
  print_host_webui; Device tab = printer web UI (PrinterWebSession/WKWebView)
  + PrinterStore (printer orchestration moved out of the view), send sheet,
  failure banner (StatusCenter.alert), LAN ATS keys. Host tests 50,641 PASS.

- [2026-10-07 CODE][TOOL] ABI v8–v16 (`7ada690`…`8edb8a6`): plate type, slice
  jobs/validate/warnings, import_model, projects, user presets, arrange/orient/
  lay flat, preview v14, physical printers + upload, thumbnails. Host contract
  tests 50,635 checks green; core + app builds green; audit PASS (12 checks).
- [2026-10-07 CODE] Closure grew to 225 upstream TUs: 3mf/bbs_3mf, NSVGUtils,
  Emboss, ExPolygonsIndex, Orient, Arrange, ModelArrange, libnest2d, NLopt
  2.5.0 (headers via `Bridge/tools/gen_nlopt.py`, verified vs CMake), Boost.Thread.
- [2026-10-06 CODE][TOOL] Gates A–C6 (compressed): contract suite + audit,
  stable IDs/revisions/snapshots, four-tab shell, Prepare editor, Preview, gizmos.

## DISCOVERIES

- [2026-10-07 TOOL] Doc entries had been stamped 2026-10-13 (future); git
  and the clock say 2026-10-07; all such stamps corrected in place.
  13 empty binary-named dirs in the repo root (created in pairs on
  2026-10-06 between 16:14 and 17:03, before the current
  prepare_preset_data_dir existed) were removed; likely an earlier test
  iteration mkdir-ing dangling c_str paths (UNCONFIRMED; current code is
  correct). Retired boost_filesystem_shim.cpp was still tracked: deleted.
- [2026-10-07 CODE] Swift `expectedBridgeABIVersion` had silently stayed at 8
  while the header reached 14 — only a runtime check compares them. Audit
  now fails on mismatch.
- [2026-10-07 CODE] Upstream quirks found: Anycubic Vyper profile fails desktop
  validation (no G92 E0) — profile PR candidate; `ConfigBase::save_to_json`
  silently fails when the parent dir is missing; physical-printer host key is
  `host_type` (coEnum); `ModelInstance::rotate` takes only a matrix;
  `OrientParamsArea` memcpy leaves empty std::function members.
- [2026-10-07 CODE] expat include path had pointed at a nonexistent dir: AMF
  compiled against SDK expat 2.7.4 headers while linking vendored 2.2.0. Fixed.
- [2026-10-06 CODE] Bed origin is machine-dependent (derive from
  `printable_area`); host tests mirror shipped `-O2 -DNDEBUG`; build remains
  machine-local (caches, profile tree) — reproducibility/CI deferred.

## OUTCOMES

- [2026-10-06 USER] Gate B on device: builds and slices; rotate UX redone (C6).
- [2026-10-03 USER] Phase 1 accepted: 483,772-triangle STL sliced on device.
- [2026-10-02 USER] Phase 0/2 accepted: native Metal viewer, engine slicing.
