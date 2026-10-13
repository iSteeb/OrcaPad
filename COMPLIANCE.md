# COMPLIANCE.md — AGPL-3.0 and App Store distribution

Status: **implemented** (2026-10-14), living document — the first
release under this plan ships when the remaining feature work is ready
(release tagging deliberately withheld [USER 2026-10-14]). This is
engineering compliance work, not legal advice. Decision [USER 2026-10-14]:
**no licensing waivers** — no contributor exceptions, no relicensing, no
special permission from upstream holders. The plan therefore maximizes
compliance with everything in our control and manages the residual risk
honestly.

---

## 1. What we distribute, under what terms

- The shipped binary (TestFlight now, App Store later) is one combined work:
  engine (pinned OrcaSlicer v2.4.2, AGPL-3.0) + Bridge adapters + Swift
  client. Root `LICENSE` = verbatim AGPL-3.0 covering the entire repo
  (§5(c): the whole work is licensed AGPL — satisfied; our own files get
  SPDX headers in W1).
- Upstream lineage to attribute: Slic3r → PrusaSlicer → Bambu Studio →
  OrcaSlicer (© their contributors; notices retained by keeping
  `upstream/orcaslicer` byte-clean). One wrinkle discovered during
  implementation: the engine closure also compiles against **host system
  headers** (boost 1.90, Eigen 3, CGAL 6, GMP, MPFR — vendored by
  `Bridge/build-core.sh` into the build's `gen/`), so CGAL (GPL-3.0+ core)
  and the rest are part of the distributed binary and its Corresponding
  Source. They are inventoried (W4) and vendored into every release source
  archive with a provenance stamp (W2).
- **AGPL §13 (remote network interaction): NOT triggered.** The engine runs
  on-device; we operate no server executing the covered work. The Device
  tab embedding the printer's own web UI conveys no covered work.
  Standing condition: any future server-side feature that executes the
  covered work (cloud slicing) activates §13 — revisit this file first (W8).
- Distribution channels are Apple's: TestFlight terms / Standard EULA. We
  cannot alter them (that is the root of §2 below).

## 2. The App Store conflict, stated honestly

- **FSF position** (2010 GNU Go enforcement, still cited): Apple's store
  terms (usage rules, the then-5-device cap, mandatory ToS acceptance, DRM)
  are "further restrictions" prohibited by the GPL/AGPL no-further-
  restrictions clauses; FSF extends the analysis to all GPL/AGPL versions,
  considers *Apple* the violator, and sought term changes. Outcome then:
  Apple pulled the app. **No court has ever ruled on this question.**
- **Changed since 2010**: the 5-device cap is gone (any Apple products you
  own or control); the current Standard EULA §a carves out the copy /
  modify / reverse-engineer restrictions "to the extent … permitted by the
  licensing terms governing use of any open-sourced components included
  with the Licensed Application"; users can build and sideload their own
  builds (free developer signing, EU DMA alternative marketplaces); many
  AGPL/GPL apps ship today unchallenged (Signal, Element, Mastodon,
  RetroArch, iSH…).
- **Residual conflicts we cannot remove** (they live in Apple's paper, not
  ours): the EULA transfer/redistribution ban and Apple-device use grant;
  FairPlay signature; the §6 "Installation Information" question for User
  Products (counter-position: §6's carve-out for channels where no party
  retains the ability to install modified object code, plus the documented
  build-your-own path in W5). This is an **unresolved question of law**.
- **Enforcement reality in this exact community**: SFC/Prusa enforcement
  targets closed-source black boxes (Bambu Studio's proprietary networking
  plugin, confirmed AGPLv3 violation 2026). Bambu's own statement: forking
  and redistributing OrcaSlicer-derived code "is fully respected".
  Fully-sourced AGPL forks (ElegooSlicer, MobileSlicer) ship unchallenged.
  Both historical App Store removals (GNU Go 2010, VLC 2011) were
  rights-holder complaints to Apple — not lawsuits; VLC later returned via
  dual-licensing, which is a waiver route we have excluded.
- **Risk accepted** [USER 2026-10-14]: realistic worst case is a
  rights-holder complaint → Apple removes the listing; the §8 cure path
  (W7) then applies. Litigation against a gratis, fully-sourced,
  prominently-attributed fork is not a pattern that exists.
- Only two things eliminate the residual risk: a §7 additional permission
  from every relevant holder (excluded), or not using the store channel.

## 3. Obligations map (AGPL-3.0 → current state → work item)

| AGPL § | Requirement | State | Item |
|---|---|---|---|
| 5(a) | prominent notices of modification + date | git history only | W1 |
| 5(b) | retain upstream legal notices | upstream byte-clean ✓ | keep |
| 5(c) | entire work under AGPL | root LICENSE ✓ | W1 (SPDX sweep) |
| 6 | Corresponding Source for the exact binary | repo + pinned submodule + build scripts ✓ | W2 |
| 6(d) | source offer, same place, no charge, durable | public repo ✓ + release archive (W2) + in-app offer (W3) | ✓ |
| 4, 7, 10 | no further restrictions from us | free app, no IAP, no DRM of ours ✓ | W8 invariants |
| 7 | respect dependency licenses (LGPL/MPL/permissive) | notices intact upstream | W4 inventory + notices |
| 13 | source offer to network users | N/A (no server) | W8 trigger condition |
| 8 | cure within 30 days of notice | — | W7 protocol |

## 4. Work items

### W1 — Notices, attribution, headers — ✅ done 2026-10-14
- `README.md`: project blurb; lineage attribution block; license + source
  link; pointers to BUILDING/COMPLIANCE/THIRD_PARTY.
- SPDX `AGPL-3.0-only` headers on 97 repo-authored files (`Sources/`, all
  of `Bridge/`, `Distribution/`, workflows, `Package.swift`, `App-Info.plist`).
  `Bridge/engine-cxx/orca_bridge.h` + its modulemap are deliberately
  excluded (byte-mirrored into `Prebuilt/`, parity-audited; a comment-only
  edit would force archive rebuilds with no legal gain — the repo-root
  LICENSE covers them).
- Accept: ✓ every repo-authored file carries SPDX (or the documented
  mirror exclusion); README shows lineage + license + source link.

### W2 — Corresponding-Source pipeline (CI) — ✅ done 2026-10-14
- **Gap**: GitHub tag tarballs omit submodule contents — not complete
  Corresponding Source on their own. Host headers (boost/Eigen/CGAL/GMP/
  MPFR) would be missing too.
- `Bridge/tools/make-source-archive.sh` builds
  `OrcaPad-<tag>-full-source.tar.gz`: tracked files + vendored upstream
  submodule + cache-dep pins + host headers + `ARCHIVE-MANIFEST.txt`
  (all pins and versions). Runs in the `verify` job (ubuntu-26.04, so the
  apt-installed headers match the build host) and is attached to the tag's
  GitHub Release via `gh release create/upload` (idempotent on reruns).
- Provenance: `Bridge/build-core.sh` stamps `Prebuilt/HOST-HEADERS.txt`
  (via `Bridge/tools/host-header-stamp.sh`); the archive tool refuses to
  build on a host whose header defines differ from the stamp — the archive
  must match the shipped binary.
- `ORCAPAD_SOURCE_REF` = `<tag>+<commit-sha>` is baked into `App-Info.plist`
  by `Distribution/release-testflight.sh` (validated + verified in the
  post-archive checks) and displayed by the About screen (W3).
- Policy: `release*` tags are permanent; every shipped build must trace to
  one.
- Accept: ✓ pending first live run — every TestFlight/App Store build has a
  durable, no-charge, complete source archive at a stable public URL; the
  binary itself names its exact source ref.

### W3 — In-app About / licenses screen — ✅ done 2026-10-14
- `About & Licenses` (`Sources/OrcaPad/App/AboutView.swift`), opened by the
  About button in the Plate tab's action bar (1 tap from the default tab,
  2 from any other): app version + build + `ORCAPAD_SOURCE_REF`, AGPL-3.0
  full text (bundled resource, byte-identical to the repo LICENSE),
  lineage attribution (incl. non-affiliation statement), the generated
  `THIRD_PARTY.md`, browsable full texts of every bundled license,
  repository + issues links, and a build-your-own pointer. Missing license
  resources surface as a visible error (fail loudly), never a silent
  empty screen.
