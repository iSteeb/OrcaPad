# OrcaPad architecture

Status: **normative target design**  
Last updated: 2026-10-06

OrcaPad is a native iOS/iPadOS client for OrcaSlicer. It reuses OrcaSlicer's
headless C++ behavior and implements the platform experience in SwiftUI and
Metal.

This document defines the boundaries all new work and migrations must follow.
`PLANS.md` defines delivery order; `CONTINUITY.md` records current execution
state.

## 1. Design values

In priority order:

1. **Correctness and desktop compatibility.** Engine semantics and project /
   G-code interoperability take precedence over convenience.
2. **Simplicity.** Use three top-level conceptual modules and add internal
   layers only when they enforce a real dependency or ownership boundary.
3. **Maintainability.** Solve classes of problems through explicit contracts;
   do not accumulate one-off patches.
4. **Loud failure.** Never silently ignore errors, substitute behavior, or
   infer success from diagnostic text.
5. **Upstreamability.** No private engine fork. Generally useful portability
   work belongs upstream.
6. **Native platform quality.** Touch-first SwiftUI and Metal, not a wrapped
   desktop interface.
7. **Feature parity where appropriate.** Missing dependencies are temporary
   implementation state, not permanent architectural exclusions.

## 2. The three modules

```text
Swift Client  ───────▶  Bridge  ───────▶  Untouched Engine
(SwiftUI/Metal/iOS)     (public API)      (upstream C++)
```

The arrows are the only permitted dependency direction.

### 2.1 Untouched Engine

Location today: `upstream/orcaslicer/`.

The engine module is the pinned upstream OrcaSlicer source and its third-party
engine dependencies. It owns slicing algorithms, model semantics, presets,
configuration definitions, project formats, arrangement/orientation, and
G-code processing.

Rules:

- Never edit the checked-out upstream worktree in OrcaPad.
- Never duplicate or reimplement slicing algorithms in the bridge or client.
- OrcaPad carries no private engine patch set.
- A required generic portability seam may be proposed and merged upstream;
  consuming that new upstream revision still satisfies this rule.
- Desktop-compatible behavior must be characterized before replacing an
  adapter with a different implementation.

"Untouched" means no private divergence. It does not forbid contributing
platform-neutral improvements to OrcaSlicer itself.

### 2.2 Bridge

Locations: `Bridge/`, `Sources/OrcaBridge/`, and the generated
`Prebuilt/OrcaBridgeCore.xcframework`.

The bridge is the only module allowed to include engine headers or import the
raw C module. It is an anti-corruption layer, not a second engine.

Responsibilities:

- expose a versioned, C-compatible public API
- contain all C++ exceptions before they cross the ABI
- define ownership and lifetime for every handle, string, and buffer
- translate typed engine failures into typed bridge failures
- provide stable document/object/instance identifiers
- provide revisioned immutable snapshots for the client
- serialize or document engine access and global-state constraints
- expose slicing as cancellable jobs with structured progress
- expose explicit capability discovery
- provide complete platform-service adapters (paths, logs, localization,
  temporary storage, atomic files, platform crypto where required)
- adapt build-time dependency surfaces without changing slicing semantics

Non-responsibilities:

- no SwiftUI, UIKit, Metal, gestures, or client presentation state
- no duplicate slicing/configuration logic
- no viewer-specific coordinate policy in the engine model
- no success/failure encoded in prose
- no silent no-op stubs or generic fallback behavior

The public contract should be organized by broad domains rather than UI
buttons:

```text
Runtime and capabilities
Preset/configuration repository
Document/model session
Scene/mesh snapshots
Project import/export
Slice jobs and results
G-code preview data
Diagnostics and logging
```

#### Temporary shims

A shim is acceptable only when it is:

1. isolated inside the bridge,
2. a complete implementation of a documented platform contract,
3. covered by focused tests or parity fixtures,
4. incapable of silently changing supported engine semantics, and
5. removable without changing the client API.

