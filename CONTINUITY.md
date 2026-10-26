# CONTINUITY — OrcaPad

## PLAN

- [2026-10-15 USER] Approved plan (execute -> release-0.5.0):
  A1 camera reset = fit focused bed; A2 general config finalization at the
  Bridge slice boundary (desktop full_config semantics: per-filament vector
  padding, matrix-shape validation, repairs as report warnings) + find/fix
  the preset-save vector poisoning + regression tests; A3 desktop-parity
  pass over shipped features; B multi-filament cluster (B1 Bridge filament
  list + selection, B2 plater filament bar, B3 object/part extruder
  assignment + per-extruder colors, B4 flushing volumes editor + per-object
  flush-into, B5 per-extruder vector editors); tag release-0.5.0 after all
  gates. NO upstream writeup.

- [2026-10-14 USER] Feature priority = app "feels complete": high-traffic
  interactions (transforms, core loop) BEFORE raw parity %. Release flow:
  tag after local gates, NO pre-tag device install - iPoke gets builds via
  TestFlight.

- Current goal: desktop feature parity over the three-module architecture
  (Swift Client → Bridge → untouched Engine). [USER 2026-10-07: "complete
  feature parity, highest priority first, mark completions in the .md files"]
- [2026-10-13 USER] Gate D: public repo `iSteeb/OrcaPad`. CI runs ONLY on
  `release*` tags and every release goes to EXTERNAL TestFlight (chosen
  over ad hoc OTA; supersedes "every main push"). Secrets loaded by the
  user. Next: user's one-time App Store Connect setup (app record, Test
  Information, external group `External`), then the first release tag;
  later host tests + engine build in CI.
- [2026-10-14 USER] New: AGPL/App Store compliance plan in COMPLIANCE.md
  (Gate E in PLANS.md). Constraints: NO licensing waivers/permissions from
  upstream holders; app stays free/open (repo is public, AGPL-3.0). Plan
  pillars: notices+attribution, per-release complete-source archive (GitHub
  tag tarballs lack submodule contents — must attach vendored tarball),
  in-app About/Licenses screen, license-inventory CI gate (LGPL trio:
  libnoise, nlopt 2.5.0, libnest2d — upstream-parity static-link position),
  BUILDING.md, §8 30-day cure protocol. Residual risk (Apple EULA conflicts,
  FSF position) accepted and documented; §13 N/A (no server).
- [2026-10-14] IMPLEMENTED all of Gate E (W1–W6): README+BUILDING+metadata
  template, SPDX on 97 files (orca_bridge.h excluded — byte-mirrored into
  Prebuilt), AboutView + ORCAPAD_SOURCE_REF (PlistBuddy in
  release-testflight.sh, checked post-archive), license-inventory.sh gate
  (312 TUs + host-header rows: CGAL 6.1.1 GPL-3+, GMP, MPFR, Eigen, boost
  headers — all vendored into the release archive by
  make-source-archive.sh with Prebuilt/HOST-HEADERS.txt provenance stamp,
  verify job now ubuntu-26.04 + gh release publish). DISCOVERY: engine
  compiles against HOST headers (gen/ symlinks) — they are part of the
  binary and Corresponding Source. Pushed to main, NO release tag
  [USER 2026-10-14: more changes pending — other agent's preset/ABI v25
  work continues in the same tree; its files (orca_bridge.{h,cpp},
  contract_tests.cpp, PresetStore.swift, Prebuilt archive) left
  uncommitted for it to finish and commit]. Local Prebuilt/.a was relinked
  (my comment TUs + its v25 objects) — NOT committed; next agent must
  rebuild/commit the archive for v25.
- Parity source of truth: `Bridge/tools/parity-manifest.toml` → generated
  PARITY.md "Remaining work" (551 desktop items, 152 features, 36% at v27;
  next: slice-all plates, then rotate/scale/lay-flat polish, prepare
  multi-filament and preview per-layer color).
- [2026-10-07 USER] Order: Device printer web UI, then plate/object editing →
  prepare/presets → Files integration → preview. Deferred by user: STEP/SVG,
  Draco, Calibration menu, mesh boolean. User device verification of v8+
  still pending.

## DECISIONS

- [2026-10-06 USER] Three modules, one-way deps; engine never patched; raw ABI
  only in `Sources/OrcaBridge`; C++ session is the sole authority; lock order
  plater → presets; engine entry process-serialized (`ObjectBase` IDs).
- Desktop logic living in GUI code is reimplemented at the matching layer:
  presentation → client; engine orchestration → Bridge C++ via engine helpers.
