#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
# Regenerates Sources/OrcaPad/Resources/config-schema.json from the pinned
# engine's print_config_def via Bridge/tools/extract_config.cpp (HOST tool).
#
# Requires: ./Bridge/build-host-tests.sh has been run in this tree (it builds
# the shared host engine archive this script links against).
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
SRC="$ROOT/upstream/orcaslicer/src"
DEPS="$ROOT/upstream/orcaslicer/deps_src"
CXX="${CXX:-$HOME/.local/share/swiftly/toolchains/6.4.0/usr/bin/clang++}"
BUILD="$ROOT/Bridge/build-host"
ARCHIVE="$BUILD/libengine-host.a"
OUT="$BUILD/extract_config"
SCHEMA="$ROOT/Sources/OrcaPad/Resources/config-schema.json"

[ -f "$ARCHIVE" ] || {
    echo "FATAL: $ARCHIVE missing — run ./Bridge/build-host-tests.sh first" >&2
    exit 1
}
[ -f "$ROOT/Bridge/cache/cereal/include/cereal/access.hpp" ] || {
    echo "FATAL: cereal cache missing — run a host/iOS build first" >&2
    exit 1
}

# Include set mirrors build-host-tests.sh (schema correctness depends on the
# same engine headers as the shipped archive).
CFLAGS=(
    -std=c++17 -O2 -DNDEBUG -Wno-deprecated-declarations
    -I"$ROOT/Bridge/shim-host"
    -I"$ROOT/Bridge/shim" -I"$ROOT/Bridge/shim/occt-stub"
    -I"$SRC" -I"$SRC/libslic3r" -I"$BUILD/gen"
    -I"$DEPS" -I"$DEPS/admesh" -I"$DEPS/qhull/src"
    -I"$DEPS/glu-libtess/include"
    -I"$DEPS/libigl" -I"$ROOT/Bridge/cache/Orca-deps-libnoise/src"
    -I"$DEPS/libnest2d/include"
    -I"$DEPS/clipper2/Clipper2Lib/include" -I"$DEPS/expat/expat/lib"
    -I"$DEPS/miniz"
    -I"$ROOT/Bridge/cache/cereal/include"
    -I/usr/include/eigen3
    -I"$DEPS/nlohmann"
)

echo "==> compiling extract_config" >&2
"$CXX" "${CFLAGS[@]}" -o "$OUT" \
    "$ROOT/Bridge/tools/extract_config.cpp" "$ARCHIVE" \
    -lboost_thread -lpthread -lm -lgmp -lmpfr -latomic

echo "==> generating schema (pinned engine v2.4.2)" >&2
"$OUT" > "$SCHEMA.tmp"
# sanity: valid JSON, non-trivial size, contains the anchors the viewer needs
python3 - "$SCHEMA.tmp" <<'EOF'
import json, sys
schema = json.load(open(sys.argv[1]))
assert isinstance(schema, list) and len(schema) > 500, f"schema too small: {len(schema)}"
keys = {option["key"] for option in schema}
for anchor in ("layer_height", "printable_area", "nozzle_diameter"):
    assert anchor in keys, f"missing anchor option: {anchor}"
assert all("mode" in option and 0 <= option["mode"] <= 3 for option in schema), "mode field missing"
assert all("sidetext" in option and "multiline" in option for option in schema), "editor fields missing"
print(f"schema ok: {len(schema)} options")
EOF
mv "$SCHEMA.tmp" "$SCHEMA"
wc -c "$SCHEMA"

# Desktop settings layout (page -> optgroup -> options) from the pinned GUI
# source, validated against the freshly generated schema.
echo "==> extracting desktop settings layout" >&2
python3 "$ROOT/Bridge/tools/extract_settings_layout.py"
