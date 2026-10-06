# CONTINUITY — OrcaPad

## PLAN

- Current goal: finish Architecture Gate A while preserving the verified
  STL → preset-backed slice → desktop-compatible G-code path.
- Acceptance: one authoritative C++ document; Client → Bridge → untouched
  Engine; stable IDs/revisions; immutable Swift snapshots; derived Metal
  caches; typed contextual failures; warning-free redirected device build.
- Next steps:
  1. Extract document/preset/file/slice orchestration from `PlaterView`.
  2. Introduce the runtime owner and immutable cancellable slice jobs so long
     slices no longer retain the live document/preset locks.
  3. Add Bridge/domain/coordinate/renderer contract tests.
  4. Resume feature parity, starting with project/3MF capability work.

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

- [2026-10-06 CODE][TOOL] STABLE SNAPSHOT STATE LANDED: C ABI v2 exposes
  document/object/instance IDs, mutation revisions, owned full-scene snapshots,
  copied canonical meshes, names/bounds/pivots, and one disposal function.
  Index/count/get/borrowed-mesh proof APIs are removed.
- [2026-10-06 CODE] `EnginePlater.apply` retains its session lock across a
  mutation plus snapshot and verifies returned revision equality. Swift scene
  values are all-let and ABI ownership/validation stays in OrcaBridge.
- [2026-10-06 CODE] `PlaterView` no longer maintains `PlaterObjectState` or
  UUID sync tokens. Selection and commands use stable IDs; gesture preview is
  a separate overlay; mutations/snapshot copies execute off-main; stale
  revisions are rejected.
- [2026-10-06 CODE] Renderer consumes coherent snapshots atomically, caches GPU
  meshes by object ID + mesh revision, and emits stable IDs from picking.
  Coordinate conversion is centralized and old anchor coupling is removed.
- [2026-10-06 CODE] Model imports use upstream `Model::add_object`, preserving
  parent pointers and generating valid engine IDs. Transform/ensure-on-bed
  mutations stage candidate state before commit; unsupported mirror/non-z/
  nonuniform transforms fail explicitly.
- [2026-10-06 TOOL] Core archive rebuilt: 259 members / 259 unique; packaged
  header equals source; new snapshot invariants verified in the archive;
  redirected `xtool dev build` completes with no warnings.

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