- [2026-10-07] Import recenters the imported group; project open keeps exact
  placements; arrange overflow parked beside the bed; lay flat = tap a facet;
  physical printers in the engine's PhysicalPrinterCollection; upload =
  URLSession per host (OctoPrint + Moonraker); thumbnails rendered once by
  the client, box-filtered per engine size in the Bridge. Device tab may
  embed the printer's own web page (scoped AGENTS.md exception).
- [2026-10-13 USER] Repo public with AGPL-3.0 LICENSE (verbatim upstream);
  history rewritten to the GitHub noreply address (all older SHAs changed,
  docs remapped). TestFlight builds use the canonical `ie.duz.OrcaPad` App ID
  (xtool keeps `XTL-C93C0481.ie.duz.OrcaPad`, whose profiles it deletes and
  recreates). Icon = user artwork, not OrcaSlicer's logo (impersonation
  risk). Export compliance: no non-exempt encryption.
- [2026-10-14 USER] No licensing waivers ever (no upstream exceptions,
  no relicensing asks). Compliance = everything in our control + documented
  risk acceptance; enforcement reality (SFC targets closed black boxes,
  fully-sourced forks respected) recorded in COMPLIANCE.md §2.
- [2026-10-13] CI on GitHub-hosted runners only: Linux for the gates,
  `xcode-27` macOS with Xcode only (XcodeGen + xcodebuild; xtool removed
  from CI after its binary hung at launch) for archive/sign/upload. The
  Apple SDK stays on Apple hardware; self-hosted runners are unsafe on a
  public repo.

## PROGRESS

- [2026-10-26 CODE] Review-fix sweep (comprehensive audit of Bridge +
  client): ABI v31->v32. Bridge: orca_presets_set_value now parses into a
  clone and returns typed INVALID_CONFIGURATION on parse failure (upstream
  deserializers write 0 into numeric values when extraction fails);
  custom G-code binds to the SELECTED plate (model.curr_plate_index synced
  with the Bridge current plate — Print::apply used to consume plate 0's
  codes for every plate); single-plate slices set {plate_name}; slice-all
  assembles in a temp + atomic rename (a failed run keeps the previous
  output, never a partial file) with marker-safe plate names; set_bed under
  the engine mutex; physical-printer upsert REPLACES preset ties. Facade:
  copy/cut no longer rejected by the revision guard (clipboard ops take no
  revision — copy was broken on every non-empty document); new
  EngineGcode.loadPlateSections splits ORCA_PLATE marker files and offsets
  each plate back to its world origin. Client: first-run Slice guard until
  a listed printer is selected; preset/resolved-config ops reject with a
  message while slicing (they used to silently queue on the engine mutex);
  per-file G-code naming (sanitized, never overwritten) + Send-any-file;
  slice-all preview sections + Plates menu + jump-to-layer; Slice button on
  the Plate pill + auto-jump to Preview on completion; marquee-mode orbit;
  Move-to-plate object menu; inverted-hull selection outline; multi-file
  import; background 3MF autosave + launch restore; writable data dir
  moved to Application Support (API keys out of Files-visible Documents,
  legacy tree migrated once); print-host uploads carry per-plan state (no
  static leaks across hosts); Device web view locked to the printer's own
  host (links open in Safari). Gates: host 51,491 PASS, core archive
  rebuilt, xtool green 0 warnings, audit PASS, parity 42% (54 done).

- [2026-10-15 CODE] ABI v31 + C10 (multi-filament, parity 51 done 40%):
  filament slots/count/per-slot preset+colour API, FilamentBar, object
  extruder assignment + slot tinting, FlushingVolumesSheet,
  per-element vector editors, config finalization on every slice path
  (0.2.0 crash class), camera reset = fit focused bed. Release 0.5.0.
- [2026-10-14 CODE] ABI v30 + C9d (fill bed, parity 48 done 38%):
  orca_plater_fill_bed (desktop FillBedJob formula; clones marked
  bed_idx=256 — UNARRANGED skips them), instances variant, overflow
  dropped, one undo step; Plate tab Fill bed button. Plus Device tab
  all-printers sidebar with live reachability probes. UNCONFIRMED on
  device.
- [2026-10-14 CODE] ABI v29 + C9c (transform polish, parity 47 done 37%):
  rotate snap zones (desktop GLGizmoRotate 45/5/free by drag distance) +
  relative-angle entry; scale per-axis on-canvas handles; Flatten gizmo
  hull planes (Bridge grouping + translucent rendering + touch-hover
  highlight). UNCONFIRMED on device (TestFlight will carry it).
