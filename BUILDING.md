# Building OrcaPad (and your own modified copy)

OrcaPad is free software under the [GNU AGPL v3.0](LICENSE). These
instructions exist so that anyone can build the app — and install their own
modified version on their own device ([COMPLIANCE.md](COMPLIANCE.md) W5).

## What you need

- A Linux x86-64 box (Ubuntu 26.04 is the reference host; the engine
  compiles against its boost / Eigen / CGAL / GMP / MPFR headers —
  `sudo apt install libboost-dev libeigen3-dev libcgal-dev libgmp-dev
  libmpfr-dev`).
- [xtool](https://github.com/xtool-org/xtool) (the Linux-hosted iOS Swift
  toolchain) and its prerequisites (mise/swift SDK — see xtool's docs).
- `git`, `python3`, `cmake`-free: everything else is fetched automatically.

Build-only third-party sources (NLopt, boost.thread, cereal) are cloned into
`Bridge/cache/` (gitignored) with pinned tags by `Bridge/engine-sources.sh`.
The OrcaSlicer engine comes as a git submodule, pinned at a release tag.

## Build

```bash
git clone --recurse-submodules https://github.com/iSteeb/OrcaPad
cd OrcaPad

# 1. engine archive (cross-compiled for iOS; writes Prebuilt/)
./Bridge/build-core.sh

# 2. the app
xtool dev build

# 3. optional: run the host contract tests against the same engine closure
./Bridge/build-host-tests.sh
```

## Install your own build on your own device

- **With xtool (Linux)**: plug in the device, then `xtool dev` installs the
  dev-signed app (bundle id prefixed `XTL-…`). Launch it from the home
  screen.
- **With Xcode (macOS)**: generate a project
  (`xtool dev generate-xcode-project` or XcodeGen with
  `Distribution/project.yml`), open it, select your *free personal team*,
  and run on your device. Free profiles expire after 7 days — rebuild and
  reinstall to refresh.
- **In the EU**: your self-built IPA can also be sideloaded via alternative
  marketplaces / web distribution under the DMA rules.

`xtool dev build` release artifacts are unsigned — never distribute them;
distribution is TestFlight/App Store (built by CI) or your own signing.

## Bundled profile checks

`Sources/OrcaPad/Resources/profile-source.json` records the exact upstream
revision used for the bundled JSON profiles. The engine remains pinned
independently; refreshing profiles does not enable newer engine features or
online profile updates.

To check the indexes and slice a 10 mm cube with the default process/PLA
profiles for all four QIDI X-Plus 5 nozzle sizes, use the desktop executable
from the official OrcaSlicer **2.4.2** release (matching OrcaPad's engine):

```bash
python3 Bridge/tools/smoke-test-qidi-plus5.py --slicer /path/to/OrcaSlicer
```

The check uses fresh temporary settings and output directories. It does not
replace iOS runtime or physical printer verification.

## Releases

CI builds and ships the app only when a `release*` tag is pushed: the
complete corresponding source archive for every release (including the
submodule, dependency pins, and host headers) is attached to that tag's
GitHub Release by `Bridge/tools/make-source-archive.sh`. If you rebuild from
a release archive, the versions in `ARCHIVE-MANIFEST.txt` inside it match
the shipped binary exactly.

## License

Everything you build from this repository is a combined work under the
GNU AGPL v3.0 — see [LICENSE](LICENSE) and [THIRD_PARTY.md](THIRD_PARTY.md).
Keep notices and attribution intact when you redistribute (also required:
the complete corresponding source of whatever you convey).
