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
- `AppEnvironment` is the process-lifetime owner of client stores and Bridge
  sessions. SwiftUI views are presentation-only: no raw engine calls,
  `FileManager` policy, preset persistence, or detached slicing orchestration.
- Blocking engine and filesystem work crosses the single typed
  `BackgroundWork` boundary; `@MainActor` stores own observable state and busy
  gates so commands reject rather than silently queue.
- The status/debug overlay is hidden by default [USER]; pressing the Device
  tab button 5x within 3 s toggles it (RootView counts selection-binding
  setter calls, which fire on re-presses). Never surface it by default.
- UIKit gesture locations are POINTS; `MTKView.drawableSize` is PIXELS.
  Normalize picks/projections by `view.bounds.size` — using drawableSize
  cast every ray toward 1/3 of the touch on 3x screens (broken tap-select
  and drag-move until C6).
- Build output always redirected to a file: `xtool dev build > /tmp/orcapad-build.log 2>&1`
- Feature status lives ONLY in `Bridge/tools/parity-manifest.toml`; PARITY.md
  is generated (`parity-check.py --write`) and `--check` gates commits. The
  desktop surface is extracted from upstream, never hand-listed: a hand-kept
  parity table had silently drifted (e.g. "ActualVolumetric" claimed done
  with no client scheme).
- Test/build policy lives in AGENTS.md's "Builds, tests, and audits" matrix.
  The engine compile list is shared (`Bridge/engine-sources.sh`) — never fork
  it; host contract tests and the architecture audit are commit gates.
- Upstream `GCode.hpp` enables `ORCA_CHECK_GCODE_PLACEHOLDERS` in non-NDEBUG
  builds, and that check rejects upstream's OWN bundled presets
  (long_retraction_when_cut & co.). Host test builds therefore mirror the
  shipped `-O2 -DNDEBUG` config exactly — do not "fix" this by patching
  upstream; it is an upstream debug-mode inconsistency worth reporting there.
- libstdc++ does not transitively include `<memory>`/`<type_traits>` where
  Darwin libc++ does: upstream headers relying on that leak
  (`Format/objparser.hpp`) and our own shims need explicit includes. Adapter
  pattern: per-file `-include <header>` in `engine-sources.sh`, or fix the
  shim. Never patch upstream.
- Enum options (`ConfigOptionEnumsGenericTempl`) derive from
  `ConfigOptionInts` and serialize THROUGH `keys_map`; the static defaults
  inside `full_print_config()` carry a NULL `keys_map` (only
  `create_default_option` wires it), so a mutated enum silently serializes
  as empty. Set ordinals AND wire `keys_map` from `print_config_def`. Lock
  any interop-critical overlay with a contract-test assertion on the gcode.
- Before adding a loud stub, check whether the real upstream TU is portable:
  `GCode/Thumbnails.cpp` only needed a declaration-only jpeg shim + loud jpeg
  symbols; stubbing its pure string parser broke gcode loading.
- A ternary `cond ? std::string(...) : nullptr` unifies to `std::string` and
  throws "construction from null" — branch explicitly.
- `boost_filesystem_shim.cpp` is RETIRED: the real boost-filesystem-1.90
  sources superseded it and both defining the same symbols was a latent
  multiple-definition hazard. Do not reintroduce it.
- A host executable links ALL objects (no archive member-pull): pack objects
  into a static archive before linking host tests (`build-host-tests.sh`) to
  mirror iOS semantics, or dead-TU references (Thread.cpp →
  boost::thread::native_handle) surface as undefined symbols.
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
- `@Observable` stores take PLAIN stored properties; adding `@Published`
  breaks with "invalid redeclaration of synthesized property _x"
  (ObservationTracked vs Combine collide).
- ABI struct extensions must keep the Swift decode, the Swift ABI literal,
  the C header and the contract-test literal in ONE commit — the audit
  checks the literal match; the decoder silently keeps default values
  otherwise.

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
- The xtool darwin SDK record in `~/.swiftpm/swift-sdks` can vanish after a
  crashed concurrent build; restore it by symlinking
  `~/.config/swiftpm/swift-sdks/darwin.artifactbundle` (xtool then skips its
  NIO-based generator, which cannot epoll here).
- Never add profiles to xtool's `XTL-...` App IDs: `xtool dev` deletes the
  single existing profile and creates a new one on every run (with two or
  more it starts accumulating them). `xtool dev build --sign` on a fresh CI
  machine would mint a new development certificate per run. CI therefore
  signs with its own App ID (`ie.duz.OrcaPad`) and identity.

### CI / App Store distribution (2026-10-13)

- Never run xtool in CI: its macOS release binary (xtool.app) hung at launch
  on the GitHub runner (`xtool --version` printed nothing for 35 minutes;
  the build never started). CI builds with Xcode itself (XcodeGen project +
  xcodebuild); xtool stays the local Linux loop.