- Accept: ✓ from inside the app, in ≤2 taps, a non-technical user reaches
  the license, the source of their exact binary, and upstream attribution.

### W4 — Third-party license inventory + LGPL handling — ✅ done 2026-10-14
- `Bridge/tools/license-inventory.sh` derives the compiled closure from
  `Bridge/engine-sources.sh` (312 TUs at implementation time) + the
  header-only components, and generates the checked-in `THIRD_PARTY.md`
  (repo root + bundled About copy) and the license texts under
  `Sources/OrcaPad/Resources/Licenses/` (AGPL copy byte-checked against
  LICENSE). `--check` is a CI gate in the `verify` job — closure changes
  cannot ship without regeneration.
- Inventory highlights: OrcaSlicer **AGPL-3.0**; admesh **GPL-2.0+**;
  libnest2d **LGPL-3.0**; nlopt 2.5.0 + libnoise **LGPL-2.1+**; CGAL core
  **GPL-3.0+** (host headers); GMP dual GPL-2+/LGPL-3+ (LGPL branch);
  MPFR **LGPL-3.0+**; Eigen **MPL-2.0**; boost/clipper/clipper2 **BSL-1.0**;
  cereal **BSD-3**; expat/miniz/qoi/semver/nlohmann **MIT**; qhull
  permissive; glu-libtess **SGI-FreeB-2.0**; nanosvg **Zlib**. Optional
  hygiene upgrade (not done): nlopt ≥ 2.6 is MIT.
