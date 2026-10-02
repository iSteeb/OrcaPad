# CONTINUITY — OrcaPad

## PLAN

- Goal: native iOS/iPadOS port of OrcaSlicer — engine as-is (C++), GUI from
  scratch (SwiftUI + Metal). See PLANS.md for phases.
- Acceptance (Phase 0): green `xtool dev build`; renders on iPoke at ~60fps
  with orbit/pan/pinch on bed grid + test cube.
- Next steps:
  1. `xtool dev build` → fix compile errors → `xtool dev` to install on iPoke.
  2. Verify syslog: `idevicesyslog | grep --line-buffered "OrcaPad\["`.
  3. Manual launch on phone (xtool launch broken, iOS 17+ issue #44).
  4. Then Phase 1: libslic3r iOS build (start: CMake toolchain file, minimal
     dep set, arm64 + simulator slices → xcframework).

## DECISIONS

- [USER] Strategy B: engine as-is + native GUI from scratch, Metal only, skip
  exotic tools (painting/MMU/CAD) for first concepts.
- Name `OrcaPad`, bundle `ie.duz.OrcaPad` (matches `ie.duz.LifeCounter`).
- iPad-first; iPhone companion is out of scope until core loop ships.
- iOS 17 deployment target, Swift 6 language mode, strict concurrency.
- Runtime MSL compilation from embedded source strings — Linux toolchain
  cannot compile .metallib (Apple's metal toolchain is macOS-only). [TOOL]
- No .xcassets (xtool #219): SF Symbols + code-drawn UI only. [TOOL]
- Renderer/camera are non-isolated classes confined to the main thread;
  MTKViewDelegate is nonisolated so no @MainActor on Renderer. [CODE]
- Git from day one; commits prefixed `P0:`–`P5:` by phase.

## PROGRESS

- [2026-10-02] Phase 0 scaffold written: Package.swift, xtool.yml, 7 Swift
  files (app shell, plater view, MetalCanvas/Renderer/Camera/Geometry/Shaders).
  Meta-files AGENTS/PLANS/CONTINUITY/LESSONS created. Build not yet attempted.

## DISCOVERIES

- OrcaSlicer codebase measured [CODE]: libslic3r ~312k LOC, wx GUI ~449k LOC
  (~31k scene core + ~47k gizmos + ~9k jobs + ~360k desktop chrome).
  → 80% of GUI code is deletable, not portable.
- wxWidgets iOS port is officially "very basic" — confirms native-rewrite path.
- Bambu Handy does cloud slicing; no full on-device mobile slicer exists yet
  (opportunity). UNCONFIRMED as of 2026-10.

## OUTCOMES

- (none yet — nothing installed on device)
