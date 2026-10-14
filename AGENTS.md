# AGENTS.md — OrcaPad

Native iOS/iPadOS port of [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer):
**slicing engine as-is (C++), GUI from scratch (SwiftUI + Metal)**.

Read order for any agent session in this repo:
**AGENTS.md → ARCHITECTURE.md → PLANS.md → CONTINUITY.md → LESSONS.md**, then code.
Update CONTINUITY.md when progress/decisions/discoveries change; PLANS.md when
scope changes; LESSONS.md on every corrected mistake.

## The strategy (do not drift from it)

- The architecture has exactly three top-level conceptual modules, with one-way
  dependencies: **Swift Client → Bridge → Untouched Engine**. The normative
  contracts are in `ARCHITECTURE.md`.
- The pinned OrcaSlicer engine in `upstream/orcaslicer` is never privately
  patched or forked. Generic portability improvements may be contributed
  upstream; slicing algorithms are never duplicated outside the engine.
- The Bridge is the only module allowed to include engine headers or import the
  raw C ABI. It owns typed failures, lifetime, capabilities, stable IDs,
  revisions, jobs, and complete platform adapters — never UI or rendering.
- The GUI is **native from scratch**: SwiftUI shell, Metal 3D viewer. No
  wxWidgets, no OpenGL/GLES, no SceneKit/RealityKit, no Catalyst, no WebView UI.
  Scoped exception [USER 2026-10-07]: the Device tab may embed the connected
  printer's OWN web interface (desktop PrinterWebView parity); OrcaPad's
  own UI stays native.
- Skip the exotic tools (seam/support painting, MMU segmentation, CAD editing)
  until the core loop is complete and shipped. See PLANS.md phases.
- iPad-first. iPhone gets a companion treatment later, not a shrunk plater.

## Repository map (structure is normative)

```
upstream/orcaslicer/        Untouched engine, git submodule pinned to v2.4.2
Bridge/engine-cxx/          C ABI boundary: orca_bridge.{h,cpp} + adapter TUs
Bridge/shim/                iOS/Darwin dependency adapters (boost::log, tbb,
                            occt stub, openssl/md5→CommonCrypto, png)
Bridge/shim-host/           host-only header overrides (md5) — highest -I
                            priority in host test builds only
Bridge/cache/               build-only fetched deps (cereal, boost-filesystem
                            1.90 sources, libnoise) — gitignored
Bridge/engine-sources.sh    THE engine compile list (single source of truth,
                            shared by both builds — lists must never drift)
Bridge/build-core.sh        cross-builds the iOS archive → Prebuilt/
Bridge/build-host-tests.sh  compiles the SAME closure for the Linux host and
                            RUNS the contract tests (asserts enabled)
Bridge/tools/contract_tests.cpp      C ABI + engine contract test suite
Bridge/tools/architecture-audit.sh   static boundary audit (no build)
Bridge/tools/parity-check.py         desktop-parity checker: extracts the desktop
                            feature surface from upstream, verifies the
                            manifest's OrcaPad evidence, generates PARITY.md
Bridge/tools/parity-manifest.toml    THE feature-status source of truth
Prebuilt/OrcaBridgeCore.xcframework  shipped binary — regenerated, never edited
Sources/OrcaBridge/         Swift facade; the ONLY raw-ABI consumer
Sources/OrcaPad/App/        AppEnvironment (process-lifetime owner), StatusCenter,
                            RootView (four-tab glass shell)
Sources/OrcaPad/Features/   one folder per tab: Plate/ Prepare/ Preview/ Device/
                            (presentation only — no engine/file orchestration)
Sources/OrcaPad/Stores/     DocumentStore, PresetStore (main-actor state owners)
Sources/OrcaPad/Services/   EnginePaths, SliceService, ResolvedConfigService,
                            GcodePreviewStore
Sources/OrcaPad/Viewer/     everything Metal: Renderer, Geometry, Camera,
                            CoordinateMapper, Shaders (runtime MSL), MetalCanvas,
                            ToolpathRenderer + GcodeCanvas (Preview)
Distribution/               App Store packaging, used ONLY by CI on macOS:
                            project.yml (XcodeGen app target: App/empty.c +
                            the OrcaPad library), AppIcon.xcassets,
                            PrivacyInfo.xcprivacy, release-testflight.sh
                            (archive, sign, check, upload), asc_testflight.py
                            (external TestFlight group + Beta App Review)
.github/workflows/          testflight.yml: on `release*` tags only - Linux
                            audit + parity, then Xcode archive -> TestFlight
PRIVACY.md                  privacy policy (TestFlight/App Store URL)
```

