#!/usr/bin/env bash
# Builds the C++ engine artifacts for iOS (arm64) from Linux and packs them
# into hand-rolled xcframeworks under Prebuilt/.
#
# Why hand-rolled: xcodebuild -create-xcframework is macOS-only. The layout
# is just directories + Info.plist; SwiftPM consumes it fine as long as each
# AvailableLibraries entry carries a HeadersPath.
#
# Toolchain: swiftly clang (cross-compiles to arm64-apple-ios with the
# artifactbundle SDK). Executable LINKING must be left to SwiftPM/xtool —
# the host lld cannot link iOS executables (unsupported platform/TAPI).
#
# Layout:
#   Engine/engine-cxx/        C++ sources (single source of truth)
#   Prebuilt/CxxProbe.xcframework/   output consumed by SwiftPM binaryTarget

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"     # repo root
SDK="${SDK:-$HOME/.config/swiftpm/swift-sdks/darwin.artifactbundle/Developer/Platforms/iPhoneOS.platform/Developer/SDKs/iPhoneOS27.0.sdk}"
CLANG="${CLANG:-$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin/clang++}"
TARGET="arm64-apple-ios17.0"
OUT="$ROOT/Prebuilt/CxxProbe.xcframework/ios-arm64"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

echo "==> building CxxProbe for $TARGET"
mkdir -p "$OUT/Headers"
cp "$ROOT/Engine/engine-cxx/probe.h" "$OUT/Headers/probe.h"

"$CLANG" -target "$TARGET" -isysroot "$SDK" -std=c++17 -O2 \
    -I"$ROOT/Engine/engine-cxx" \
    -c "$ROOT/Engine/engine-cxx/probe.cpp" -o "$WORK/probe.o"
ar rcs "$OUT/libCxxProbe.a" "$WORK/probe.o"
file "$OUT/libCxxProbe.a"
echo "==> done: $OUT/libCxxProbe.a"
