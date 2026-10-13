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

- [2026-10-13 TOOL] First release `release-0.1.0` (run 38395092119): Xcode
  archive, App Store signing, export, altool validate + UPLOAD SUCCEEDED
  for 0.1.0 (2.1) to app "OrcaPad Slicer" (ASC id 6822246784). Only the
  external submission failed: no TestFlight group `External` yet (the UI
  showed no External Testing section before the first build existed).
- [2026-10-13 CODE][TOOL] CI rework: the first run (workflow_dispatch) hung
  35 min in `xtool --version` on the runner and was cancelled. CI is now
  release-tag-only and Xcode-only: Distribution/project.yml (XcodeGen),
  release-testflight.sh (archive/sign/check/export/upload),
  asc_testflight.py (external group + Beta App Review; JWT self-test
  passed locally), PRIVACY.md. Environment `testflight` deploys only
  `release*` tags. Scratch-branch dry run (no secrets): XcodeGen +
  unsigned xcodebuild archive OK in ~1 min; Info.plist, icons, privacy
  manifest, DT keys correct; Apple ld links the engine and SwiftUI (not
  SwiftUICore). Signing/export/upload/submission UNCONFIRMED until the
  first release tag.
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
- [2026-10-13 TOOL] Linux-linked (lld) app loads SwiftUICore (iOS 18+)
  strongly despite the iOS 17 target; the Xcode-linked release build
  loads SwiftUI only, so shipped builds are unaffected.
- [2026-10-07 CODE] Upstream quirks: Anycubic Vyper profile lacks G92 E0;
  `save_to_json` fails silently on a missing parent dir; physical-printer
  host key is `host_type`.

## OUTCOMES

- [2026-10-06 USER] Gate B on device: builds and slices; rotate UX redone (C6).
- [2026-10-03 USER] Phase 1 accepted: 483,772-triangle STL sliced on device.
- [2026-10-02 USER] Phase 0/2 accepted: native Metal viewer, engine slicing.