- Give every CI step that can block a `timeout-minutes`. A silent step is
  not necessarily a slow build: check whether its FIRST command printed.

- A static archive needs a symbol index for Apple's linker. Host GNU
  `ar rcs` cannot read Mach-O members and silently wrote an index-less
  archive that only lld tolerated. Use the toolchain's
  `llvm-ar --format=darwin` and check `llvm-nm --print-armap` starts with
  "Archive map" (build-core.sh and the audit enforce both).
- App Store Connect validates what xtool never produces: an asset-catalog
  icon (CFBundleIconName + opaque 1024px), DT* toolchain keys (Linux-built
  resource bundles carry placeholders such as DTXcodeBuild 99T999), a
  privacy manifest, export compliance. Only macOS can compile the icon
  (actool), so `.xcassets` live in `Distribution/`, never in `Sources/`.
- Required-reason API references differ between debug and release builds
  (dead-strip drops boost.filesystem's statfs/fstat): derive the privacy
  manifest from the RELEASE executable. The packaging script fails on an
  undeclared category instead of waiting for Apple's ITMS-91053 mail.
- Signing material (`~/orcapad-signing`) is off-limits to the agent: the
  user runs the commands that load it into GitHub secrets.
- GitHub Pages serves `.plist` as application/octet-stream, reported to
  break itms-services OTA installs (relevant if ad hoc OTA ever returns).
- History was rewritten on 2026-10-13 (author email to the GitHub noreply
  address): every earlier SHA changed; the commit map was applied to the
  tracked docs, but external notes may still cite old SHAs.

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
- [USER 2026-10-07] Do NOT use subagents in this repo/session environment —
  the tool returned empty output on every call. Do audits directly with rg.
- Entity snapshots must validate raw ABI values BEFORE calling a Swift
  initializer with preconditions, or a bad engine value traps instead of
  surfacing a typed BridgeFailure.
- Part picking/highlight (ABI v26 `merged_triangle_start/count`) relies on
  `ModelObject::raw_mesh()` concatenating PART volumes in document order;
  the snapshot builder FAILS LOUDLY when the ranges stop covering the merged
  mesh. Never weaken that check if upstream reshapes raw_mesh — a silent
  mismatch would mis-map every part pick.
- Plate membership is DERIVED from instance positions (ABI v27): never
  store a client-side copy as a second authority. The only stored state is
  the plate list (names/locks/pins); the engine's 3mf PlateData already
  carries names/locks/membership — adopt it on open, write it on save.
- Plate selection (like the camera) is session state: it must NEVER advance
  the revision, and undo/redo must NOT restore it (only clamp its index).
  Documents with zero plates are an internal-invariant failure — every
  plater is born with one.
- **Set the upstream plate context before every slice** (ABI v28 lesson):
  `Print::m_origin` (plate origin) has NO default initializer upstream — a
  fresh Print carries stack garbage, and desktop always calls
  `PartPlate::set_print → set_plate_origin` first. We saw NaN → `int64_min`
  G-code coordinates (`X-9223372036854775.808`, NaN→int32 in M73 times)
  that appeared/disappeared with innocent-looking frame changes (an extra
  never-dereferenced function argument!). `set_plate_origin(index)`+
  `set_plate_name` are now mandatory in every Bridge slice path; per-plate
  G-code is plate-relative and the client preview shifts it back.
- Desktop GUI-job engine quirks transfer verbatim: FillBedJob marks
  clone arrange-polys with bed_idx = MAX_PLATES_COUNT (256) so the nester
  places them into bed 0 — `arrangement::UNARRANGED` (-1) means "leave
  alone" and produces zero clones. Read the desktop job's setter, not just
  its count formula. Failed C calls zero their out-params (out_revision=0),
  so tests must re-sync expected revisions from a snapshot after
  expect_code paths.
- Release tags do NOT wait for a local iPoke install [USER 2026-10-14]:
  tag after the local gates are green; iPoke receives the build through
  TestFlight (external group) — device verification happens there, after
  Beta App Review approval.
- Diagnose engine corruption with a FAST standalone probe (link against
  `Bridge/build-host/libengine-host.a`, ~20 s iterations), never by rerunning
  the full host suite per hypothesis — a 6-minute gate per guess cost 45 min
  once (and a corrupted run can hang later arrange tests in nlopt).
- UBSan on the closure is a one-off `build-host-tests.sh` clone with
  `-fsanitize=undefined,float-cast-overflow`: it flagged our NaN→int64
  conversions AND upstream's own `WallToolPaths.cpp:693` invalid bool load
  (upstream issue material, not patchable here).
- All-or-nothing edit scripts lose EVERY edit when one anchor no longer
  matches (e.g. an edit that already landed on a previous run). Make each
  scripted edit idempotent (skip when the new text is present) or apply one
  edit per script, and verify the file afterwards — never assume it landed.
- The Swift ABI literal, the header macro and the contract-test literal must
  move together; only a RUNTIME check compared Swift vs header, so the Swift
  value drifted silently (8 vs 14). The audit now enforces the match.
- The engine's GCodeProcessor SliceWarning levels are its OWN scale (0/1/2
  plus a Studio-only 3 emitted beside a 2); desktop never fails a slice on
  them. Map engine enums onto ABI values at the Bridge - forwarding them raw
  made a successful slice fail at facade decode ("level 3 source 4"). The
  vitrification key is `temperature_vitrification` (coInts), not
  filament_vitrification_temperature.
