#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
#
# License inventory of the COMPILED closure (COMPLIANCE.md W4).
#
#   license-inventory.sh           regenerate THIRD_PARTY.md (repo root and
#                                  the bundled About-screen copy) and the
#                                  license texts under
#                                  Sources/OrcaPad/Resources/Licenses/
#   license-inventory.sh --check   regenerate into a temp dir and diff
#                                  against the committed files; exit 1 on
#                                  drift (CI gate, same contract as
#                                  parity-check.py --check)
#
# The translation-unit closure is derived from Bridge/engine-sources.sh (the
# single source of truth both builds share). Header-only components that
# enter the binary through -I paths are inventoried in HEADER_ONLY below —
# keep that list in sync with the -I set in Bridge/build-core.sh.
# Cache-fetched dependencies are materialized by engine_fetch_deps(); the
# pins (tags/URLs) live in engine-sources.sh, so the archive of a release
# always contains exactly what this inventory saw.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

CHECK=0
[ "${1:-}" = "--check" ] && CHECK=1

source Bridge/engine-sources.sh
engine_fetch_deps >/dev/null

SRC="$ROOT/upstream/orcaslicer/src"
DEPS="$ROOT/upstream/orcaslicer/deps_src"

# ---------------------------------------------------------------------------
# Component classification: path prefix -> "name|license-id|role"
# (role: code = compiled TUs, headers = compiled in through -I)
# License evidence paths are relative to the repo root and MUST exist.
# ---------------------------------------------------------------------------
classify() {
    local p="$1"
    case "$p" in
        "$SRC"/*)
            case "$(basename "$p")" in
                # clipper 6.x vendored inside the engine tree (BSL header)
                clipper.cpp) echo "Clipper 1|BSL-1.0|code" ;;
                *) echo "OrcaSlicer engine|AGPL-3.0|code" ;;
            esac ;;
        "$DEPS/admesh"/*)        echo "ADMesh|GPL-2.0-or-later|code" ;;
        "$DEPS/qhull"/*)         echo "Qhull|Qhull (permissive)|code" ;;
        "$DEPS/glu-libtess"/*)   echo "glu-libtess|SGI-FreeB-2.0|code" ;;
        "$DEPS/semver"/*)        echo "semver.c|MIT|code" ;;
        "$DEPS/clipper"/*)       echo "Clipper 1|BSL-1.0|code" ;;
        "$DEPS/clipper2"/*)      echo "Clipper2|BSL-1.0|code" ;;
        "$DEPS/expat"/*)         echo "Expat|MIT|code" ;;
        "$DEPS/miniz"/*)         echo "miniz|MIT|code" ;;
        "$DEPS/qoi"/*)           echo "QOI|MIT|code" ;;
        "$DEPS/nanosvg"/*)       echo "NanoSVG|Zlib|code" ;;
        "$DEPS/libnest2d"/*)     echo "libnest2d|LGPL-3.0|code" ;;
        "$ROOT/Bridge/cache/Orca-deps-libnoise"/*) echo "libnoise|LGPL-2.1-or-later|code" ;;
        "$ROOT/Bridge/cache/boost-filesystem-1.90"/*) echo "Boost|BSL-1.0|code" ;;
        "$ROOT/Bridge/cache/boost-thread-1.90"/*)    echo "Boost|BSL-1.0|code" ;;
        "$ROOT/Bridge/cache/nlopt"/*)    echo "NLopt 2.5.0|LGPL-2.1-or-later|code" ;;
        "$ROOT/Bridge/cache/nlopt-gen"/*) echo "NLopt 2.5.0|LGPL-2.1-or-later|code" ;;
        "$ROOT/Bridge/engine-cxx"/*)     echo "OrcaPad Bridge|AGPL-3.0-only|code" ;;
        *) echo "UNMAPPED:$p"; return 1 ;;
    esac
}

# Header-only components that enter the binary through #include. Kept in
# sync with the -I set of build-core.sh AND the host system headers it
# symlinks into gen/ (build-core.sh: /usr/include/{boost,eigen3,CGAL},
# gmp.h, mpfr.h — the release source archive vendors these, see
# make-source-archive.sh).
HEADER_ONLY=(
    "nlohmann/json|MIT|headers|upstream/orcaslicer/deps_src/nlohmann/json.hpp"
    "libigl|MPL-2.0|headers|upstream/orcaslicer/deps_src/libigl/README.md"
    "NanoSVG|Zlib|headers|upstream/orcaslicer/deps_src/nanosvg/nanosvg.h (compiled via Bridge/engine-cxx/nanosvg_impl.cpp)"
    "Eigen 3 (host headers)|MPL-2.0|headers|/usr/include/eigen3 (vendored into the release source archive)"
    "Boost 1.90 headers (host)|BSL-1.0|headers|/usr/include/boost (tag-matched to Bridge/cache/boost-*-1.90 sources)"
    "CGAL 6.1.1 headers (host)|GPL-3.0-or-later / LGPL-3.0-or-later|headers|/usr/include/CGAL (per-package; core geometry is GPL-3+)"
    "GMP 6 headers (host)|GPL-2.0-or-later or LGPL-3.0-or-later (dual)|headers|/usr/include/x86_64-linux-gnu/gmp.h (LGPL-3+ branch relied on)"
    "MPFR 4.2 headers (host)|LGPL-3.0-or-later|headers|/usr/include/mpfr.h"
    "cereal 1.3.0|BSD-3-Clause|headers|Bridge/cache/cereal/LICENSE"
)

# ---------------------------------------------------------------------------
# Evidence table for compiled components (name|license|role|evidence).
# ---------------------------------------------------------------------------
EVIDENCE=(
    "OrcaSlicer engine|AGPL-3.0|code|upstream/orcaslicer/LICENSE.txt"
    "OrcaPad Bridge|AGPL-3.0-only|code|LICENSE (repo root; Bridge adapters and platform shims are OrcaPad-authored — no upstream TBB/OpenSSL/OCCT code is distributed)"
    "ADMesh|GPL-2.0-or-later|code|upstream/orcaslicer/deps_src/admesh/stl.h (license headers)"
    "Qhull|Qhull (permissive)|code|upstream/orcaslicer/deps_src/qhull/COPYING.txt"
    "glu-libtess|SGI-FreeB-2.0|code|upstream/orcaslicer/deps_src/glu-libtess/src/dict.c (license headers)"
    "semver.c|MIT|code|upstream/orcaslicer/deps_src/semver/semver.c (license header)"
    "Clipper 1|BSL-1.0|code|upstream/orcaslicer/deps_src/clipper/clipper.cpp + src/libslic3r/clipper.cpp (license headers)"
    "Clipper2|BSL-1.0|code|upstream/orcaslicer/deps_src/clipper2 (license headers)"
    "Expat|MIT|code|upstream/orcaslicer/deps_src/expat/COPYING"
    "miniz|MIT|code|upstream/orcaslicer/deps_src/miniz/LICENSE"
    "QOI|MIT|code|upstream/orcaslicer/deps_src/qoi/qoi.h (license header)"
    "libnoise|LGPL-2.1-or-later|code|Bridge/cache/Orca-deps-libnoise/src/noise.h (license headers; fetched from SoftFever/Orca-deps)"
    "Boost|BSL-1.0|code|Bridge/cache/boost-{filesystem,thread}-1.90 (boostorg tags boost-1.90.0, license headers)"
    "NLopt 2.5.0|LGPL-2.1-or-later|code|Bridge/cache/nlopt/COPYING (conjunction of permissive terms; LGPL-2.1+ is the most restrictive)"
    "libnest2d|LGPL-3.0|code|upstream/orcaslicer/deps_src/libnest2d/LICENSE.txt"
)

# ---------------------------------------------------------------------------
# License full texts bundled into the app (About & Licenses screen) and
# named per component in THIRD_PARTY.md.
# ---------------------------------------------------------------------------
LICDIR_TEXTS=(
    "AGPL-3.0.txt|LICENSE"
    "GPL-2.0.txt|/usr/share/common-licenses/GPL-2"
    "LGPL-2.1.txt|/usr/share/common-licenses/LGPL-2.1"
    "LGPL-3.0.txt|upstream/orcaslicer/deps_src/libnest2d/LICENSE.txt"
    "MPL-2.0.txt|/usr/share/common-licenses/MPL-2.0"
    "BSD-3-Clause.txt|/usr/share/common-licenses/BSD"
    "MIT-Expat.txt|upstream/orcaslicer/deps_src/expat/COPYING"
    "Qhull.txt|upstream/orcaslicer/deps_src/qhull/COPYING.txt"
)
# Short canonical texts embedded verbatim (not present as standalone files
# anywhere in the closure).
BSL_TEXT='Boost Software License - Version 1.0 - August 17th, 2003

Permission is hereby granted, free of charge, to any person or organization
obtaining a copy of the software and accompanying documentation covered by
this license (the "Software") to use, reproduce, display, distribute,
execute, and transmit the Software, and to prepare derivative works of the
Software, and to permit third-parties to whom the Software is furnished to
do so, all subject to the following:

The copyright notices in the Software and this entire statement, including
the above license grant, this restriction and the following disclaimer,
must be included in all copies of the Software, in whole or in part, and
all derivative works of the Software, unless such copies or derivative
works are solely in the form of machine-executable object code generated by
a source language processor.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE, TITLE AND NON-INFRINGEMENT. IN NO EVENT
SHALL THE COPYRIGHT HOLDERS OR ANYONE DISTRIBUTING THE SOFTWARE BE LIABLE
FOR ANY DAMAGES OR OTHER LIABILITY, WHETHER IN CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.'
SGI_TEXT='SGI FREE SOFTWARE LICENSE B
(Version 2.0, Sept. 18, 2008)

Copyright (C) 1991-2008 Silicon Graphics, Inc. All Rights Reserved.

Permission is hereby granted, free of charge, to any person obtaining a
copy of this software and associated documentation files (the "Software"),
to deal in the Software without restriction, including without limitation
the rights to use, copy, modify, merge, publish, distribute, sublicense,
and/or sell copies of the Software, and to permit persons to whom the
Software is furnished to do so, subject to the following conditions:

The above copyright notice including the dates of first and last
publication (or updates) and this permission notice shall be included in
all copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE IMPLIED WARRANTIES OF
MERCHANTABILITY, FITNESS FOR A PARTICULAR PURPOSE AND NON-INFRINGEMENT, IN
NO EVENT SHALL SILICON GRAPHICS, INC. BE LIABLE FOR ANY CLAIM, DAMAGES OR
OTHER LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE,
ARISING FROM, OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER
DEALINGS IN THE SOFTWARE.'

# ---------------------------------------------------------------------------
# Generate.
# ---------------------------------------------------------------------------
if [ "$CHECK" = 1 ]; then
    OUT="$(mktemp -d)"
    trap 'rm -rf "$OUT"' EXIT
    RES_LIC="$OUT/licenses"; RES_ROOT="$OUT/root"; mkdir -p "$RES_LIC" "$RES_ROOT"
else
    RES_LIC="$ROOT/Sources/OrcaPad/Resources/Licenses/licenses"
    RES_ROOT="$ROOT"
    mkdir -p "$RES_LIC"
fi

# License texts.
mkdir -p "$RES_LIC"
for entry in "${LICDIR_TEXTS[@]}"; do
    dst="$RES_LIC/${entry%%|*}"; src="${entry#*|}"
    case "$src" in
        /*) [ -f "$src" ] || { echo "FATAL: missing license source $src" >&2; exit 1; }
            cp "$src" "$dst" ;;
        *)   [ -f "$ROOT/$src" ] || { echo "FATAL: missing license source $src" >&2; exit 1; }
            cp "$ROOT/$src" "$dst" ;;
    esac
done
printf '%s\n' "$BSL_TEXT" > "$RES_LIC/BSL-1.0.txt"
printf '%s\n' "$SGI_TEXT" > "$RES_LIC/SGI-FreeB-2.0.txt"
# The bundled AGPL text must be a byte-identical copy of the repo LICENSE.
AGPL_DST="$([ $CHECK = 1 ] && echo "$OUT" || echo "$ROOT")/Sources/OrcaPad/Resources/Licenses"
mkdir -p "$AGPL_DST"
cp "$ROOT/LICENSE" "$AGPL_DST/AGPL-3.0.txt"

# Classify the TU closure.
declare -A COUNT
UNMAPPED=0
while IFS=$'\t' read -r _kind path _flags; do
    [ -n "$path" ] || continue
    if ! row="$(classify "$path")"; then
        echo "FATAL: unmapped TU: $path" >&2; UNMAPPED=1; continue
    fi
    name="${row%%|*}"
    COUNT[$name]=$(( ${COUNT[$name]:-0} + 1 ))
done < <(engine_sources)
[ "$UNMAPPED" = 0 ] || exit 1
[ "${#COUNT[@]}" -gt 0 ] || { echo "FATAL: empty closure" >&2; exit 1; }

# Header-only components (0 compiled TUs of their own).
for entry in "${HEADER_ONLY[@]}"; do
    IFS='|' read -r name _lic _r _ev <<<"$entry"
    COUNT[$name]=0
done

# THIRD_PARTY.md.
{
    echo "# Third-party components in the OrcaPad binary"
    echo
    echo "Generated by \`Bridge/tools/license-inventory.sh\` from the compiled"
    echo "closure in \`Bridge/engine-sources.sh\` — do not edit by hand;"
    echo "regenerate after any closure or dependency change (CI gates this)."
    echo
    total=0; for n in "${!COUNT[@]}"; do total=$(( total + ${COUNT[$n]} )); done
    echo "Closure: **$total translation units** plus header-only includes."
    echo
    echo "| Component | License | Role | Files | Evidence |"
    echo "|---|---|---|---|---|"
    for row in "${EVIDENCE[@]}"; do
        IFS='|' read -r name lic role ev <<<"$row"
        printf '| %s | %s | %s | %s | %s |\n' "$name" "$lic" "$role" "${COUNT[$name]:-0}" "$ev"
    done
    for entry in "${HEADER_ONLY[@]}"; do
        IFS='|' read -r name lic role ev <<<"$entry"
        printf '| %s | %s | %s | — | %s |\n' "$name" "$lic" "$role" "$ev"
    done
    echo
    echo "Full license texts are bundled with the app (About & Licenses screen)"
    echo "and in \`Sources/OrcaPad/Resources/Licenses/licenses/\`."
    echo
    echo "## Notes"
    echo
    echo "- **AGPL-3.0**: the whole OrcaPad work, including OrcaSlicer-derived"
    echo "  code and the OrcaPad Bridge, is licensed under the GNU AGPL v3.0"
    echo "  ([LICENSE](LICENSE))."
    echo "- **ADMesh (GPL-2.0-or-later), CGAL core (GPL-3.0-or-later)**:"
    echo "  one-way compatible — conveyed as part of the AGPL-3.0 combined"
    echo "  work, exactly as upstream OrcaSlicer distributes them."
    echo "- **libnoise / NLopt 2.5.0 (LGPL-2.1+) and libnest2d (LGPL-3.0)**:"
    echo "  statically linked. Compliance mirrors upstream OrcaSlicer's own"
    echo "  distribution model: the complete combined-work source — including"
    echo "  these libraries and the full build system — is conveyed at no charge"
    echo "  for every release, enabling any recipient to rebuild and relink"
    echo "  (LGPLv3 §4(a); LGPLv2.1 §6's relinking purpose served by the"
    echo "  full-source rebuild path; see COMPLIANCE.md §W4)."
    echo "- **OrcaPad Bridge**: adapter and shim sources are OrcaPad-authored"
    echo "  (AGPL); no upstream TBB, OpenSSL, or OCCT code is distributed."
    echo "- **Host headers** (boost 1.90, Eigen 3, CGAL 6, GMP, MPFR): the"
    echo "  engine compiles against system headers symlinked into the build;"
    echo "  their sources are vendored into the release source archive under"
    echo "  \`host-headers/\` with a version manifest, so the archive is"
    echo "  self-contained Corresponding Source."
    echo "- **Header-only** rows enter the binary through \`#include\`; their"
    echo "  license evidence files ship in the full source archive."
    echo "- The complete corresponding source of every release is attached to"
    echo "  its GitHub Release as \`OrcaPad-<version>-full-source.tar.gz\`."
} > "$RES_ROOT/THIRD_PARTY.md"

# Bundled About-screen copy (both modes, so --check can diff it).
BUNDLED="$([ $CHECK = 1 ] && echo "$OUT" || echo "$ROOT")/Sources/OrcaPad/Resources/Licenses/THIRD_PARTY.md"
cp "$RES_ROOT/THIRD_PARTY.md" "$BUNDLED"

if [ "$CHECK" = 1 ]; then
    fail=0
    for f in THIRD_PARTY.md Sources/OrcaPad/Resources/Licenses/THIRD_PARTY.md \
             Sources/OrcaPad/Resources/Licenses/AGPL-3.0.txt; do
        # THIRD_PARTY.md is generated under $OUT/root; the bundled copies
        # under $OUT at their repo-relative paths.
        gen_path="$OUT/$( [ "$f" = THIRD_PARTY.md ] && echo root || true )/$f"
        if ! diff -u "$ROOT/$f" "$gen_path" >/dev/null 2>&1; then
            diff -u "$ROOT/$f" "$gen_path" | head -40 || true
            echo "::error::$f is stale — run Bridge/tools/license-inventory.sh and commit" >&2
            fail=1
        fi
    done
    if ! diff -r "$ROOT/Sources/OrcaPad/Resources/Licenses/licenses" "$RES_LIC" >/dev/null 2>&1; then
        echo "::error::bundled license texts are stale — rerun license-inventory.sh" >&2
        fail=1
    fi
    if [ "$fail" = 1 ]; then echo "RESULT: FAIL"; exit 1; fi
    echo "RESULT: PASS"
else
    echo "wrote THIRD_PARTY.md (+ bundled copy) and $(ls "$RES_LIC" | wc -l | tr -d ' ') license texts"
fi
