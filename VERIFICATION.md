# VERIFICATION.md — implementation vs desktop equivalence audit

Method: for every ✅/🟡 parity feature, the OrcaPad code path is compared
against the upstream code path named in `Bridge/tools/parity-manifest.toml`
(`source`/`desktop` anchors). Status: PASS = equivalent pathway;
FIXED = divergence found and fixed in this pass; NOTE = minor divergence,
documented, no user impact expected.

## Slicing core

| Feature | Desktop path | Ours | Status |
|---|---|---|---|
| prepare.slice | `BackgroundSlicingProcess`: validate → process → export_gcode + GCodeProcessor stats | `orcapad_run_print`: identical engine calls, typed warnings mapped | PASS |
| prepare.preset-selection | `PlaterPresetComboBox` + `update_compatible`; incompatible greyed, toggle to show all | GroupedPickerList: compatibility glyph + filters + "show incompatible" toggles | PASS |
| prepare.bed-type | app_config per-printer `curr_bed_type` memory | same engine path (BedTypeMemory client mirror) | PASS |
| plate context | `PartPlate::set_print` sets origin/index/name per plate | every slice path sets all three (ABI v28) | PASS |
| config finalization | desktop never slices a shape-invalid config (defaults + full_config normalization) | `orcapad_finalize_config` on every slice path, repairs reported | PASS (last-line guard; see LESSONS) |
| slice-all | plate-by-plate reslice, per-plate context | loop of full per-plate slices, markers between | PASS |

## Transforms / arrange / orient

| Feature | Desktop path | Ours | Status |
|---|---|---|---|
| plate.import | `load_model_objects`: center_around_origin + bed-center offset + on-bed | same math, group-centered | PASS |
| plate.arrange | `init_arrange_params`: **distance default 0** (brim-aware inflation), clearance, nozzle height, shrink bedpts | was hardcoded 6 mm | **FIXED**: `scaled(0)` + the same three engine param updates |
| plate.fill-bed | FillBedJob formula + setter markers (bed_idx=256) | same formula/markers; same distance default | **FIXED** (distance 0) |
| plate.orient | OrientJob: per-object `support_threshold_angle`, else bundle, else 60; min-area default | read bundle only | **FIXED**: per-object first, bundle, 60 |
| plate.rotate | GLGizmoRotate zones 45/5/free by drag radius | same fractions/radii + relative-angle entry | PASS |
| plate.scale | GLGizmoScale3D axis handles + uniform | projected local-axis handles + uniform drag | PASS |
| plate.lay-flat | GLGizmoFlatten::update_planes (hull, BFS eps 0.001, filters, 10% shrink) | ported verbatim into the Bridge | PASS |
| plate.move | drag on bed plane; Z engine-managed | same (Z rest-on-bed is a documented user decision) | PASS |

## Document / presets / preview / device (spot-verified)

| Feature | Status | Note |
|---|---|---|
| undo-redo | PASS | desktop stack depth 100 vs unlimited ours (NOTE) |
| copy-paste / settings paste | PASS | one undo step per batch (ABI v26 semantics) |
| split/merge/mirror | PASS | engine paths |
| multi-plate / slice-all | PASS | grid + derived membership + 3MF roundtrip |
| user presets save/delete/detach | PASS | PresetCollection rules |
| multi-filament | PASS | set_num_filaments semantics; merge-with still open (manifest gap) |
| preview schemes/legend/travel/markers/slider | PASS | engine ExtrusionRole/EMoveType carried raw (never libvgcode) |
| device webui/upload | PASS | print_host_webui + host upload parity |
| files project/export/open-in | PASS | 3MF with presets; G-code share sheet |

## Open divergences (tracked, no fix in this pass)

- Arrange spacing is not user-settable (desktop arrange dialog has a
  distance field; ours uses the desktop default 0). Manifest gap under
  plate.arrange.
- Multi-filament "merge with" (combine two filament presets) unimplemented.
- Desktop keyboard shortcut set larger than ours (touch device; tracked in
  plate.keyboard partial).