- Static-linked LGPL position: mirror upstream OrcaSlicer's own model —
  the complete combined-work source *including the LGPL libraries and the
  full build system* is conveyed at no charge (LGPLv3 §4(a)
  Corresponding Source; LGPLv2.1 §6's relinking purpose served by the
  full-source rebuild path). Notices preserved + listed.
- Accept: ✓ `THIRD_PARTY.md` lists every compiled dependency with license +
  evidence; closure changes cannot pass CI without it.

### W5 — BUILDING.md (the practical freedom path) — ✅ done 2026-10-14
- Human-facing guide: prerequisites (Ubuntu 26.04 reference host incl.
  the header packages), clone with submodules, engine archive build, app
  build, host contract tests, and how to install one's own build on one's
  own device (xtool dev / free Xcode personal-team signing with the 7-day
  refresh caveat / EU sideloading note), plus the release-archive provenance
  pointer.
- Accept: ✓ a motivated stranger can follow it end to end.

### W6 — Store metadata hygiene — ✅ done 2026-10-14
- `Distribution/app-store-metadata.md`: the App Store / TestFlight listing
  template — open-source + AGPL statement, source URL, upstream
  attribution + non-affiliation, issues link — plus standing rules (keep
  those sentences in every revision; no proprietary-sounding claims; no
  IAP; tag messages must be user-appropriate because CI feeds them to Beta
  App Review).
- Accept: ✓ template exists; listing text reviewed on every release
  (checklist).

### W7 — Governance, cure, complaints
- This file is the living record. Update on: closure change, upstream pin
  change, Apple ToS change, incident. Contact: GitHub issues, response
  target ≤7 days.
- §8 cure protocol: on any rights-holder notice → acknowledge, stop
  further releases, cure within 30 days or withdraw the listing, document
  here. Reinstatement follows §8.
- Apple dispute: use the App Review dispute / DMCA counter-process;
  publish a community note in the repo.
- Annual review of the Apple EULA text and FSF/SFC positions (they move).

### W8 — Policy invariants (guard rails; enforced by review + gates)
- Only repo-source-available, OSI-compatible code in the shipped binary:
  no proprietary blobs, no license keys, no paywalled functionality or IAP
  inside the AGPL work. The app stays gratis.
- No server-side execution of the covered work without reopening §13
  analysis here.
- No new closure dependency without a `THIRD_PARTY.md` entry (CI gate).

## 5. Release checklist delta (every `release*` tag)

- [ ] `license-inventory.sh` gate green (closure ↔ THIRD_PARTY.md in sync)
- [ ] full-source tarball attached to the GitHub Release
- [ ] `ORCAPAD_SOURCE_REF` baked; About screen shows the exact ref
- [ ] store metadata mentions AGPL-3.0 + source URL

## 6. Sources consulted (2026-10-14)

- FSF: *GPL Enforcement in Apple's App Store* + follow-up (2010)
- Apple Standard EULA §a (current text incl. the OSS carve-out)
- VLC removal (2011) / MPL return (2013) coverage
- Signal libsignal AGPL + App Store exception history (libsignal #684)
- element-ios #7839 (AGPL switch; lawyers engaged; unlicensed)
- App Fair: *The GPL and Commercial App Stores: Time for a Reconsideration*
- SFC vs Bambu Studio AGPLv3 enforcement (2026) and Bambu's fork statement
- AGPL-3.0 text §§4–8, 13; local: `LICENSE`, `upstream/orcaslicer/LICENSE.txt`
