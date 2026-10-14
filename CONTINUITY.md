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

- [2026-10-14] C8 milestone complete (5 parity rows ✅, ABI v25→v26):
  release-0.2.0 run 38526110136 green end to end — build 0.2.0 (5.1)
  uploaded, What to Test set, external group 'External', Beta App Review
  submitted, complete-source archive published. Awaiting: review approval
  + on-device check (marquee drag, part tap, parameter table, preset fix
  from 0.1.1).
- [2026-10-06 USER] Gate B on device: builds and slices; rotate UX redone (C6).
- [2026-10-03 USER] Phase 1 accepted: 483,772-triangle STL sliced on device.
- [2026-10-02 USER] Phase 0/2 accepted: native Metal viewer, engine slicing.
