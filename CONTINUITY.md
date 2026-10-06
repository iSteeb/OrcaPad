# CONTINUITY — OrcaPad

## PLAN

- Current goal: finish Architecture Gate A while preserving the verified
  STL → preset-backed slice → desktop-compatible G-code path.
- Acceptance: one authoritative C++ document; Client → Bridge → untouched
  Engine; stable IDs/revisions; immutable Swift snapshots; derived Metal
  caches; typed contextual failures; warning-free redirected device build.
- Next steps:
  1. Final Gate A validation census + device install and acceptance loop.
  2. Swift-domain contract tests (blocked on Linux-runnable Swift module or
     Mac CI).
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

- [2026-10-06 CODE][TOOL] HOST CONTRACT TESTS LANDED: `Bridge/build-host-tests.sh`
  compiles the shared engine closure for Linux (via the new
  `Bridge/engine-sources.sh` single compile list), links
  `Bridge/tools/contract_tests.cpp` archive-style (iOS member-pull
  semantics), and runs it: 183 checks green — ABI v2, typed failures, owned
  diagnostics + idempotent disposal, stable IDs, +1 revision per successful
  mutation and +0 per rejection, mutation/snapshot revision equality,
  deep-copy ownership, NOT_FOUND/INVALID_ARGUMENT taxonomy, transform
  validation, last-instance atomicity, two-thread process serialization,
  transactional presets, and all three real slice paths with progress.
- [2026-10-06 CODE] `Bridge/tools/architecture-audit.sh` (10 static boundary
  checks: upstream purity, header parity, archive uniqueness, raw-ABI
  confinement, package direction, no silent-failure patterns, runtime-MSL
  only, overlay discipline, no client refs in Bridge C++) — all PASS.
- [2026-10-06 CODE] build-core.sh refactored onto the shared list with a
  manifest-identical, byte-stable iOS archive; `boost_filesystem_shim.cpp`
  retired (duplicate definitions of the real boost-filesystem sources);
  archive now 258 members; app links green.

- [2026-10-06 CODE][TOOL] C ABI v2 stable snapshot state landed in `ef29203`:
  engine object/instance IDs, mutation revisions, owned canonical meshes, one
  coherent snapshot read, immutable Swift values, and stable renderer caches.
- [2026-10-06 CODE] `AppEnvironment` now owns process-lifetime client stores.
  `DocumentStore`, `PresetStore`, `SliceService`, `EnginePaths`, and
  `StatusCenter` own engine/file/job policy; `PlaterView` is presentation-only.
- [2026-10-06 CODE] All blocking engine/file operations use one typed detached
  work boundary. Document busy/stale/preview rules and transactional preset
  persistence are centralized; slice outcomes carry source revision/config.
- [2026-10-06 TOOL] Core archive rebuilt at 258/258 unique (shim retirement)
  with matching headers; the decomposed Swift client passes a warning-free
  redirected xtool build.

## DISCOVERIES

- [2026-10-06 CODE] Upstream `ObjectBase::s_last_id` is not thread safe, so the
  Bridge process-serializes guarded engine entry. Moving a `ModelObject*`
  between models leaves `m_model` dangling — transfer only through upstream
  `Model` APIs.
- [2026-10-06 CODE] Upstream `GCode.hpp` enables a placeholder check in
  non-NDEBUG builds that rejects upstream's own bundled presets; host tests
  mirror the shipped `-O2 -DNDEBUG`. libstdc++ doesn't leak `<memory>`/
  `<type_traits>` like libc++ — adapters go in `engine-sources.sh` per-file
  flags or shim fixes, never upstream patches.
- [2026-10-06 CODE] Current build remains machine-local: manual source closure,
  sequential TBB shims, ignored caches, and duplicated 12,006 profile JSONs.

## OUTCOMES

- [2026-10-06 TOOL] **GATE A VALIDATION CENSUS GREEN**: architecture audit
  10/10; host contract tests 183/183; warning-free redirected xtool build;
  archive 258/258 unique with header parity; upstream pristine. Build
  `d730eea` installed to iPoke — on-device acceptance loop (import →
  transform → presets → slice → Files) pending user verification.
- [2026-10-03 USER] Phase 1 accepted on device: a 483,772-triangle STL sliced
  through the real Orca pipeline to G-code in Documents; desktop compatibility
  was subsequently verified with real presets.
- [2026-10-02 USER] Phase 0/2 proof accepted: native Metal viewer at 60 fps,
  real STL repair/render, document import, camera controls, and engine slicing.
