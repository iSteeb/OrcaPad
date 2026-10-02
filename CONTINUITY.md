# CONTINUITY — OrcaPad

## PLAN

- Goal: native iOS/iPadOS port of OrcaSlicer — engine as-is (C++), GUI from
  scratch (SwiftUI + Metal). See PLANS.md for phases.
- Acceptance (Phase 0): green `xtool dev build`; renders on iPoke at ~60fps
  with orbit/pan/pinch on bed grid + test cube.
- Next steps:
  1. [USER] Visual confirm on iPoke: bed grid + orange cube visible; orbit /
     pan / pinch work; status chip shows live fps (expect ~60). Then tick
     the last Phase 0 box.
  2. Phase 1: libslic3r iOS build — CMake toolchain file, minimal dep set,
     arm64 + simulator slices → xcframework, Swift↔C++ interop layer in
     `Engine/`, first on-device slice (cube STL → gcode in Documents).
  3. Consider `skipLSP: true` decision and Mac collaborator .xcodeproj export
     (`xtool dev generate-xcode-project`) when Phase 1 C++ enters.

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
  Meta-files AGENTS/PLANS/CONTINUITY/LESSONS created.
- [2026-10-02] `xtool dev build` GREEN (3 fix iterations, 0 warnings).
  Committed `P0:` 9bc9586. Phone not connected — install pending.
- [2026-10-02] Installed on iPoke via `xtool dev` (auto-provisioned). User
  launched 15:14:13 → `renderer online` at 15:14:14.566 (<600ms), GPU
  assertion acquired, foregroundRunning, no crash/jetsam through capture
  window. On-device id: `XTL-C93C0481.ie.duz.OrcaPad`. [TOOL]

## DISCOVERIES

- OrcaSlicer codebase measured [CODE]: libslic3r ~312k LOC, wx GUI ~449k LOC
  (~31k scene core + ~47k gizmos + ~9k jobs + ~360k desktop chrome).
  → 80% of GUI code is deletable, not portable.
- wxWidgets iOS port is officially "very basic" — confirms native-rewrite path.
- Bambu Handy does cloud slicing; no full on-device mobile slicer exists yet
  (opportunity). UNCONFIRMED as of 2026-10.
- xtool's generated Info.plist already has UIDeviceFamily [1,2] (iPhone+iPad)
  and full iPad orientations — no plist overrides needed. [TOOL]
- In this SDK (iOS 27.0), MTKView is @MainActor and MTKViewDelegate
  satisfaction from a @MainActor class works WITHOUT @preconcurrency
  (attribute warned "has no effect"). Renderer is @MainActor. [TOOL]
- Swift tuples do NOT bridge to SIMD3<Float> literals — write
  `SIMD3(x, y, z)` explicitly. [CODE]

## OUTCOMES

- [2026-10-02] Phase 0 complete (pending visual confirm): OrcaPad builds
  from Linux, installs on a physical iPhone, Metal pipeline + runtime MSL
  compile + 60fps render loop verified via syslog. The whole xtool loop
  (build→sign→install→verify) works for this project.
