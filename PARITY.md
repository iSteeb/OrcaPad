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
| Import model (STL) | `Plater.cpp` load_files | `PlateTabView.swift:82` (`ImportTypes.stl`) | ✅ | — |
| Delete / delete all | `GLCanvas3D.cpp` toolbar | `DocumentStore.swift:136,143` | ✅ | — |
| Add/remove instances ("more/fewer") | `GLCanvas3D.cpp:6812,6824` | `DocumentStore.swift:116,129` | ✅ | — |
| Move gizmo + panel | `GizmoObjectManipulation.cpp:731` (X/Y/Z, world/object) | `PlateTabView.swift:357` X/Y + center | 🟡 Z and the world/object coordinate switch are omitted on purpose (user decision; the engine rests the object on the bed) | — |
| Rotate gizmo (3 rings, coarse/fine snap) | `GLGizmoRotate.cpp:33-36,114` | `Renderer.swift` ring for the selected axis; fixed 5° snap | 🟡 one ring at a time; no fine 1° snap zone | UI |
| Rotate panel (relative X/Y/Z input, reset) | `GizmoObjectManipulation.cpp:890,966,558` | `PlateTabView.swift:382` axis picker + glyph, ±15°, reset | 🟡 no free-angle relative entry | UI |
| Scale gizmo (per-axis handles) | `GLGizmoScale.cpp` | on-canvas handles are uniform only | 🟡 | UI |
| Scale panel (per-axis %, size, uniform lock) | `GizmoObjectManipulation.cpp:1095,1190-1276` | `PlateTabView.swift:494` | ✅ local axes only | — |
| Arrange | `GLCanvas3D.cpp:6788`, `Plater.cpp:17077` | none found | ❌ | Closure: `Arrange.cpp` needs libnest2d (vendored) + **NLopt** (not vendored) |
| Auto-orient | `GLCanvas3D.cpp:6766`, `Plater.cpp:10912` | none found | ❌ | Closure: `Orient.cpp` only needs the existing tbb shim |
| Lay on face (Flatten) | `GLGizmosManager.cpp:209` | `PlateTabView.swift:257` placeholder | ❌ | Client-reimpl: plane search lives in the GUI gizmo; convex hull is compiled; v7 rotate can apply the result |
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
| Revert to saved (user preset level) | `Tab.cpp:1143` | needs user presets | ❌ | Blocked on C5b |
| Search | `Search.hpp:91` (global, all tabs) | per-screen `.searchable` | 🟡 | UI |
| Compare presets | `UnsavedChangesDialog.hpp:408`, `Tab.cpp:6626` | none found | ❌ | UI (config_dump already exists) |
| Save / rename / delete / detach user presets | `Tab.cpp:6663,6801`; `Preset.cpp:2865,2983` | none found | ❌ (C5b) | Bridge (`Preset.cpp` is compiled) |
| Unsaved-changes prompt when switching presets | `UnsavedChangesDialog.hpp:266` | edits are discarded silently on select | ❌ | UI + C5b |
| Physical printers (host/URL) | `PhysicalPrinterDialog.hpp:27` | none found | ❌ | Bridge (`PhysicalPrinter` in Preset.cpp) — a Device-tab prerequisite |
| Import / export configs, bundles | `MainFrame.cpp:2762,2804,3688,3723` | none found | ❌ | Bridge |
| Resolved-config inspector | (no desktop equivalent) | `ResolvedConfigView.swift` | ✅ extra | — |

## 3. Preview / G-code viewer / slicing

| Feature | Desktop evidence | OrcaPad evidence | Status | Work |
|---|---|---|---|---|
| Schemes: FeatureType, Speed, Height, Width, Fan, Temperature | `libvgcode/include/Types.hpp:80-102` | `GcodePreviewStore.swift:8-13` | ✅ | — |
| VolumetricFlowRate | same | none found | ❌ | UI (`mm3_per_mm × feedrate` is already exported) |
| ActualSpeed, ActualVolumetric, LayerTime lin/log, PA, Accel, Jerk | same | none found | ❌ | ABI: export `actual_feedrate`, `layer_duration`, `pressure_advance`, `acceleration`, `jerk` (`GCodeProcessor.hpp:194-208`) |
| Tool / ColorPrint / Summary | same | none found | ❌ | UI for Tool (`extruder` exported); ColorPrint needs color changes |
| Travel toggle | `Types.hpp:168` | `PreviewTabView.swift:225` dock | ✅ | — |
| Wipes, retractions, unretractions, seams, tool/color changes, pauses, custom G-code | `Types.hpp:169-176` | the bridge filters to Extrude/Travel only (`orca_bridge.cpp:1336,1372`) | ❌ | ABI: keep the other `EMoveType`s as markers |
| Center of gravity, shells | `Types.hpp:177-179`, `GCodeViewer.cpp:2476` | none found | ❌ | UI (shells can reuse Plate meshes) |
| Tool marker | `Types.hpp:179` | `ToolpathRenderer` marker | ✅ | — |
| Legend with per-feature toggles, time, % | `GCodeViewer.cpp:3111` | `PreviewTabView.swift:148-200` | ✅ | — |
| Legend filament usage (g/m per role/extruder), cost | `GCodeViewer.cpp:2718-2808` | none found | ❌ | ABI: `PrintEstimatedStatistics` |
| Normal vs stealth time | `GCodeViewer.cpp:4569,4662` | normal only | ❌ | ABI: `time[Stealth]` |
| Layer range slider | `IMSlider.hpp:55` | `LayerRangeSlider.swift` | ✅ | — |
| One-layer mode, go-to-layer | `IMSlider.cpp:155`, `IMSlider.hpp:144` | none found | ❌ | UI |
| Add color change / pause / custom G-code at layer | `IMSlider.cpp:79` | none found | ❌ | Bridge (`Model::custom_gcode_per_print_z`, `CustomGCode.cpp` compiled) |
| Move scrubber | `GCodeViewer` sequential slider | `PreviewTabView.swift:118` | ✅ | — |
| G-code line window | `GCodeViewer.hpp:112-154` | none found | ❌ | ABI: `gcode_id` per segment + file mapping |
| Slice progress | notification/progress bar | `SliceService.swift:23`, `PrepareTabView.swift:53` | ✅ | — |
| Cancel slicing | `BackgroundSlicingProcess` | none found | ❌ | Bridge (`PrintBase::cancel`) |
| Slicing warnings / errors list | `NotificationManager.hpp:85` | none found (only hard failures surface) | ❌ | ABI: `Print::validate` warnings, processor warnings |
| Export / share G-code | `Plater.cpp:14857` | none found (the file stays in the sandbox) | ❌ | UI (ShareLink / fileExporter) |
| Open external G-code (viewer mode) | `PartPlate.cpp:5969` | `orca_gcode_load` exists; no importer | ❌ | UI |
| G-code thumbnails | `Plater.cpp` thumbnail callback | `orca_bridge.cpp:1489` passes `nullptr` | ❌ | Client renders offscreen in Metal + ABI callback (`Thumbnails.cpp` is compiled) |

