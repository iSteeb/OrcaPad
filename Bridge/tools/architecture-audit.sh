#!/usr/bin/env bash
# Static architecture contract audit — run before every commit.
# Verifies module boundaries, engine purity, ABI packaging, and the
# no-silent-failure discipline WITHOUT building anything.
set -u
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
failures=0

report() { # report <PASS|FAIL> <description>
    printf '%s  %s\n' "$1" "$2"
    [ "$1" = FAIL ] && failures=$((failures + 1))
}

# 1. Upstream engine is pristine (never privately patched).
if [ -z "$(git -C "$ROOT/upstream/orcaslicer" status --porcelain 2>/dev/null)" ]; then
    report PASS "upstream/orcaslicer is unmodified"
else
    report FAIL "upstream/orcaslicer has local modifications"
fi

# 2. Packaged C ABI header is byte-identical to the source header.
if cmp -s "$ROOT/Bridge/engine-cxx/orca_bridge.h" \
          "$ROOT/Prebuilt/OrcaBridgeCore.xcframework/ios-arm64/Headers/orca_bridge.h"; then
    report PASS "packaged orca_bridge.h matches source"
else
    report FAIL "packaged orca_bridge.h differs from source — rebuild the archive"
fi

# 3. Archive has no duplicate or stale members.
total=$(ar t "$ROOT/Prebuilt/OrcaBridgeCore.xcframework/ios-arm64/libOrcaBridgeCore.a" | wc -l)
unique=$(ar t "$ROOT/Prebuilt/OrcaBridgeCore.xcframework/ios-arm64/libOrcaBridgeCore.a" | sort -u | wc -l)
if [ "$total" -eq "$unique" ] && [ "$total" -ge 250 ]; then
    report PASS "archive: $total members, $unique unique"
else
    report FAIL "archive: $total members, $unique unique (duplicates or shrinkage)"
fi

# 4. Raw C ABI use is confined to Sources/OrcaBridge.
raw_abi=$(grep -rEl 'OrcaBridgeCore|OpaquePointer|orca_[a-zA-Z0-9_]+\s*\(' \
    "$ROOT/Sources/OrcaPad" 2>/dev/null || true)
if [ -z "$raw_abi" ]; then
    report PASS "raw ABI confined to Sources/OrcaBridge"
else
    report FAIL "raw ABI references leaked into the client:"$'\n'"$raw_abi"
fi

# 5. Package dependency direction: OrcaPad → OrcaBridge → OrcaBridgeCore.
client_deps=$(sed -n '/name: "OrcaPad"/,/target/p' "$ROOT/Package.swift" | grep -c 'OrcaBridgeCore' || true)
if [ "$client_deps" -eq 0 ]; then
    report PASS "Package.swift: client links only OrcaBridge"
else
    report FAIL "Package.swift: OrcaPad target references OrcaBridgeCore directly"
fi
if grep -q 'OrcaBridgeCore' "$ROOT/Package.swift"; then
    report PASS "Package.swift: OrcaBridgeCore binary target present"
else
    report FAIL "Package.swift: OrcaBridgeCore binary target missing"
fi

# 6. No silent-failure patterns in Swift sources (empty catch / try?).
empty_catch=$(grep -rEUn 'catch\s*\{\s*\}' "$ROOT/Sources" 2>/dev/null || true)
try_q=$(grep -rn 'try?' "$ROOT/Sources" --include='*.swift' 2>/dev/null || true)
if [ -z "$empty_catch" ] && [ -z "$try_q" ]; then
    report PASS "no empty catch blocks or try? in Swift sources"
else
    report FAIL "silent-failure patterns found:"$'\n'"$empty_catch"$'\n'"$try_q"
fi

# 7. All Metal shader source lives in Viewer/Shaders.swift (runtime-compiled).
metal_files=$(find "$ROOT/Sources" -name '*.metal' -o -name '*.xcassets' 2>/dev/null || true)
if [ -z "$metal_files" ]; then
    report PASS "no offline Metal assets (runtime MSL only)"
else
    report FAIL "offline Metal/xcassets found: $metal_files"
fi

# 8. Generic config overlays appear ONLY on the preset-free slice paths
#    (definition + the two defaults paths; never after full_config()).
overlay_count=$(grep -c 'orcapad_config_overlays' \
    "$ROOT/Bridge/engine-cxx/orca_bridge.cpp" || true)
preset_slice=$(awk '/orca_plater_slice_to_gcode_with_presets/,/^}/' \
    "$ROOT/Bridge/engine-cxx/orca_bridge.cpp")
if [ "$overlay_count" -eq 3 ] && ! grep -q 'orcapad_config_overlays' <<<"$preset_slice"; then
    report PASS "config overlays only on preset-free slice paths"
else
    report FAIL "config overlay discipline violated (count=$overlay_count)"
fi

# 9. Bridge sources contain no iOS/Swift/UI references.
client_headers=$(grep -rn 'include <UIKit\|import SwiftUI\|import UIKit' \
    "$ROOT/Bridge/engine-cxx" 2>/dev/null || true)
if [ -z "$client_headers" ]; then
    report PASS "Bridge C++ has no client-platform references"
else
    report FAIL "Bridge C++ references client platform:"$'\n'"$client_headers"
fi

echo
if [ "$failures" -eq 0 ]; then
    echo "architecture audit: PASS"
    exit 0
fi
echo "architecture audit: $failures FAILURE(S)"
exit 1
