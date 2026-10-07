# OrcaPad ↔ OrcaSlicer desktop parity report

Audited 2026-10-13 at commit `8d4cdaf` against `upstream/orcaslicer` (pinned).
Status: ✅ done · 🟡 partial · ❌ missing · ➖ N/A on iOS / deliberate.
"Work" says what closing the gap needs: **UI** (Swift only), **Bridge** (new
ABI over engine code already compiled), **Closure** (engine TU/dependency not
yet in `Bridge/engine-sources.sh`), **Client-reimpl** (desktop logic lives in
`src/slic3r/GUI`, not the engine, so it must be rebuilt natively).

## 1. Plate / 3D editor

| Feature | Desktop evidence | OrcaPad evidence | Status | Work |
|---|---|---|---|---|
| Import model (STL, OBJ, AMF, 3MF geometry; multi-object) | `Plater.cpp` load_files / `load_model_objects:7044` | ABI v10 `orca_plater_import_model` (all objects, file layout preserved, group centered on bed); `PlateTabView.swift` ImportTypes.models | ✅ (STEP/SVG/DRC blocked, see §4) | — |
| Delete / delete all | `GLCanvas3D.cpp` toolbar | `DocumentStore.swift:136,143` | ✅ | — |
| Add/remove instances ("more/fewer") | `GLCanvas3D.cpp:6812,6824` | `DocumentStore.swift:116,129` | ✅ | — |
| Move gizmo + panel | `GizmoObjectManipulation.cpp:731` (X/Y/Z, world/object) | `PlateTabView.swift:357` X/Y + center | 🟡 Z and the world/object coordinate switch are omitted on purpose (user decision; the engine rests the object on the bed) | — |
| Rotate gizmo (3 rings, coarse/fine snap) | `GLGizmoRotate.cpp:33-36,114` | `Renderer.swift` ring for the selected axis; fixed 5° snap | 🟡 one ring at a time; no fine 1° snap zone | UI |
| Rotate panel (relative X/Y/Z input, reset) | `GizmoObjectManipulation.cpp:890,966,558` | `PlateTabView.swift:382` axis picker + glyph, ±15°, reset | 🟡 no free-angle relative entry | UI |
| Scale gizmo (per-axis handles) | `GLGizmoScale.cpp` | on-canvas handles are uniform only | 🟡 | UI |
| Scale panel (per-axis %, size, uniform lock) | `GizmoObjectManipulation.cpp:1095,1190-1276` | `PlateTabView.swift:494` | ✅ local axes only | — |
| Arrange | `GLCanvas3D.cpp:6788`, `Plater.cpp:17077` | ABI v13 `orca_plater_arrange` — real libnest2d + NLopt 2.5.0 (Orca's pin) in the closure; ArrangeJob/CLI param flow; overflow → virtual beds beside the plate; Arrange button | ✅ single plate (multi-plate overflow is shifted aside, not plated) | — |
| Auto-orient | `GLCanvas3D.cpp:6766`, `Plater.cpp:10912` | ABI v13 `orca_plater_orient` (engine `Orient.cpp`, min-area default, preset overhang angle); Orient button | ✅ | — |
| Lay on face (Flatten) | `GLGizmosManager.cpp:209` | ABI v13 `orca_plater_instance_lay_flat` + facet-pick tap (`Renderer.pickFace`) in the Lay flat tool | 🟡 taps any facet; no convex-hull plane highlighting | Bridge (hull plane grouping) |
| Split to objects / parts | `GLCanvas3D.cpp:6836,6848`, `Plater.cpp:17251` | none found | ❌ | Bridge (`ModelObject::split` is compiled) |
| Mirror | `Plater.cpp:7605` | snapshot rejects left-handed instances | ❌ | Bridge + renderer (winding flip) |
| Cut | `GLGizmosManager.cpp:210` | none found | ❌ | Closure: `CutUtils.cpp` (no exotic dependencies) |
| Mesh boolean | `GLGizmosManager.cpp:211` | stubbed in `format_stubs.cpp:97` | ❌ | Closure: CGAL PMP + libigl / mcut (heavy) |
| Support / seam / fuzzy-skin / MMU paint | `GLGizmosManager.cpp:212-215` | `PlateTabView.swift:258` placeholder | ❌ (deferred by AGENTS.md) | Bridge: `TriangleSelector.cpp` is compiled; brush UI is needed |
| Text emboss / SVG | `GLGizmosManager.cpp:216-217` | none found | ❌ | Closure: `Emboss.cpp` (imstb_truetype, nanosvg vendored) + font access |
| Measure / Assembly / Simplify / Brim ears | `GLGizmosManager.cpp:218-221` | none found | ❌ | Closure: `Measure.cpp`, `QuadricEdgeCollapse.cpp`; brim ears are Client-reimpl |
| Variable layer height | `GLCanvas3D.cpp:6858` | none found | ❌ | Bridge (`SlicingAdaptive.cpp` compiled) |
| Object list: parts / modifiers / negative volumes / blockers | `GUI_ObjectList.cpp:2153,2271,2441` | object sheet `PlateTabView.swift:182` lists objects only | ❌ | Bridge (`ModelVolumeType`) + multi-volume renderer |
| Per-object / per-part settings, height ranges | `GUI_ObjectList.cpp:3227` | none found | ❌ | Bridge (`ModelObject::config`, `layer_config_ranges`) |
| Rename object | `GUI_ObjectList.cpp:6055` | none found | ❌ | Bridge (trivial) |
| Multi-plate (add/delete/lock, plate settings) | `PartPlate.cpp:4407,4554`, `Plater.cpp:17787` | none found | ❌ | Client-reimpl: PartPlate is GUI code, not engine |
| Undo / redo | `Plater.cpp:11697,11714` (`UndoRedo::Stack`) | none found | ❌ | Bridge: Model snapshot stack under the session revision |
| Copy / paste | `Plater.cpp:17339,17348` | "Copy" means add-instance only | 🟡 | Bridge |
| Camera view presets (top/front/…/iso) | `GLCanvas3D.cpp:3411-3416` | `Camera.swift` orbit/zoom/pan only | ❌ | UI |
| Multi-select, select all | `Selection.cpp` | single selection (`DocumentStore.select`) | ❌ | UI + Bridge batch mutations |

## 2. Prepare / presets / settings

| Feature | Desktop evidence | OrcaPad evidence | Status | Work |
|---|---|---|---|---|
| Printer / process selection, vendor grouping | `PresetComboBoxes.cpp` | `GroupedPickerList.swift`, `PrepareTabView.swift` | ✅ | — |
| Compatibility filtering | `Preset.cpp` is_compatible | `PrepareTabView.swift:164` | ✅ | — |
| Nozzle diameter combo | `Plater.cpp:489,1862` | variants are separate printer presets | 🟡 | UI |
| Bed / plate type (`curr_bed_type`) | `Plater.cpp:1990-2010,2512-2544` → `GCode.cpp:2154` | ABI v8 `orca_presets_bed_type`/`set_bed_type`; `PrepareTabView.swift` PlateTypeRow; per-printer memory in `PresetStore.swift` | ✅ engine default on machine change (`Preset::get_default_bed_type`), model-supported list, read-only when not selectable | — |
| Multiple filaments / extruders, colors, AMS sync | `Plater.cpp:3101,3191,3204,3500` | one filament only | ❌ | Bridge (`PresetBundle` filament vector) + UI |
| Simple / Advanced / Expert modes | `Tab.cpp:1270` | `ConfigSchema.swift:119-129` | ✅ | — |
| Desktop page/optgroup layout | `Tab.cpp` | `Resources/settings-layout.json` (extracted) | ✅ | — |
| Widgets: bool / enum / numeric / text / multiline G-code, units, tooltips | `Field.cpp` | `ConfigSchema.swift:164-219`, `SettingsPagesView.swift:204` | ✅ | — |
| Color widget (`coColor`) | `Field.cpp` | none found (shown as text) | ❌ | UI |
| Per-extruder vector values | `Tab.cpp` extruder pages | only one-element vectors are editable (`ConfigSchema.swift:155-160`) | 🟡 | UI |
| Range validation | `Field.cpp` | `ConfigSchema.swift` numeric validation | ✅ | — |
| Option dependency enable/disable, sanity dialogs | `ConfigManipulation.cpp:594` | none found | ❌ | Client-reimpl (GUI logic) |
| Modified marker + revert to system | `Tab.cpp:1133,1143` | `SettingsPagesView.swift:68,99`, `resetKind` | ✅ | — |
| Revert to saved (user preset level) | `Tab.cpp:1143` | per-key reset + "Discard changes" restore the selected (saved) user preset | 🟡 no separate revert-to-parent-system for user presets | UI |
| Search | `Search.hpp:91` (global, all tabs) | per-screen `.searchable` | 🟡 | UI |
| Compare presets | `UnsavedChangesDialog.hpp:408`, `Tab.cpp:6626` | none found | ❌ | UI (config_dump already exists) |
| Save / rename / delete / detach user presets | `Tab.cpp:6663,6801`; `Preset.cpp:2865,2983`; `SavePresetDialog.cpp:135` | ABI v12 `orca_presets_save_user`/`delete_user` (desktop name rules, Orca filament scoping, `.info`, persisted + reloaded); `PresetActions.swift` menu + save sheet; user/project groups in pickers | ✅ (rename = save-as + delete) | — |
| Unsaved-changes prompt when switching presets | `UnsavedChangesDialog.hpp:266` | `PrepareTabView.swift` confirmation (discard / keep editing; save via preset menu) | 🟡 no "transfer changes to new preset" | Bridge (apply dirty options onto new selection) |
| Physical printers (host/URL) | `PhysicalPrinterDialog.hpp:27` | ABI v15 over the engine's `PhysicalPrinterCollection` (persisted JSON under `user/default/physical_machine`, reloaded each session); Device tab editor | ✅ | — |
| Import / export configs, bundles | `MainFrame.cpp:2762,2804,3688,3723` | none found | ❌ | Bridge |
| Resolved-config inspector | (no desktop equivalent) | `ResolvedConfigView.swift` | ✅ extra | — |

## 3. Preview / G-code viewer / slicing

| Feature | Desktop evidence | OrcaPad evidence | Status | Work |
|---|---|---|---|---|
| Schemes: FeatureType, Speed, Height, Width, Fan, Temperature | `libvgcode/include/Types.hpp:80-102` | `GcodePreviewStore.swift:8-13` | ✅ | — |
| VolumetricFlowRate, ActualSpeed/Volumetric, LayerTime lin/log, PA, Accel, Jerk, Tool | `Types.hpp:80-102` | ABI v14 fields; all schemes in `GcodePreviewStore.swift` color modes | ✅ ColorPrint/Summary ➖ | — |
| ~~ActualSpeed etc~~ | | | ✅ (see row above) | |
| Tool / ColorPrint / Summary | same | none found | ❌ | UI for Tool (`extruder` exported); ColorPrint needs color changes |
| Travel toggle | `Types.hpp:168` | `PreviewTabView.swift:225` dock | ✅ | — |
| Wipes, retractions, unretractions, seams, tool/color changes, pauses, custom G-code | `Types.hpp:169-176` | ABI v14 marker segments (point moves) + Seams/Retract dock toggles; markers rendered as crosses | 🟡 tool/color changes, pauses, custom G-code exported but not yet drawn | UI |
| Center of gravity, shells | `Types.hpp:177-179`, `GCodeViewer.cpp:2476` | none found | ❌ | UI (shells can reuse Plate meshes) |
| Tool marker | `Types.hpp:179` | `ToolpathRenderer` marker | ✅ | — |
| Legend with per-feature toggles, time, % | `GCodeViewer.cpp:3111` | `PreviewTabView.swift:148-200` | ✅ | — |
| Legend filament usage (g/m per role/extruder), cost | `GCodeViewer.cpp:2718-2808` | ABI v14 per-extruder volumes/densities/costs → Total Estimation block (time normal+silent, m/g/cost) | ✅ | — |
| Normal vs stealth time | `GCodeViewer.cpp:4569,4662` | ABI v14 `estimated_stealth_seconds` in legend totals | ✅ | — |
| Layer range slider | `IMSlider.hpp:55` | `LayerRangeSlider.swift` | ✅ | — |
| One-layer mode, go-to-layer | `IMSlider.cpp:155`, `IMSlider.hpp:144` | none found | ❌ | UI |
| Add color change / pause / custom G-code at layer | `IMSlider.cpp:79` | none found | ❌ | Bridge (`Model::custom_gcode_per_print_z`, `CustomGCode.cpp` compiled) |
| Move scrubber | `GCodeViewer` sequential slider | `PreviewTabView.swift:118` | ✅ | — |
| G-code line window | `GCodeViewer.hpp:112-154` | none found | ❌ | ABI: `gcode_id` per segment + file mapping |
| Slice progress | notification/progress bar | `SliceService.swift:23`, `PrepareTabView.swift:53` | ✅ | — |
| Cancel slicing | `BackgroundSlicingProcess` | ABI v9 `orca_slice_job` (`PrintBase::cancel`, thread-safe); cancel button in Prepare toolbar (`PrepareTabView.swift`) | ✅ | — |
| Slicing warnings / errors list | `NotificationManager.hpp:85`, `Plater.cpp:5608` | ABI v9 `orca_slice_report`: `Print::validate` (errors refuse the slice, warnings listed), print/object step warnings, G-code processor warnings, path conflicts; `SliceWarningsList` with desktop texts | ✅ | — |
| Export / share G-code | `Plater.cpp:14857` | `ShareLink` in `PreviewTabView.swift` file actions + Prepare slice footer (Save to Files, AirDrop, apps) | ✅ | — |
| Open external G-code (viewer mode) | `PartPlate.cpp:5969` | `PreviewTabView.swift` `.fileImporter` (`.gcode/.g/.gco/.ngc`) → `orca_gcode_load` | ✅ (Files "Open in" document types still missing) | — |
| G-code + project thumbnails | `Plater.cpp` thumbnail callback, `PartPlate` thumbnail | ABI v16: client renders the plate offscreen (`ThumbnailService` → headless `Renderer`), Bridge box-filters to every size the engine's `thumbnails` config requests and to the 512² 3MF plate image | ✅ (BBL printers: engine writes no G-code thumbnail, by design) | — |

## 4. Device / files / app

| Feature | Desktop evidence | OrcaPad evidence | Status | Work |
|---|---|---|---|---|
| Device tab (printer web UI) | `PrinterWebView.hpp:37` | `DeviceTabView.swift`: native printer list + send; no embedded printer web page | 🟡 web UI pending your decision (AGENTS.md bans WebView UI) | — |
| Print hosts (OctoPrint, Moonraker, PrusaLink/Connect, Duet, Repetier, MKS, Elegoo, Flashforge, SimplyPrint, …) | `Utils/PrintHost.cpp:58-73`, `PrintConfig.hpp:80` | `PrintHostService.swift` (URLSession, mirrors desktop's GUI-layer libcurl): OctoPrint `/api/files/local` + Moonraker `/server/files/upload`, upload + optional start print | 🟡 2 of 16 host types; others are typed rejections | Client-reimpl per host |
| Bambu cloud/LAN monitor | `Monitor.cpp` | — | ➖ proprietary network plugin | — |
| OBJ / AMF import | `Plater.cpp` load_files | ABI v10 `orca_plater_import_model` → `Model::read_from_file` | ✅ | — |
| 3MF project load/save | `Plater.cpp:12102,12234,15551` | ABI v11 `orca_project_open` (model + embedded presets + `load_config_model` + plate type, atomic) / `orca_project_save` (`store_bbs_3mf`, `full_config_secure`); Plate ▸ File menu | ✅ single plate (multi-plate projects rejected loudly; no thumbnails yet) | — |
| STEP | `Format/STEP.cpp` (OCCT) | stubbed in `format_stubs.cpp:47-58` | ❌ | Closure: OpenCASCADE (heavy) |
| SVG import | `Format/svg.cpp` (OCCT + nanosvg) | stubbed in `format_stubs.cpp:87` | ❌ | Closure: OCCT |
| DRC | `Format/DRC.cpp` (draco) | stubbed in `format_stubs.cpp:84` | ❌ | Closure: draco (not vendored) |
| Export plate STL/OBJ, printable 3MF | `Plater.cpp:15047` | none found | ❌ | Bridge (STL/OBJ store compiled); 3MF blocked as above |
| Recent projects, auto-backup | `MainFrame.cpp`, `bbs_3mf.cpp` backup manager | projects saved to Files ▸ OrcaPad ▸ Projects; no recent list, backup manager compiled but unused | 🟡 | UI |
| Calibration menu (temp, max flow, PA, flow, retraction, VFA, cornering, input shaping) | `MainFrame.cpp:3328-3478`, `Plater.cpp:12622-13396` | none found | ❌ | Engine `calib.cpp` is compiled, but the models are `.drc` (`Plater.cpp:12634-13359`), so draco is required first |
| Preferences | `Preferences.hpp:31` | none found | ❌ | UI |
| Setup wizard (vendor/printer picking) | `ConfigWizard.cpp` | all system printers are listed | 🟡 | UI |

## Highest-value outstanding items (recommended order)

1. ~~**Bed type (`curr_bed_type`)**~~ ✅ done (ABI v8).
2. ~~Export / share G-code and open external G-code~~ ✅ done (also fixed: re-slicing to the same path never refreshed Preview; imported objects were named "orcapad-import").
3. ~~Slice cancel + warnings list~~ ✅ done (ABI v9; slices now run `Print::validate` like desktop — previously OrcaPad exported G-code desktop would refuse).
4. ~~3MF load/save~~ ✅ done (ABI v10 import of STL/OBJ/AMF/3MF geometry; ABI v11 single-plate project open/save incl. presets + plate type). Follow-ups: multi-plate, project thumbnails.
5. ~~User presets (C5b) + unsaved-changes prompt~~ ✅ done (ABI v12). Physical printers move to item 7 (print hosts).
6. **Arrange / orient / lay-flat**: needs NLopt for Arrange; `Orient.cpp` is a small closure step; lay-flat is client logic on the v7 rotate.
7. ~~Print host upload~~ ✅ OctoPrint + Moonraker done (ABI v15 physical printers via the engine collection; other host types are typed rejections).
8. **Preview ABI v8**: retract/seam/wipe markers, `actual_feedrate`/`layer_duration`/PA/accel/jerk, stealth time and filament statistics. These complete the Types.hpp scheme list.
9. Object list volumes/modifiers, per-object settings, undo/redo, multi-plate: larger Bridge and client-reimpl work.
