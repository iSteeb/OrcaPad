# CONTINUITY — OrcaPad

## PLAN

- Current goal: desktop feature parity over the three-module architecture
  (Swift Client → Bridge → untouched Engine). [USER 2026-10-07: "complete
  feature parity, highest priority first, mark completions in the .md files"]
- [2026-10-13 USER] Gate D: public repo `iSteeb/OrcaPad`; every main push →
  TestFlight (chosen over ad hoc OTA). Next: user loads the `testflight`
  environment secrets, first CI run, install from TestFlight on iPoke; later
  host contract tests + engine cross-build in CI.
- Parity source of truth: `Bridge/tools/parity-manifest.toml` → generated
  PARITY.md "Remaining work" (551 desktop items, 152 features, 33% at v24).
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
- [2026-10-13] CI on GitHub-hosted runners only: Linux for the gates,
  `xcode-27` macOS for build/sign/upload. The Apple SDK stays on Apple
  hardware; self-hosted runners are unsafe on a public repo.

## PROGRESS

- [2026-10-13 CODE][TOOL] Gate D: ABI v24 WIP committed (per-layer custom
  G-code C ABI + tests, 51,004 PASS; Swift expectation 24; no client UI yet).
  Engine archive in Darwin format with `__.SYMDEF` (llvm-ar). Distribution/:
  AppIcon catalog, PrivacyInfo.xcprivacy, package-testflight.sh; workflow
  testflight.yml (actionlint + shellcheck clean). Apple side done by user:
  App ID ie.duz.OrcaPad, Apple Distribution cert, App Store profile, CI API
  key 8XDBKRMA4V. UNCONFIRMED until the first run: Apple link + upload.
- [2026-10-07 CODE][TOOL] ABI v17–v23 (compressed): printer web UI, undo/redo
  + transactional mutations, volumes, mirror/clipboard/view presets, group
  transforms, per-object settings, object ops, slice warning-level fix. Host
  tests 50,962 PASS at v23; parity checker gates commits.
- [2026-10-07 CODE][TOOL] ABI v8–v16: plate type, slice jobs/validate/
  warnings, import_model, projects, user presets, arrange/orient/lay flat,
  preview v14, physical printers + upload, thumbnails. Closure: 225 upstream
  TUs (3mf, NSVG, Emboss, Arrange, libnest2d, NLopt 2.5.0, Boost.Thread).
- [2026-10-06 CODE][TOOL] Gates A–C6 (compressed): contract suite + audit,
  stable IDs/revisions/snapshots, four-tab shell, Prepare editor, Preview.

## DISCOVERIES

- [2026-10-13 TOOL] Host GNU ar cannot read Mach-O, so the shipped archive
  had NO symbol index: lld tolerated it, Apple's ld rejects it. Fixed at the
  source (build-core.sh), enforced by the audit.
- [2026-10-13 TOOL] App Store needs what xtool omits: asset-catalog icon
  (actool, macOS only), DT* toolchain keys (Linux-built resource bundles
  carry placeholders such as DTXcodeBuild 99T999), privacy manifest. The
  RELEASE binary references stat/lstat + NSUserDefaults only; debug builds
  also pull statfs/fstat from boost.filesystem (dead-strip removes them).
- [2026-10-13 TOOL] The Linux-linked app loads SwiftUICore (iOS 18+) strongly
  despite the iOS 17 target; the SDK's SwiftUICore.tbd is arm64e-only with
  allowable-clients. Watch the first Apple-linked build (UNCONFIRMED impact).
- [2026-10-07 CODE] Upstream quirks: Anycubic Vyper profile lacks G92 E0;
  `save_to_json` fails silently on a missing parent dir; physical-printer
  host key is `host_type`; expat include path had pointed nowhere (fixed).

## OUTCOMES

- [2026-10-06 USER] Gate B on device: builds and slices; rotate UX redone (C6).
- [2026-10-03 USER] Phase 1 accepted: 483,772-triangle STL sliced on device.
- [2026-10-02 USER] Phase 0/2 accepted: native Metal viewer, engine slicing.
