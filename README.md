# OrcaPad

OrcaSlicer's slicing engine, natively on iPadOS: a SwiftUI shell and a Metal
3D viewer around the untouched C++ engine from
[OrcaSlicer](https://github.com/OrcaSlicer/OrcaSlicer) — no wxWidgets, no
OpenGL, no Catalyst. Import a model, arrange it, pick presets, slice, inspect
the toolpath, and send the G-code to your printer.

Status: early TestFlight (feature parity in progress — see
[PLANS.md](PLANS.md)).

## License, source, and attribution

- OrcaPad is free software: the **entire repository** (engine boundary,
  app, viewer, tooling) is licensed under the
  [GNU AGPL v3.0](LICENSE) (SPDX: `AGPL-3.0-only`).
- OrcaPad **contains and modifies OrcaSlicer**, pinned as a git submodule
  at [upstream/orcaslicer](upstream/orcaslicer). OrcaSlicer © SoftFever and
  contributors, and is itself based on Bambu Studio, PrusaSlicer, and
  Slic3r. Their copyright and legal notices are retained in the submodule.
- OrcaPad is an independent community project. It is **not affiliated
  with, or endorsed by**, SoftFever, the OrcaSlicer project, Prusa
  Research, or Bambu Lab.
- Complete third-party component licensing is inventoried in
  [THIRD_PARTY.md](THIRD_PARTY.md).
- Every released build corresponds to a `release*` git tag. The complete
  corresponding source for each release (including submodule contents) is
  attached to that tag's GitHub Release as
  `OrcaPad-<version>-full-source.tar.gz` — no charge, no restrictions
  beyond the AGPL.

App Store / TestFlight builds are offered under those same terms: the
program's license is the AGPL; see the in-app **About & Licenses** screen
for the license text, attribution, and the exact source of your binary.
Distribution terms and the Apple-EULA analysis are documented in
[COMPLIANCE.md](COMPLIANCE.md).

## Building

OrcaPad builds from a plain Linux box (and from macOS for the App Store
archive) — see [BUILDING.md](BUILDING.md), including how to build and
install your own modified copy on your own device.

## Contributing

Issues and pull requests are welcome at
[github.com/iSteeb/OrcaPad](https://github.com/iSteeb/OrcaPad). Read
[ARCHITECTURE.md](ARCHITECTURE.md) first — the three-module rule (Swift
client → Bridge → untouched engine) is normative.
