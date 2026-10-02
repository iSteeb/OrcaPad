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

## Lessons learned

- (log the first one here when we burn ourselves — we will)