## The contract (summary — full text in ARCHITECTURE.md)

**C ABI (`Bridge/engine-cxx/orca_bridge.h`, version in `ORCA_BRIDGE_ABI_VERSION`;
bump it on every header change and update the Swift expectation + the
contract test literal in the same commit)**
- Every fallible operation returns a typed `orca_result` (status code + owned
  diagnostic). Callers branch on `code`, never on message text. Diagnostics are
  empty on success.
- Owned memory (diagnostics, strings, scene snapshots) is released through the
  matching `*_dispose` function, exactly once; dispose is idempotent and
  null-safe.
- Identity and state: engine-issued stable `orca_document_id` /
  `orca_object_id` / `orca_instance_id` (never array indices), one monotonic
  document `orca_revision` advanced by every successful mutation and returned
  with it, and deep-copied immutable `orca_scene_snapshot`s in canonical
  engine coordinates (z-up, millimetres, radians).
- Engine entry is process-serialized inside the Bridge (upstream globals are
  not thread-safe); a handle must not be freed concurrently with a call.
- The process data directory is initialize-once; a second, different path is a
  typed configuration failure.
- Instance transforms: engine XYZ Euler rotation + positive per-axis scale
  (ABI v7); mirroring is not supported yet (typed rejection).
- Document mutations are transactional (a failure leaves the document
  unchanged) and each success is one labelled undo step; undo/redo restore
  the same stable IDs and still advance the revision (ABI v18). Batch
  operations (group delete, multi-object clipboard, settings paste) are
  one mutation per user action (ABI v26).
- Scene snapshots carry each part volume's triangle range inside the
  object's merged mesh (ABI v26): client-side part picking and highlight
  without duplicating part geometry; the snapshot fails loudly if the
  ranges stop covering the merged mesh.
- Presets: entries expose engine vendor + `is_compatible`; overrides are
  written to the edited preset of a kind (`full_config()` merges edited
  presets, so slices consume them); edited vs system dumps detect changes.
- G-code preview: `orca_gcode_load` runs the upstream GCodeProcessor;
  `orca_gcode_toolpath` returns a compact owned segment/layer copy carrying
  the engine's own ExtrusionRole/EMoveType values (never libvgcode's).

**Swift facade (`Sources/OrcaBridge`)**
- Raw ABI use (`OrcaBridgeCore`, `OpaquePointer`, `orca_*`, `Unmanaged`) is
  confined here.
- `EnginePlater.apply` performs one mutation plus one snapshot read under a
  single session lock and verifies revision equality; cross-handle operations
  hold both locks in plater → presets order.

**Swift client (`Sources/OrcaPad`)**
- `AppEnvironment` owns process-lifetime stores and Bridge sessions; views are
  presentation-only (no raw engine calls, no filesystem policy, no detached
  engine orchestration).
- Blocking engine/filesystem work crosses exactly one typed boundary
  (`BackgroundWork`); commands reject while a document mutation or slice is in
  flight rather than silently queueing.
- The C++ document is authoritative: authoritative snapshot installs clear
  transient gesture-preview transforms, and stale revisions are rejected.