- Before exposing an engine option, read its real key in PrintConfig.cpp
  (physical-printer host is `host_type`, coEnum — not `print_host_type`).
  Swift imports C fixed-size arrays as tuples — index them via byte offsets.
- Never use `rm -rf ./*` style cleanup [USER 2026-10-07]: create a fresh
  scratch dir instead of emptying one.
- Python edit scripts MUST assert t.count(old) before replace: two silent
  no-op replaces today shipped v20 without the snapshot mirrored flag
  (only the host test caught it).
- Edits whose oldText contains non-ASCII punctuation (em dash, ellipsis,
  arrows) repeatedly came out corrupted (a stray "\r" + garbage, or no
  match). Anchor edits on ASCII-only substrings, or rewrite the lines with a
  small checked Python script, then grep the result.
- iOS 17+ ATS blocks plain-HTTP IP-address hosts by default; LAN printers
  need NSAllowsLocalNetworking + private CIDR NSExceptionDomains (and
  NSAllowsArbitraryLoadsInWebContent for the printer web view).

### Config well-formedness (2026-10-15, TestFlight 0.2.0 crash)
- The engine's ToolOrdering copies `filament_count^2` floats per nozzle from
  `flush_volumes_matrix` with NO size guard — an empty vector = memmove from
  a null buffer = guaranteed SIGSEGV ("crashes when slicing", iPad11,4,
  0.2.0 build 5.1). Desktop never guards this either; it survives on three
  pipeline properties: print_config_def defaults always present,
  `PresetBundle::full_config()` normalizing per-filament vectors
  (repeat-last-value padding to the extruder count), and GUI editors never
  writing shape-invalid vectors.
- The correct fix class is NOT a per-option band-aid at the crash site:
  (1) fix OUR poisoning source (set_value/preset-save writing empty
  vectors — same class as the enum keys_map empty-serialization), and
  (2) one general config finalization at the Bridge slice boundary applying
  desktop's normalization semantics to EVERY vector option + matrix-shape
  validation, with repairs surfaced as slice-report warnings so future
  poisoning is observable. Engine receives only desktop-grade configs.
- Never "catch" engine SIGSEGVs at the ABI boundary (signal handlers):
  post-segfault engine state is untrustworthy and it hides real bugs.

### Desktop-default verification findings (2026-10-19 audit)
- Desktop `ArrangeSettings.distance` defaults to 0 — arrange spacing comes
  from per-item brim inflation (`update_selected_items_inflation`), NOT a
  fixed 6 mm. Hardcoding 6 diverged from every default arrange on desktop.
- Desktop OrientJob reads `support_threshold_angle` PER OBJECT first, then
  the bundle config, then 60° — bundle-only reads miss per-object overrides.
- When porting a desktop job, port its PARAMETER INITIALIZATION verbatim
  (init_arrange_params / OrientJob::prepare), not just the engine call.

### UI direction from user feedback (2026-10-19, device round 2)
- Multi-plate MUST stay visible: other plates render as dimmed outlined
  beds WITH their (faded) objects beside the current plate — removing them
  for "desktop parity" was wrong for this app's plate-grid model.
- One wide pill top bar per tab is THE chrome pattern (Plate, Preview,
  Device): Undo/Redo | Menu (file+objects) | Arrange | Tools; the left
  gizmo rail is retired. Tools live in a collapsible bottom half-modal:
  collapsed = touch manipulation with live readouts + axis chips,
  expanded = numeric entry. Rotate: tapping the selected model cycles the
  axis focus.
- Never clamp UI to "what desktop does" when the user's model differs -
  the plate grid and the touch manipulation flow are OrcaPad's own.

### Profile refresh and macOS builds (2026-10-25)
- Do not infer engine incompatibility from singleton arrays in newer JSON:
  the 2.4.2 loader already deserializes these. Check with the matching engine.
- Load profiles through each vendor index; filament subdirectories are nested.
  Non-recursive globs falsely report missing default filaments.
- Qualify Swift.abs and use explicit simd_mul where Xcode 26's C++ interop
  overloads make scalar comparisons or matrix/vector products ambiguous.
- Keep unrelated patch hunks separate: a bad anchor in one file rejects the
  whole multi-file patch. Check the outcome before assuming any hunk landed.
