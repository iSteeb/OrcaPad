# CONTINUITY — OrcaPad

## PLAN

- Current goal: desktop feature parity over the three-module architecture
  (Swift Client → Bridge → untouched Engine). [USER 2026-10-13: "complete
  feature parity, highest priority first, mark completions in the .md files"]
- Done through ABI v16 (`8edb8a6`): all 8 ranked PARITY items + thumbnails.
  Source of truth for what's left: PARITY.md "Remaining work".
- Next: user device-verifies v8–v16 (nothing since `8d4cdaf` was on iPoke
  before this install); then unblocked list in PARITY.md (per-layer
  color change/pause, undo/redo, object list ops, multi-filament, multi-plate).
- Blocked on user decisions: printer web UI (WebView ban), draco
  (calibration), OCCT (STEP/SVG), CGAL/mcut (mesh boolean).

## DECISIONS

- [2026-10-06 USER] Three modules, one-way deps; engine never patched; raw ABI
  only in `Sources/OrcaBridge`; C++ session is the sole authority; lock order
  plater → presets; engine entry process-serialized (`ObjectBase` IDs).
- Desktop logic living in GUI code is reimplemented at the matching layer:
  presentation → client; engine orchestration (ArrangeJob/OrientJob/project
  load flows) → Bridge C++ calling the engine's own helpers.
- [2026-10-13] Import recenters the imported GROUP on the bed (file layout
  kept); project open keeps exact placements (new document id).
- [2026-10-13] Arrange overflow is parked beside the bed + counted (no
  PartPlate yet). Lay flat = tap any facet (no hull-plane highlighting).
- [2026-10-13] Physical printers live in the engine's PhysicalPrinterCollection
  under `<data_dir>/user/default/physical_machine` (this fork's GUI owns the
  load path; OrcaPad's convention, documented in the Bridge).
- [2026-10-13] Upload = URLSession per host (desktop does libcurl in its GUI
  layer); only OctoPrint + Moonraker enabled, others typed rejections.
- Thumbnails: client renders the plate once offscreen; Bridge box-filters to
  each engine-requested size (bottom-up rows, the GL convention upstream flips).

## PROGRESS

- [2026-10-13 CODE][TOOL] ABI v8–v16 (`7ada690`…`8edb8a6`): plate type, slice
  jobs/validate/warnings, import_model, projects, user presets, arrange/orient/
  lay flat, preview v14, physical printers + upload, thumbnails. Host contract
  tests 50,635 checks green; core + app builds green; audit PASS (12 checks).
- [2026-10-13 CODE] Closure grew to 225 upstream TUs: 3mf/bbs_3mf, NSVGUtils,
  Emboss, ExPolygonsIndex, Orient, Arrange, ModelArrange, libnest2d, NLopt
  2.5.0 (headers via `Bridge/tools/gen_nlopt.py`, verified vs CMake), Boost.Thread.
- [2026-10-06 CODE][TOOL] Gates A–C6 (compressed): contract suite + audit,
  stable IDs/revisions/snapshots, four-tab shell, Prepare editor, Preview, gizmos.

## DISCOVERIES

- [2026-10-13 CODE] Swift `expectedBridgeABIVersion` had silently stayed at 8
  while the header reached 14 — only a runtime check compares them. Audit
  now fails on mismatch.
- [2026-10-13 CODE] Upstream quirks found: Anycubic Vyper profile fails desktop
  validation (no G92 E0) — profile PR candidate; `ConfigBase::save_to_json`
  silently fails when the parent dir is missing; physical-printer host key is
  `host_type` (coEnum); `ModelInstance::rotate` takes only a matrix;
  `OrientParamsArea` memcpy leaves empty std::function members.
- [2026-10-13 CODE] expat include path had pointed at a nonexistent dir: AMF
  compiled against SDK expat 2.7.4 headers while linking vendored 2.2.0. Fixed.
- [2026-10-06 CODE] Bed origin is machine-dependent (derive from
  `printable_area`); host tests mirror shipped `-O2 -DNDEBUG`; build remains
  machine-local (caches, profile tree) — reproducibility/CI deferred.

## OUTCOMES

- [2026-10-06 USER] Gate B on device: builds and slices; rotate UX redone (C6).
- [2026-10-03 USER] Phase 1 accepted: 483,772-triangle STL sliced on device.
- [2026-10-02 USER] Phase 0/2 accepted: native Metal viewer, engine slicing.