- Generic PLA/brass config overlays apply ONLY to the preset-free slice path;
  selected preset `full_config()` values are never overwritten.

**Engine purity**
- `upstream/orcaslicer` stays byte-clean. Portability adapters live under
  `Bridge/shim*` and `Bridge/engine-cxx` as small, documented TUs.

## Toolchain reality (this is a Linux box, no Xcode)

- Build: `cd ~/OrcaPad && xtool dev build > /tmp/orcapad-build.log 2>&1`
  (stdout MUST be redirected — xtool crashes on /dev/null stdout, issue #268).
  This must stay green at every commit.
- Install to the phone (when plugged in): `xtool dev > /tmp/orcapad-dev.log 2>&1`.
  Phone: "iPoke" `00008150-000243C63408401C` (iPhone18,4, iOS 27.2).
- On-device app id is prefixed: `XTL-C93C0481.ie.duz.OrcaPad`. Launch manually —
  `xtool launch` is broken on iOS 17+ (issue #44).
- Logs: `idevicesyslog | grep --line-buffered "OrcaPad\["`. `print()` is
  invisible for home-screen-launched apps — always use `os_log` (`Logger`).
- **No .xcassets under `Sources/`** (xtool can't compile them, #219): SF
  Symbols + code only. The App Store icon catalog lives in `Distribution/`
  and only CI compiles it (actool on macOS).
- **No offline Metal shader compilation** (Apple's metal compiler is
  macOS-only): all MSL lives in `Viewer/Shaders.swift` and is compiled at
  runtime via `MTLDevice.makeLibrary(source:)`. Keep it that way.
- `xtool dev build` release artifacts are UNSIGNED — never install them.
- **CI = releases only** [USER 2026-10-13] (GitHub Actions
  `.github/workflows/testflight.yml`, public repo `iSteeb/OrcaPad`): it runs
  ONLY when a `release*` tag is pushed, and every such build goes to the
  external TestFlight group (Beta App Review). Linux job: audit + parity
  check. macOS job (hosted `xcode-27`): Xcode only, NO xtool (the xtool.app
  binary hung at launch on the runner): XcodeGen generates the app project
  from `Distribution/project.yml`, `xcodebuild` archives with App Store
  signing, then export, `altool` upload, `asc_testflight.py` (external
  group, What to Test, review submission). CI does NOT rebuild the engine: it
  links the committed `Prebuilt/` archive, so the matrix below still governs
  it. Release: `git tag release-X.Y.Z && git push origin release-X.Y.Z`
  (the tag sets the version; a plain `release*` tag keeps
  MARKETING_VERSION from `Distribution/project.yml`).
- TestFlight builds are `ie.duz.OrcaPad`: a separate app (and data container)
  from the xtool dev install `XTL-C93C0481.ie.duz.OrcaPad`. CFBundleVersion
  is `<run number>.<attempt>`. Signing material stays with the user
  (`~/orcapad-signing`, off-limits to agents) and in the `testflight`
  environment secrets.

## Builds, tests, and audits — when to run what

| Change you made | Run before committing |
|---|---|
| Anything under `Bridge/engine-cxx`, `Bridge/shim*`, `Bridge/engine-sources.sh`, or the upstream pin | 1. `./Bridge/build-core.sh` (rebuild archive) 2. `./Bridge/build-host-tests.sh` (contract tests) 3. `xtool dev build` |
| `Sources/OrcaBridge` (Swift facade) | `./Bridge/build-host-tests.sh` + `xtool dev build` |
| `Sources/OrcaPad` (Swift client / viewer) | `xtool dev build`; device run for UI/gesture paths |
| Upstream pin change, or `Bridge/tools/extract_config.cpp` | after host tests: `./Bridge/tools/build-extract-config.sh` (regenerates the committed `Resources/config-schema.json`) |
| Contract-adjacent docs (`ARCHITECTURE.md`, this file) | nothing — but keep the tables truthful |
| `Distribution/` or `.github/` | `shellcheck Distribution/*.sh`, `python3 -m py_compile Distribution/*.py`, `mise exec actionlint@latest -- actionlint`; CI only runs on a `release*` tag, so the next release is the real test (`gh run watch`) |
| A feature lands or changes status (any layer) | update `Bridge/tools/parity-manifest.toml` (status + evidence), then `./Bridge/tools/parity-check.py --write` |
| **Before every commit, any change** | `./Bridge/tools/architecture-audit.sh` and `./Bridge/tools/parity-check.py --check` |

Ground rules for the matrix:

- `Bridge/build-host-tests.sh` compiles the identical engine closure from
  `Bridge/engine-sources.sh` for the host with assertions ENABLED, links the
  contract suite against it archive-style (mirroring iOS member-pull
  semantics), runs it, and must print `RESULT: PASS`.
- `Bridge/build-core.sh` verifies object-manifest parity (member count ==
  unique count, no stale members) and copies the header into `Prebuilt/`; the
  audit then checks byte-parity. The archive is written by the toolchain's
  `llvm-ar --format=darwin` with a `__.SYMDEF` index: Apple's linker (CI)
  rejects index-less archives, which host GNU `ar` silently produced.
- Never hand-edit anything under `Prebuilt/` or `Bridge/build-*`; never add a
  source to one build list without the other — edit
  `Bridge/engine-sources.sh` only.
- A red contract test or audit is a commit blocker; fix the cause, never the
  assertion, unless the contract itself changed (then update the test AND
  `ARCHITECTURE.md` in the same change).
- `PARITY.md` is GENERATED from `Bridge/tools/parity-manifest.toml`; never
  edit it by hand. A red parity check is a commit blocker: an unclaimed or
  orphan item means the pinned upstream surface moved (re-map it), stale
  evidence means a claim no longer holds (fix the code or the status).
- Device verification (import → transform → preset select → slice → G-code in
  Files) remains the acceptance loop for Gate A; host tests do not replace it.

## Code conventions

- Swift 6, strict concurrency. All renderer/camera state is main-thread
  confined (non-isolated classes + UIKit gesture entry points). Do not
  introduce Sendable-happy hacks; keep the confinement explicit.
- Viewer module (`Sources/OrcaPad/Viewer/`) owns everything Metal. New 3D
  features extend `Renderer`/`Geometry`/`Shaders` — UI never touches MTL types.
- Inside the Swift Client, keep focused domain/state, persistence, renderer,
  settings, preview, and printing boundaries without proliferating packages.
  Settings UI is generated from ConfigOptionDefs; G-code data semantics may be
  reused, but the OpenGL libvgcode renderer is not used on iOS.
- The C++ document session is the sole mutable slicer-domain authority. Swift
  consumes revisioned immutable snapshots; Metal holds derived caches only.
- Fail loudly with typed errors and context: no status-text control flow,
  silent fallbacks, empty catches, `try?` for required work, or `return nil`
  papering over errors. Renderer errors surface in the status overlay + os_log.
- Prefer one complete solution for a recurring problem over individual patches.
- Bundle id `ie.duz.OrcaPad`. Folder `~/OrcaPad`. Deployment target iOS 17.

## Git discipline

- Commit at every green build. Message prefix with phase: `P0:`, `P1:`, …
- `.gitignore` already excludes `/xtool` (build output) and `/.build`.
- Other prefixes in use: `CI:` (build/distribution), `Docs:` (docs only).
- Commits use the repo-local GitHub noreply identity
  (`65476863+iSteeb@users.noreply.github.com`) [USER 2026-10-13]; history
  was rewritten to it on 2026-10-13, so every earlier commit SHA changed.
- Pushes to `main` run no CI. A `release*` tag ships an external TestFlight
  build and costs a Beta App Review: tag deliberately, only after the local
  gates and a device check.
- Never commit built artifacts, logs, or provision profiles.
