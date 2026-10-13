# CONTINUITY — OrcaPad

## PLAN

- Current goal: desktop feature parity over the three-module architecture
  (Swift Client → Bridge → untouched Engine). [USER 2026-10-07: "complete
  feature parity, highest priority first, mark completions in the .md files"]
- [2026-10-13 USER] Gate D: public repo `iSteeb/OrcaPad`. CI runs ONLY on
  `release*` tags and every release goes to EXTERNAL TestFlight (chosen
  over ad hoc OTA; supersedes "every main push"). Secrets loaded by the
  user. Next: user's one-time App Store Connect setup (app record, Test
  Information, external group `External`), then the first release tag;
  later host tests + engine build in CI.
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
  `xcode-27` macOS with Xcode only (XcodeGen + xcodebuild; xtool removed
  from CI after its binary hung at launch) for archive/sign/upload. The
  Apple SDK stays on Apple hardware; self-hosted runners are unsafe on a
  public repo.

## PROGRESS

- [2026-10-13 CODE][TOOL] CI rework: the first run (workflow_dispatch) hung
  35 min in `xtool --version` on the runner and was cancelled. CI is now
  release-tag-only and Xcode-only: Distribution/project.yml (XcodeGen),
  release-testflight.sh (archive/sign/check/export/upload),
  asc_testflight.py (external group + Beta App Review; JWT self-test
  passed locally), PRIVACY.md. Environment `testflight` deploys only
  `release*` tags. UNCONFIRMED until the first release tag runs.
- [2026-10-13 CODE][TOOL] ABI v24 committed (per-layer custom G-code C ABI
  + tests, 51,004 PASS; no client UI yet); Darwin-format engine archive;
  Distribution/ icon + privacy manifest. Apple side by the user: App ID
  ie.duz.OrcaPad, distribution cert, App Store profile, CI key 8XDBKRMA4V.
- [2026-10-06/07 CODE][TOOL] (compressed) Gates A-C6, then ABI v8-v23:
  presets/projects/import, slice jobs, arrange/orient, preview v14,
  printers + upload + printer web UI, thumbnails, undo/redo, volumes,
  transforms, per-object settings, object ops. Host tests 50,962 PASS at
  v23; closure 225 upstream TUs; parity checker gates commits.

## DISCOVERIES

- [2026-10-13 TOOL] The shipped archive had NO symbol index (host GNU ar
  can't read Mach-O): lld tolerated it, Apple's ld rejects it. Fixed in
  build-core.sh, enforced by the audit.
- [2026-10-13 TOOL] App Store needs what xtool omits (asset-catalog icon,
  DT* keys, privacy manifest); Xcode in CI now supplies them. Release binary
  references stat/lstat + NSUserDefaults only (dead-strip drops statfs).
- [2026-10-13 TOOL] xtool 1.20.1's macOS binary hung at launch on the
  `xcode-27` runner (`xtool --version` silent for 35 min).
- [2026-10-13 TOOL] Linux-linked app loads SwiftUICore (iOS 18+) strongly
  despite the iOS 17 target (UNCONFIRMED impact; Xcode links in CI).
- [2026-10-07 CODE] Upstream quirks: Anycubic Vyper profile lacks G92 E0;
  `save_to_json` fails silently on a missing parent dir; physical-printer
  host key is `host_type`.

## OUTCOMES

- [2026-10-06 USER] Gate B on device: builds and slices; rotate UX redone (C6).
- [2026-10-03 USER] Phase 1 accepted: 483,772-triangle STL sliced on device.
- [2026-10-02 USER] Phase 0/2 accepted: native Metal viewer, engine slicing.
