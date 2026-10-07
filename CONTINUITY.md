# CONTINUITY — OrcaPad

## PLAN

- Current goal: Gate C — four-tab desktop-parity UX (Plate / Prepare /
  Preview / Device) over the clean three-module architecture. [USER]
- Priority order [USER 2026-10-06]: tab shell + clean refactor → Prepare
  desktop parity → Preview gcode parity → Plate transform UI (current
  move/rotate judged poor by user — redo in C6).
- Done: C1 shell, C2/C5 Prepare (extracted desktop layout, ABI v4
  overrides), C3/C4 Preview (ABI v6 toolpath, range/move scrubbing, schemes,
  legend), C6 Plate gizmos + numeric panel; debug overlay hidden (5x Device).
- [2026-10-13] C6c-1 done (ABI v7 full transforms + mode panels + Preview
  dock, `8d4cdaf`); on-device check of it by user PENDING.
- Next (needs user choice): rank from PARITY.md — #1 curr_bed_type bug,
  #2 export/open G-code, #3 cancel+warnings, #4 3MF, #5 C5b presets.

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

- [2026-10-13 CODE][TOOL] ABI v7 (`8d4cdaf`): host contract 29,837 checks
  green; audit PASS; installed on iPoke. PARITY.md written.
- [2026-10-06 CODE][TOOL] Gate C1–C6 (compressed): tab shell; Prepare editor
  (Tab.cpp layout, ABI v4 overrides); Preview (ABI v5/v6 toolpath, schemes,
  legend, scrubbers); Plate gizmos + picking fix (`cc85933`); overlay toggle.

- [2026-10-06 CODE][TOOL] Gate A/B infrastructure (compressed): shared
  `engine-sources.sh` list; host contract suite + archive-style link;
  10-check architecture audit; stable IDs/revisions/snapshots (`ef29203`);
  AppEnvironment + stores/services decomposition (`3f7b0a9`); placement from
  machine bed, vendor/compat preset metadata, resolved config (`72892e6`).

## DISCOVERIES

- [2026-10-13 CODE] Bridge never sets project `curr_bed_type`; GCode.cpp:2154
  picks bed temps by it, default btPC → all slices use Cool Plate temps.
  Desktop calib models are .drc (draco not vendored); 3MF needs only vendored
  miniz+expat. Subagent tool returns empty output — don't use it [USER].

- [2026-10-06 CODE] Upstream `ObjectBase::s_last_id` is not thread safe, so the
  Bridge process-serializes guarded engine entry. Moving a `ModelObject*`
  between models leaves `m_model` dangling — transfer only through upstream
  `Model` APIs.
- [2026-10-06 CODE] Bed origin placement is MACHINE-DEPENDENT (604 corner-style
  vs 53 centered profiles in the bundled tree, e.g. FLSun deltas). Never
  assume an origin: derive the frame from the `printable_area` polygon. The
  upstream debug-mode placeholder check rejects upstream's own presets, so
  host tests mirror the shipped `-O2 -DNDEBUG`. libstdc++ doesn't leak
  `<memory>`/`<type_traits>` like libc++ — adapters go in `engine-sources.sh`
  per-file flags or shim fixes, never upstream patches.
- [2026-10-06 CODE] Current build remains machine-local: manual source closure,
  sequential TBB shims, ignored caches, and duplicated 12,006 profile JSONs.

## OUTCOMES

- [2026-10-06 USER] Gate B on device: builds and slices; placement/rotate UX
  rejected as poor → redesign queued as C6. Gate A census green earlier.
- [2026-10-03 USER] Phase 1 accepted on device: a 483,772-triangle STL sliced
  through the real Orca pipeline to G-code in Documents; desktop compatibility
  was subsequently verified with real presets.
- [2026-10-02 USER] Phase 0/2 proof accepted: native Metal viewer at 60 fps,
  real STL repair/render, document import, camera controls, and engine slicing.
