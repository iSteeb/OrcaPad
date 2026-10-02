# LESSONS — OrcaPad

Corrected mistakes & durable project conventions. Append-only; compress old
entries when they stop earning their lines. (Toolchain-level xtool quirks live
in ~/xtool-cheatsheet.md — link, don't duplicate.)

## Conventions

- Build output always redirected to a file: `xtool dev build > /tmp/orcapad-build.log 2>&1`
- All app logging via `os_log` (`Logger(subsystem: "ie.duz.OrcaPad", …)`);
  `print()` is invisible for home-screen-launched apps.
- MSL shaders live ONLY in `Viewer/Shaders.swift` (runtime-compiled; the Linux
  toolchain cannot produce .metallib files). Swift-side uniform structs must
  keep field order identical to the MSL structs.
- Upstream (`upstream/orcaslicer`) is NEVER patched. Deviations are adapters:
  shim headers (Engine/shim/), force-includes (-include), or wrapper TUs in
  Engine/engine-cxx/. If an adapter becomes load-bearing, document it in
  PLANS.md's risk register.

## Lessons learned (2026-10-02, engine bring-up night)

### Process discipline — the expensive ones

- **Do NOT iterate build errors one at a time.** [USER called this out]
  Before the next build attempt, enumerate the FULL error surface: run a
  census compile of every candidate file (parallel, collect all failures),
  and/or compute the symbol closure up front (Engine/tools/closure.py, or the
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
- SwiftPM rejects mixed-language targets: C++ sources live in `Engine/`, Swift
  interop in `Sources/Engine/`, prebuilt artifacts in `Prebuilt/`.
- UNCONFIRMED: path-based binaryTarget may be cached under .build — if a
  rebuilt .a seems ignored, `rm -rf .build xtool/.xtool-tmp` before blaming
  the linker. (Suspected once; the real cause was analysis bugs, but the
  purge is cheap insurance.)

### Bash discipline

- `set -u` + empty-array expansion and `local` scoping inside $( ) bit twice.
  Keep build scripts dumb: manifest file + explicit failure exits + no clever
  process substitution.