If a feature is unavailable, the bridge reports an explicit unsupported
capability. It must not satisfy the linker with a fake success path.

### 2.3 Swift Client

Location: `Sources/OrcaPad/` plus the typed Swift side of the bridge.

The client owns the native product:

- Swift value types and typed async engine access
- document/window lifecycle
- SwiftUI feature presentation
- touch, keyboard, and pointer interaction
- Metal rendering
- iOS persistence and security-scoped file access
- application support, export, and sharing
- printer discovery, credentials, and platform networking

The client may have internal folders or Swift targets, but these are not new
top-level architecture modules. Split a target only when separate compilation
meaningfully enforces the contract.

Recommended internal boundaries:

```text
Bridge Swift facade   raw ABI → typed Swift errors/values/async calls
Domain                IDs, revisions, transforms, snapshots, commands
Application state     document session and feature stores
Persistence           UIDocument, autosave, paths, import/export
Renderer              all Metal types and derived GPU state
Features              SwiftUI views and interaction logic
```

Only the bridge's Swift facade may use `OpaquePointer`, `UnsafePointer`,
`Unmanaged`, raw callbacks, or imported C structs.

## 3. State ownership

There is one authoritative mutable representation of slicer-domain state:

```text
C++ DocumentSession / Slic3r::Model
```

Swift and Metal necessarily use different representations, but they are
strictly derived:

```text
Authoritative C++ model at revision N
        │
        ├──▶ immutable Swift SceneSnapshot(revision: N)
        │
        └──▶ renderer cache / Metal buffers for revision N
```

Rules:

- Engine-issued stable IDs identify documents, plates, objects, volumes, and
  instances. Collection indices are never identity.
- Every successful domain mutation advances a document revision.
- Mutations return the resulting revision or snapshot; the client does not
  manually predict structural engine changes.
- Renderer state is a cache keyed by stable ID and revision.
- Swift may keep transient gesture state for responsiveness. A completed
  gesture is committed as a command and replaced by the authoritative result.
- Stale snapshots and stale slice results are detectable, never silently
  treated as current.

## 4. Commands and snapshots

The client sends intent as typed commands, for example:

```text
ImportModel
DeleteObject
AddInstance
SetInstanceTransform
ArrangePlate
OrientObject
ApplyConfigPatch
SelectPresets
```

The bridge returns a typed result and a revisioned snapshot or targeted delta.
Start with full immutable snapshots for correctness and simplicity. Introduce
deltas only after profiling demonstrates a need.

A scene snapshot contains client-safe values only. It never aliases mutable
engine memory beyond a documented synchronous copy scope.

## 5. Concurrency and jobs

- A document session has one documented serialization boundary.
- Long-running slicing does not hold the mutable document lock.
- Starting a slice captures an immutable model revision and resolved config.
- The user may continue editing while the captured revision slices.
- Slice results carry source revision and configuration identity.
- Cancellation uses the engine's cooperative cancellation path.
- Progress callbacks document their thread and are converted to `AsyncStream`
  or equivalent typed Swift events by the bridge facade.
- Process-wide engine globals are initialized once by a runtime owner; they
  are not mutated opportunistically by independent handles.

## 6. Error and invariant contract

Human-readable text is diagnostic data, never control flow.

Every bridge operation returns a typed status such as:

```text
ok
invalidArgument
invalidHandle
notFound
unsupportedCapability
cancelled
ioFailure
invalidModel
invalidConfiguration
engineFailure
outOfMemory
internalInvariant
```

Each failure includes contextual diagnostics suitable for the UI and `os_log`.
Messages may change without changing behavior.

Rules:

- C++ exceptions never cross the bridge boundary.
- No shared static result strings.
- No empty catches, `try?` for required operations, or log-and-continue paths.
- Output values are valid only on success and are initialized defensively.
- Unsupported behavior is a capability result, not a stubbed success.
- Development builds assert internal invariants.
- Production builds surface typed failures rather than corrupting state.
- Cleanup/destructor paths are non-throwing and preserve diagnostics from the
  originating operation.

