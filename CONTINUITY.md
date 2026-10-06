# CONTINUITY — OrcaPad

## PLAN

- Current goal: finish Architecture Gate A while preserving the verified
  STL → preset-backed slice → desktop-compatible G-code path.
- Acceptance: one authoritative C++ document; Client → Bridge → untouched
  Engine; stable IDs/revisions; immutable Swift snapshots; derived Metal
  caches; typed contextual failures; warning-free redirected device build.
- Next steps:
  1. Add Bridge/domain/coordinate/renderer architecture contract tests.
  2. Run the complete validation/device acceptance census and checkpoint Gate A.
  3. Then introduce immutable cancellable slice jobs so slicing no longer
     retains the live document/preset locks.

## DECISIONS

- [2026-10-06 USER] Exactly three conceptual modules: Swift Client → Bridge →
  untouched Engine. Prefer broad typed contracts and loud failures over
  feature-specific patches or extra packages.
- The C++ session owns canonical document/config state. Swift snapshots are
  immutable values; transient gesture previews are separate; Metal owns only
  derived GPU/picking caches.
- The versioned C ABI contains raw pointers, callbacks, ownership, and C++
  exceptions. Raw ABI use stays in `Sources/OrcaBridge`.
- Cross-handle lock order is plater → presets. Guarded engine operations are
  process-serialized because upstream `ObjectBase` IDs/globals are not thread
  safe. Long-term serialization belongs to a runtime owner.
- Engine-issued `ObjectID`s back document/object/instance identity. Every
  successful document mutation advances one monotonic revision.
- Start with complete deep-copied snapshots for correctness; optimize later by
  stable ID + mesh revision without changing authority.
- Coordinates are canonical engine z-up values in the Bridge. One client
  `CoordinateMapper` owns z-up ↔ Metal y-up conversion.

## PROGRESS

- [2026-10-06 CODE][TOOL] C ABI v2 stable snapshot state landed in `ef29203`:
  engine object/instance IDs, mutation revisions, owned canonical meshes, one
  coherent snapshot read, immutable Swift values, and stable renderer caches.
- [2026-10-06 CODE] `AppEnvironment` now owns process-lifetime client stores.
  `DocumentStore`, `PresetStore`, `SliceService`, `EnginePaths`, and
  `StatusCenter` own engine/file/job policy; `PlaterView` is presentation-only.
- [2026-10-06 CODE] All blocking engine/file operations use one typed detached
  work boundary. Document busy/stale/preview rules and transactional preset
  persistence are centralized; slice outcomes carry source revision/config.
- [2026-10-06 TOOL] Core archive remains 259/259 unique with matching headers;
  the decomposed Swift client passes a warning-free redirected xtool build.

## DISCOVERIES

- [2026-10-06 CODE] Upstream `ObjectBase::s_last_id` is explicitly not thread
  safe; per-session Swift locks cannot protect IDs across documents/Prints, so
  the Bridge requires process-wide guarded entry.
- [2026-10-06 CODE] Moving a `ModelObject*` directly between `Model.objects`
  vectors leaves its private `m_model` back-pointer dangling. Always transfer
  through upstream `Model` APIs.
- [2026-10-06 CODE] The old archive duplicate count came from three duplicate
  compile-list jobs; build tooling now rejects duplicates and produces 259/259.
- [2026-10-06 CODE] Current build remains machine-local: manual source closure,
  sequential TBB shims, ignored caches, and duplicated 12,006 profile JSONs.

## OUTCOMES

- [2026-10-03 USER] Phase 1 accepted on device: a 483,772-triangle STL sliced
  through the real Orca pipeline to G-code in Documents; desktop compatibility
  was subsequently verified with real presets.
- [2026-10-02 USER] Phase 0/2 proof accepted: native Metal viewer at 60 fps,
  real STL repair/render, document import, camera controls, and engine slicing.