## 4. Device / files / app

| Feature | Desktop evidence | OrcaPad evidence | Status | Work |
|---|---|---|---|---|
| Device tab (printer web UI) | `PrinterWebView.hpp:37` | `DeviceTabView.swift` placeholder | ❌ | **Decision:** AGENTS.md bans WebView *UI*; embedding the printer's own page needs your OK |
| Print hosts (OctoPrint, Moonraker, PrusaLink/Connect, Duet, Repetier, MKS, Elegoo, Flashforge, SimplyPrint, …) | `Utils/PrintHost.cpp:58-73`, `PrintConfig.hpp:80` | none found | ❌ | Client-reimpl (these are GUI-side libcurl HTTP; native URLSession) |
| Bambu cloud/LAN monitor | `Monitor.cpp` | — | ➖ proprietary network plugin | — |
| OBJ / AMF import | `Plater.cpp` load_files | `OBJ.cpp`, `AMF.cpp` compiled; only `orca_plater_add_stl` exposed | ❌ | Bridge only |
| 3MF project load/save | `Plater.cpp:12102,12234,15551` | stubbed in `format_stubs.cpp:24-28,79` | ❌ | Closure: `3mf.cpp`/`bbs_3mf.cpp` need miniz + expat (both vendored) + boost property_tree (header-only) |
| STEP | `Format/STEP.cpp` (OCCT) | stubbed in `format_stubs.cpp:47-58` | ❌ | Closure: OpenCASCADE (heavy) |
| SVG import | `Format/svg.cpp` (OCCT + nanosvg) | stubbed in `format_stubs.cpp:87` | ❌ | Closure: OCCT |
| DRC | `Format/DRC.cpp` (draco) | stubbed in `format_stubs.cpp:84` | ❌ | Closure: draco (not vendored) |
| Export plate STL/OBJ, printable 3MF | `Plater.cpp:15047` | none found | ❌ | Bridge (STL/OBJ store compiled); 3MF blocked as above |
| Recent projects, auto-backup | `MainFrame.cpp`, `remove_backup` stub | none found | ❌ | Client + 3MF |
| Calibration menu (temp, max flow, PA, flow, retraction, VFA, cornering, input shaping) | `MainFrame.cpp:3328-3478`, `Plater.cpp:12622-13396` | none found | ❌ | Engine `calib.cpp` is compiled, but the models are `.drc` (`Plater.cpp:12634-13359`), so draco is required first |
| Preferences | `Preferences.hpp:31` | none found | ❌ | UI |
| Setup wizard (vendor/printer picking) | `ConfigWizard.cpp` | all system printers are listed | 🟡 | UI |

## Highest-value outstanding items (recommended order)

1. ~~**Bed type (`curr_bed_type`)**~~ ✅ done (ABI v8).
2. **Export / share G-code** and **open external G-code**: UI-only. Without them the core loop never leaves the device.
3. **Slice cancel + warnings list**: Bridge (`PrintBase::cancel`, validate warnings). This folds into immutable slice jobs.
4. **3MF load/save**: Closure work with vendored dependencies only. It unlocks projects, multi-plate persistence and Bambu-style files.
5. **User presets (C5b)** + unsaved-changes prompt + physical printers: Bridge over compiled `Preset.cpp`.
6. **Arrange / orient / lay-flat**: needs NLopt for Arrange; `Orient.cpp` is a small closure step; lay-flat is client logic on the v7 rotate.
7. **Print host upload (Moonraker/OctoPrint/PrusaLink)**: native networking, needs the physical-printer model from item 5.
8. **Preview ABI v8**: retract/seam/wipe markers, `actual_feedrate`/`layer_duration`/PA/accel/jerk, stealth time and filament statistics. These complete the Types.hpp scheme list.
9. Object list volumes/modifiers, per-object settings, undo/redo, multi-plate: larger Bridge and client-reimpl work.