## 7. Capabilities and feature parity

The bridge exposes supported capabilities. The client presents only behavior
that the current engine build can execute correctly.

Capabilities include at least:

```text
STL / OBJ import
Orca/Bambu 3MF project import and export
STEP import
Arrangement and orientation
Slicing and cancellation
G-code thumbnails
G-code preview data
Mesh booleans
Parallel execution
```

A capability being absent now does not make it a non-goal. `PLANS.md` tracks
when appropriate desktop parity is delivered.

## 8. Rendering boundary

The renderer is part of the Swift client and knows nothing about engine
handles. It consumes immutable render snapshots.

- Engine/domain coordinates remain canonical and documented.
- One tested client mapper converts engine Z-up coordinates to Metal space.
- Mesh resources are cached by stable mesh ID and revision.
- Instance transforms do not require rebuilding immutable mesh resources.
- Picking produces stable domain IDs.
- GPU or spatially accelerated picking replaces O(triangle × instance) scans
  before large-scene support is considered complete.
- Bed shape and dimensions come from the selected printer configuration.
- `libvgcode` parsing/data semantics may be reused, but its OpenGL renderer is
  not used on iOS. Shared data processing and backend rendering must be split.

## 9. Presets, settings, and resources

- Upstream profile files have one source of truth.
- Read-only system profiles and writable user data have separate explicit
  roots; the client does not emulate this contract through user-visible
  Documents storage long-term.
- Presets use stable IDs and expose compatibility metadata and rejection
  reasons, not names alone.
- Settings UI is generated from versioned `ConfigOptionDefs` schema.
- Client edits are typed config patches validated by the engine.
- Profile/config migrations preserve desktop project compatibility.

## 10. Testing contract

Architecture is enforced by tests, not comments alone.

Required layers:

1. C ABI compile/ownership/error tests.
2. Bridge unit tests for handles, IDs, revisions, capabilities, cancellation,
   and concurrency.
3. Desktop/iOS parity fixtures for models, presets, normalized G-code, layer
   counts, tool changes, warnings, and estimates.
4. Swift domain/store tests without Metal or device dependencies.
5. Renderer math and snapshot tests, followed by device visual/performance
   tests.
6. 3MF round-trip and malformed-input tests.
7. End-to-end physical-device acceptance for each product phase.

A feature is incomplete if its broad failure modes and state transitions are
not tested.

## 11. Build-system status

The current machine-local cross-build is accepted temporarily. Reproducible
CMake, simulator slices, CI, signed distribution, offline Metal compilation,
and canonical resource packaging are required before upstream submission, but
they are not the immediate architecture-cleanup priority.

New feature work must not deepen reliance on manual source lists, hidden cache
state, or additional fake dependency surfaces.

## 12. Migration order

1. Establish and document the three-module boundary.
2. Align repository/package names with that boundary.
3. Replace prose-based bridge status with one typed result contract.
4. Introduce runtime/session ownership, stable IDs, and revisions.
5. Replace mutable Swift model mirroring with authoritative snapshots.
6. Decompose `PlaterView` into document state, services, and presentation.
7. Add contract and parity tests while migrating each domain.
8. Continue feature parity through complete vertical capabilities.
9. Make the build reproducible and prepare a sequence of upstream PRs.

## 13. Architectural definition of done

The foundation migration is complete when:

- the repository visibly contains Engine, Bridge, and Swift Client boundaries;
- dependency direction is mechanically enforceable;
- no client code imports raw engine/C ABI types outside the facade;
- no bridge function infers success from text or returns shared mutable text;
- engine objects have stable IDs and document revisions;
- Swift and Metal state are derived snapshots, not competing authorities;
- slicing is a cancellable immutable-revision job;
- unsupported features are explicit capabilities;
- broad contracts have focused tests; and
- the physical-device STL/3MF → arrange → configure → slice → preview/export
  loop remains desktop-compatible.
