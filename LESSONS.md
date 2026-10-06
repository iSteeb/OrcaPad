# LESSONS — OrcaPad

Corrected mistakes & durable project conventions. Append-only; compress old
entries when they stop earning their lines. (Toolchain-level xtool quirks live
in ~/xtool-cheatsheet.md — link, don't duplicate.)

## Conventions

- Architecture is exactly three conceptual modules with one-way dependencies:
  Swift Client → Bridge → untouched upstream Engine. See `ARCHITECTURE.md`.
- The C++ document session is authoritative. Swift snapshots and Metal buffers
  are derived, revisioned representations — never competing mutable models.
- Solve recurring classes of problems through one typed contract; do not grow
  status-string checks, per-feature shims, index identity, or silent patches.
- Generic safety overlays belong only to the preset-free slice path. Applying
  them after `PresetBundle.full_config()` silently corrupts selected material
  and hardware values.
- Cross-handle calls hold both session locks for the full C operation, always
  in plater → presets order; borrowing an unlocked raw handle is a data race.
- Upstream `ObjectBase::s_last_id` and other process globals assume
  single-threaded engine entry. Every guarded C ABI engine operation is
  process-serialized in the Bridge; do not weaken this until an upstream-safe
  runtime owner replaces it.
- Move/copy model objects only through upstream `Model` APIs such as
  `add_object`; pushing raw object pointers leaves `ModelObject::m_model`
  pointing at the source model and creates latent use-after-free failures.
- Authoritative `SceneSnapshot` values stay immutable. Gesture previews are a
  separate transient transform overlay and are cleared on every authoritative
  snapshot install.
- Build output always redirected to a file: `xtool dev build > /tmp/orcapad-build.log 2>&1`
- All app logging via `os_log` (`Logger(subsystem: "ie.duz.OrcaPad", …)`);
  `print()` is invisible for home-screen-launched apps.
- MSL shaders live ONLY in `Viewer/Shaders.swift` (runtime-compiled; the Linux
  toolchain cannot produce .metallib files). Swift-side uniform structs must
  keep field order identical to the MSL structs.
- Upstream (`upstream/orcaslicer`) is NEVER privately patched. Temporary
  adapters live under `Bridge/shim/` or `Bridge/engine-cxx/`; generic
  portability improvements go upstream. If an adapter becomes load-bearing,
  document it in
  PLANS.md's risk register.

### Swift 6 / simd specifics (2026-10-03)
- `SIMD4<Float>` has NO `.xyz` swizzle in Swift — spell out
  `SIMD3(v.x, v.y, v.z)`. `simd_min/max` are BINARY only (no variadic).
- Property access inside string interpolation counts as closure capture →
  hoist to a local before `logger.notice("\(x)")`.
- @unchecked Sendable wrapper + internal NSLock is the working pattern for
  engine handles that must cross into Task.detached (engine not reentrant).

## Lessons learned (2026-10-03, engine bring-up night)

### Build-pressure & session discipline (2026-10-03 evening)
- **12 parallel clang++ jobs froze the box** (14 cores / 14GiB RAM, heavy
  CGAL/Eigen TUs → swap death; a pi session died mid-build). Cap is now
  ORCAPAD_JOBS (default 6) + nice 15 in build-core.sh. Don't raise it for
  interactive sessions.
- **Never invent script flags.** `build-core.sh --dry-run` doesn't exist —
  the invocation ran a REAL build with output discarded. If you need a
  dry-run, add one; otherwise read the script.
- **Verify state, don't forensically reconstruct it.** When two builds'
  artifacts interleave, single-run logs mislead (a FAILED(no object) line
  for an .o that exists seconds later). Ground truth: rerun the script —
  mtime incremental + archive member guard + strings on the artifact.
- **Each source appears once in the archive manifest.** Duplicate compile jobs
  race on the same `.o`/depfile and may use conflicting force-includes. The
  build now rejects duplicate object paths before launching any compiler.

### Process discipline — the expensive ones

- **Do NOT iterate build errors one at a time.** [USER called this out]
  Before the next build attempt, enumerate the FULL error surface: run a
  census compile of every candidate file (parallel, collect all failures),
  and/or compute the symbol closure up front (Bridge/tools/closure.py, or the
  linker itself as oracle). One fix batch beats N fix cycles. Reactive
  whack-a-mole cost ~8 rebuild cycles on night one.
- **Never pair `edit` + `bash` (build/git) as parallel tool calls.** Twice the
  build/commit ran against a half-written file: once a commit silently missed
  changes, once a stale script "succeeded" with an empty archive. Sequential
  edit → build, always.
- **Truncated grep is a lie.** `grep -rl … | head -2` made VoronoiOffset.cpp
  look like a "caller only"; it was the DEFINER of annotate_inside_outside.
  Full sweeps only, and distinguish definer from caller by evidence (nm says
  defined/undefined; signature+body in source), not by guesswork.
- **Ground-truth precedence: linker > llvm-nm on the archive > grep on
  sources > own reasoning.** When the linker and my analyzer disagreed, the
  linker was right every time. A home-grown analyzer is a hypothesis, not an
  oracle — it shipped with 3 bugs (below) and still has an unexplained
  kept-set discrepancy vs ld64. Debug the tool before trusting a "zero
  remaining" claim.
- Command substitution swallows exit codes: a compile() wrapped in $( ) that
  always echoes will report success on failure. Compile functions must
  hard-fail (exit 1) and write to a manifest consumed at archive time.

### Cross-compilation gotchas (durable)

- **Debian multiarch headers**: gmp.h/mpfr.h live in
  /usr/include/x86_64-linux-gnu/, not /usr/include/ — a symlink to the wrong
  path dangles silently and surfaces later as "incomplete type gmp_int".
- **Never `-I/usr/include`** for an iOS-targeted build — glibc headers shadow
  the Darwin SDK. Symlink ONLY the needed header trees (boost, Eigen, CGAL,
  gmp.h, cereal) into the generated include dir.
- **Shim include dir must PRECEDE the symlinked real headers.** Real
  boost/log/trivial.hpp beat the shim once → boost::log runtime symbols at
  final link. Include order in build-core.sh is load-bearing, commented.
- **Mach-O symbols carry a leading underscore**: filters written as
  `_ZN6Slic3r` miss actual `__ZN6Slic3r…`. Bite me once in the union-check
  script (reported a false "0 unresolved").
- **llvm-nm line formats**: undefined = 2 fields ("U sym"), defined = 3 fields
  ("addr LETTER sym"); vtables/typeinfo are letters V/v (and W/D/S…) — a
  letters-list missing V silently drops RTTI from the closure.
- Host binutils nm/ar can't parse Mach-O members — always the toolchain's
  llvm-nm for archive inspection.
- **lld on Linux cannot link iOS executables** (no iOS platform support +
  arm64e.x1 TAPI syntax unknown). Fine: cross-build STATIC libraries only;
  the final executable link belongs to SwiftPM/xtool (proven working).
- Upstream sources rely on transitive includes that clang-for-Darwin doesn't
  provide (sstream in LocalesUtils, stdarg/stdio in qhullcpp usermem,
  limits.h→LONG_MAX in libtess). Adapter = force-include flags, never patches.
- CGAL CORE/BigInt instantiates boost::multiprecision::number<gmp_int> with
  only a fwd-decl present — needs `-include boost/multiprecision/gmp.hpp`
  before CGAL headers reach it.

### SwiftPM / xtool specifics

- `.interoperabilityMode(.Cxx)` must be on EVERY Swift target that (transitively)
  imports the C++ module — the app target included.
- Binary-target modulemap must NOT use `requires cplusplus` (SwiftPM's C-mode
  scanner rejects it); headers get `#if defined(__cplusplus)` guards instead.
- Hand-rolled xcframeworks need `HeadersPath` in each AvailableLibraries
  plist entry or the module won't resolve.
- SwiftPM rejects mixed-language targets: C++ adapters live in `Bridge/`, the
  Swift facade in `Sources/OrcaBridge/`, prebuilt artifacts in `Prebuilt/`.
- UNCONFIRMED: path-based binaryTarget may be cached under .build — if a
  rebuilt .a seems ignored, `rm -rf .build xtool/.xtool-tmp` before blaming
  the linker. (Suspected once; the real cause was analysis bugs, but the
  purge is cheap insurance.)

### Bash discipline

- `set -u` + empty-array expansion and `local` scoping inside $( ) bit twice.
  Keep build scripts dumb: manifest file + explicit failure exits + no clever
  process substitution.

### iOS runtime (2026-10-02, first engine crash)

- **Sandboxed apps CANNOT write /tmp** — only the container's temp dir
  (NSTemporaryDirectory / TMPDIR env). Hardcoded "/tmp" fopen returns NULL.
- **Never pass an unchecked FILE\* to fwrite** — a NULL FILE\* segfaults in
  flockfile with fault address ~0x68 (recognizable crash signature).
- Boundary rule: Swift owns ALL filesystem paths (sandbox-aware); the C++
  engine receives paths as arguments and every file op is checked with loud
  error strings returned to the UI — never crashes, never silent fallbacks.
- extern "C" boundaries must catch ALL C++ exceptions (…/std::exception)
  and convert to error strings — an exception escaping into Swift frames
  is std::terminate.
- Crash reports: `idevicecrashreport -e <dir>` (slow — background it) or
  pymobiledevice3; the .ips JSON carries exception type + symbolicated
  frames (our static-lib symbols show up by name — keep them unstripped).

### Renderer/engine boundary (2026-10-02, STL-import night)

- **Face-duplicated vertex arrays need SEQUENTIAL indices.** Engine meshes
  (post-admesh-repair) use deduplicated shared-vertex indices; after
  expanding to 3-verts-per-face for flat shading, the original index buffer
  points into wrong vertices → garbled mesh. Symptom signature: right
  position/size, scrambled triangles.
- **Test geometry hides bugs.** The unit cube is natively face-duplicated
  with matching indices — it silently survived both render bugs that
  garbled every real imported mesh. Verify new pipelines with real-world
  assets, not the placeholder.
- **Leftover transforms:** when a placeholder object's model matrix lives in
  the draw path (not its geometry), every later object inherits it. Bake
  placeholder transforms into placeholder vertices; draw paths stay identity.
- Swift "failed to produce diagnostic" ≈ usually a REAL error hiding
  elsewhere (missing member from a raced-away edit); fix the root, don't
  restructure around the opaque message.
- The parallel edit+bash race DID it again (expandFlat vanished; CONTINUITY
  commit aborted). RULE IS ABSOLUTE: after any edit/write, the next bash
  call runs in a SEPARATE tool turn. No exceptions for "quick" appends.
- Camera framing formula that worked: distance = max(bboxDim) × 2.6
  (clamped 110–1400), target at 45% of height, pitch 0.42 rad.