- [2026-10-14 CODE] ABI v28 + C9b (slice-all, parity 44 done): engine
  plate context fixed on EVERY slice — upstream `Print::m_origin` is
  UNINITIALIZED (desktop always calls PartPlate::set_print; our Bridge
  now sets origin/index/name; per-plate G-code is plate-relative),
  `orca_plater_slice_all_to_gcode[_with_presets]` → one G-code with
  `; ORCA_PLATE index/name begin/end` markers, aggregated report,
  cross-plate progress; Prepare Slice menu "Slice All Plates"; preview
  shifts single-plate results by the plate origin. plate.multi-plate ✅.
  UNCONFIRMED on device.
- [2026-10-14 CODE] ABI v27 + C9 (plates + open-in, 51,326 host checks
  PASS, archive 312 TUs, build/audit/parity green, 36% parity, 43 done):
  Bridge plate grid (ceil-sqrt cols, 1.2x stride, max 36) with derived
  membership (locked pins), plate_add/delete/rename/lock/move-to-front/
  duplicate/select + set_bed; arrange overflow → new plates (locked = fixed
  obstacles via arrange's excluded set); slice filters to the selected
  plate (typed failure when empty); 3MF roundtrip adopts names/locks/
  membership from the engine's PlateData; client: PlateBar chips, current
  plate = rendered bed (viewer anchors to it), inactive plates dimmed,
  frameScene = current plate; Open-in via CFBundleDocumentTypes +
  onOpenURL (models import, 3MF = project flow). UNCONFIRMED on device.
- [2026-10-14 CODE] ABI v26 + C8 (selection/clipboard/part parity, parity
  33%→36% cumulative): marquee select + one-step group delete, multi-object
  clipboard + cut, canvas part selection via merged-triangle ranges,
  Copy/Paste Process Settings (one-step replace), parameter table,
  frequent-settings menu, object-list Settings rows.
- [2026-10-13/14, compressed] Gate E compliance landed (SPDX, license gate,
  source archive, About view); release-0.1.1 shipped end to end (run
  38413247330: external group + Beta App Review submitted; approval +
  on-device preset-fix check pending). ABI v25 select_machine fixed the
  fresh-install preset bug.

## DISCOVERIES

- [2026-10-13 TOOL] The shipped archive had NO symbol index (host GNU ar
  can't read Mach-O): lld tolerated it, Apple's ld rejects it. Fixed in
  build-core.sh, enforced by the audit.
- [2026-10-13 TOOL] App Store needs what xtool omits (asset-catalog icon,
  DT* keys, privacy manifest); Xcode in CI now supplies them. Release binary
  references stat/lstat + NSUserDefaults only (dead-strip drops statfs).
- [2026-10-13 TOOL] xtool 1.20.1's macOS binary hung at launch on the
  `xcode-27` runner (`xtool --version` silent for 35 min).
- [2026-10-13 TOOL] Linux-linked (lld) app loads SwiftUICore (iOS 18+)
  strongly despite the iOS 17 target; the Xcode-linked release build
  loads SwiftUI only, so shipped builds are unaffected.
- [2026-10-07 CODE] Upstream quirks: Anycubic Vyper profile lacks G92 E0;
  `save_to_json` fails silently on a missing parent dir; physical-printer
  host key is `host_type`.

## OUTCOMES

- [2026-10-26] Review-fix sweep complete (parity 40%->42%, 51->54 done):
  every bug from the Bridge+client audit fixed - copy/cut, silent preset
  value reverts, slice-all preview overlap + partial outputs, print-host
  static-state leaks, per-plate custom G-code, first-run slice guard,
  preset-ops-while-slicing messaging, selection outline, move-to-plate,
  autosave, API keys out of Files-visible storage, printer-web host lock.
  Awaiting device verification via TestFlight.

- [2026-10-19] UI round 7: SETUP WIZARD (desktop ConfigWizard parity, the
  user's 'global filter' intent): SetupWizardSheet from the Prepare pill
  (wand) - vendor-grouped printer checklist, then searchable filament
  checklist with compatible-with-picked-printers pre-checked; sets
  persist (UserDefaults installed-sets) and drive EVERY preset list
  (pill pages + slot picker show only installed system presets, user/
  project always). prepare.setup-wizard done (52 done). release-0.7.4.

- [2026-10-19] UI round 6: Slice button back (first-class in the Prepare
  pill, primary style - it died with the hidden nav toolbar); all pills
  clip content (clipShape Capsule + inner padding - no overflow when
  scrolling); plate bar bottom gap to the tab bar; filament chips are
  44pt targets opening a FAST searchable compatibility-filtered picker
  sheet (the inline Menu with hundreds of buttons was slow + tiny);
  GLOBAL preset filter toggle in the Prepare pill (desktop Preferences
  parity, @AppStorage, applies to pill lists + slot picker).
  release-0.7.3.

- [2026-10-19] UI round 5: page chips only in the pill (internal PageStrip
  hidden when pill-driven), in-content settings search restored (nav bar
  hidden), preset lists searchable + compatibility-filtered (desktop combo
  parity, show-incompatible toggle), MOVE live-values root cause fixed
  (missing onBegin -> manipulationBase nil; rotate/scale worked because
  they called it), rotate angle field flexible + icon apply button,
  inactive plates render as dimmed mini-beds (border + sparse grid).
  release-0.7.2.

- [2026-10-19] UI round 4 (user feedback, Prepare + Plate): Prepare pill
  DRIVES the page (tap-cycling mode toggle with per-kind memory; kind
  buttons switch pages - printer page = preset list + plate type +
  volume + settings defaulting to first page; filament/process
  likewise). Plate: manipulation header rebuilt (2-row clean block,
  compact extruder chip - the vertical-letters bug), rotate steppers
  equalized + Rotate never wraps, numeric fields flexible monospaced,
  live gesture values hardened (panel observes presentationRevision),
  bounded text shrinks instead of wrapping (global rule, also preview
  readouts). release-0.7.1.

- [2026-10-19] UI round 3 (user TestFlight feedback, 8 items): pill bars
  SCROLLABLE with first-class tools (Plate: undo/redo/menu/arrange/fill/
  orient + gizmo modes + filament chips inline; Preview: de-nested
  toggles; Prepare: mode-per-kind memory + kind buttons + page chips);
  live gesture value updates; uniform-only scale drag; move/rotate/scale
  panels rebuilt (comfortable rows, consistent buttons); nav titles
  hidden (bottom tab identifies the page). release-0.7.0.

- [2026-10-19] UI overhaul round 2 (user device feedback, 7 items):
  multi-plate rendering restored (dimmed beds + faded objects); Plate tab
  chrome = one wide pill (Undo/Redo | Menu(file+objects) | Arrange |
  Tools), left rail removed; tools = collapsible half-modal (collapsed
  touch / expanded numeric, tap-model cycles rotate axis); Preview tab
  = same top pill (Scheme | View | Open | Share), left dock removed,
  layer-slider hitboxes track-level (overlap bug fixed), legend off by
  default; Device tab = same pill bar + PrusaLink (digest) beside
  Duet/FlashAir. release-0.6.0.

- [2026-10-19] Verification + UI pass: VERIFICATION.md records the
  feature-by-feature desktop-equivalence audit (62 features). 3 real
  divergences fixed (arrange distance default 0 brim-aware, fill-bed same,
  orient per-object threshold precedence); UI chrome unified (ChromeTool
  tokens across action bar + gizmo toolbar, About into File menu, Rotate
  panel adaptive for narrow widths, filament chips bounded). 51,473 host
  checks PASS.

- [2026-10-19] C10 milestone complete (multi-filament + polish, ABI v30->31,
  parity 38%->40%, 51 done): release-0.5.0 run 39243764031 green end to
  end - both jobs green, external group + Beta App Review submitted.
  Carries: multi-filament slots/bar/assignment/flush editor/vector
  editors, config finalization (0.2.0 crash class), camera reset = fit
  bed, plate-background + empty-plate fixes, all-printers device tab,
  fill bed, flatten planes, rotate/scale polish, slice-all. Awaiting:
  review approval + on-device checks.

- [2026-10-14] C9 milestone complete (plates + open-in, ABI v26→v27,
  files.open-in ✅, plate.multi-plate 🟡 major): release-0.3.0 run
  38570936772 green end to end — build 0.3.0 (6.1) uploaded, external
  group, Beta App Review submitted, source archive published. Awaiting:
  approvals (0.2.0 + 0.3.0) + on-device checks (marquee/part tap/parameter
  table; plate bar, plate slicing, open-in).
- [2026-10-14] C8 milestone complete (5 parity rows ✅, ABI v25→v26):
  release-0.2.0 run 38526110136 green end to end — build 0.2.0 (5.1)
  uploaded, What to Test set, external group 'External', Beta App Review
  submitted, complete-source archive published. Awaiting: review approval
  + on-device check (marquee drag, part tap, parameter table, preset fix
  from 0.1.1).
- [2026-10-06 USER] Gate B on device: builds and slices; rotate UX redone (C6).
- [2026-10-03 USER] Phase 1 accepted: 483,772-triangle STL sliced on device.
- [2026-10-02 USER] Phase 0/2 accepted: native Metal viewer, engine slicing.
