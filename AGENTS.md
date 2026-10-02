# AGENTS.md — OrcaPad

Native iOS/iPadOS port of [OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer):
**slicing engine as-is (C++), GUI from scratch (SwiftUI + Metal)**.

Read order for any agent session in this repo:
**AGENTS.md → PLANS.md → CONTINUITY.md → LESSONS.md**, then code.
Update CONTINUITY.md when progress/decisions/discoveries change; PLANS.md when
scope changes; LESSONS.md on every corrected mistake.

## The strategy (do not drift from it)

- libslic3r (the ~312k-LOC headless C++ engine) is used **unmodified** — built
  as xcframeworks, consumed via Swift↔C++ interop. We are a consumer of
  upstream, not a fork. Never hand-patch engine sources; if an engine change is
  unavoidable it goes upstream or behind a thin adapter in `Engine/`.
- The GUI is **native from scratch**: SwiftUI shell, Metal 3D viewer. No
  wxWidgets, no OpenGL/GLES, no SceneKit/RealityKit, no Catalyst, no WebView UI.
- Skip the exotic tools (seam/support painting, MMU segmentation, CAD editing)
  until the core loop is complete and shipped. See PLANS.md phases.
- iPad-first. iPhone gets a companion treatment later, not a shrunk plater.

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
- **No .xcassets** (xtool can't compile them, #219): SF Symbols + code only.
- **No offline Metal shader compilation** (Apple's metal compiler is
  macOS-only): all MSL lives in `Viewer/Shaders.swift` and is compiled at
  runtime via `MTLDevice.makeLibrary(source:)`. Keep it that way.
- `xtool dev build` release artifacts are UNSIGNED — never install them.

## Code conventions

- Swift 6, strict concurrency. All renderer/camera state is main-thread
  confined (non-isolated classes + UIKit gesture entry points). Do not
  introduce Sendable-happy hacks; keep the confinement explicit.
- Viewer module (`Sources/OrcaPad/Viewer/`) owns everything Metal. New 3D
  features extend `Renderer`/`Geometry`/`Shaders` — UI never touches MTL types.
- Future modules: `Engine/` (Swift↔C++ interop over libslic3r), `Settings/`
  (UI generated from ConfigOptionDefs — never hand-write settings rows),
  `GCode/` (libvgcode viewer), `Printing/` (LAN/cloud comms).
- Fail loudly: no silent fallbacks, no empty catches, no `return nil` papering
  over errors. Renderer errors surface in the status overlay + os_log.
- Bundle id `ie.duz.OrcaPad`. Folder `~/OrcaPad`. Deployment target iOS 17.

## Git discipline

- Commit at every green build. Message prefix with phase: `P0:`, `P1:`, …
- `.gitignore` already excludes `/xtool` (build output) and `/.build`.
- Never commit built artifacts, logs, or provision profiles.
