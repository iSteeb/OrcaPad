#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
#
# Complete-corresponding-source archive (COMPLIANCE.md W2).
#
#   make-source-archive.sh <output.tar.gz> [--allow-untagged]
#
# Builds a self-contained source archive of the CURRENT checkout:
#   - every git-tracked file at the current commit
#   - the pinned upstream submodule's full tree (GitHub tag tarballs
#     omit submodule contents — that omission is exactly why this exists)
#   - the build-only cache dependencies (engine_fetch_deps pins)
#   - the host headers the engine compiles against (boost / Eigen / CGAL /
#     gmp / mpfr, symlinked into gen/ by build-core.sh) + a version manifest
#   - ARCHIVE-MANIFEST.txt recording every pin
#
# Fails unless HEAD is exactly on a `release*` tag (or --allow-untagged),
# because an untraceable archive is not Corresponding Source.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT"

OUT="${1:?usage: make-source-archive.sh <output.tar.gz> [--allow-untagged]}"
shift || true
ALLOW_UNTAGGED=0
[ "${1:-}" = "--allow-untagged" ] && ALLOW_UNTAGGED=1
OUT="$(cd "$(dirname "$OUT")" && pwd)/$(basename "$OUT")"

STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

# --- 1. traceability: HEAD must be a release tag -------------------------
TAG="$(git describe --exact-match --tags HEAD 2>/dev/null || true)"
if [ -z "$TAG" ]; then
    if [ "$ALLOW_UNTAGGED" = 1 ]; then
        TAG="untagged-$(git rev-parse --short HEAD)"
        echo "==> WARNING: archiving untagged commit as $TAG" >&2
    else
        echo "::error::HEAD is not on a tag — tag a release first (COMPLIANCE.md W2)" >&2
        exit 1
    fi
fi

# --- 2. tracked files + submodule + cache deps ----------------------------
source Bridge/engine-sources.sh
engine_fetch_deps >/dev/null
git submodule update --init --quiet

git ls-files -z | tar --null -T - -cf - | tar -xf - -C "$STAGE"
mkdir -p "$STAGE/upstream/orcaslicer"
tar -C upstream/orcaslicer --exclude-vcs -cf - . | tar -xf - -C "$STAGE/upstream/orcaslicer"
mkdir -p "$STAGE/Bridge/cache"
for dep in Orca-deps-libnoise boost-filesystem-1.90 boost-thread-1.90 cereal nlopt nlopt-gen; do
    [ -d "Bridge/cache/$dep" ] || continue
    mkdir -p "$STAGE/Bridge/cache/$dep"
    tar -C "Bridge/cache/$dep" --exclude-vcs -cf - . | tar -xf - -C "$STAGE/Bridge/cache/$dep"
done

# --- 3. host headers the engine compiles against --------------------------
# Mirrors the gen/ symlinks in build-core.sh (and its "NEVER -I/usr/include"
# rule: these are the ONLY host files that reach the binary).
HOST="$STAGE/host-headers"
mkdir -p "$HOST"
for hdr in /usr/include/boost /usr/include/eigen3 /usr/include/CGAL \
           /usr/include/mpfr.h; do
    [ -e "$hdr" ] || { echo "::error::expected host headers missing: $hdr" >&2; exit 1; }
    cp -a "$hdr" "$HOST/"
done
# gmp.h lives in the multiarch include dir on Debian/Ubuntu
GMP_H="$( { ls /usr/include/x86_64-linux-gnu/gmp.h /usr/include/gmp.h 2>/dev/null || true; } | head -1)"
[ -n "$GMP_H" ] || { echo "::error::gmp.h not found on the host" >&2; exit 1; }
cp -a "$GMP_H" "$HOST/gmp.h"

# --- 3b. provenance: host headers must match the engine archive's stamp --
STAMP="$ROOT/Prebuilt/HOST-HEADERS.txt"
[ -f "$STAMP" ] || {
    echo "::error::Prebuilt/HOST-HEADERS.txt is missing — rebuild the engine archive (Bridge/build-core.sh) so its host-header provenance is recorded" >&2
    exit 1
}
if ! diff -u <("$ROOT/Bridge/tools/host-header-stamp.sh" | head -6) <(head -6 "$STAMP"); then
    echo "::error::this host's headers differ from Prebuilt/HOST-HEADERS.txt — the archive would not be Corresponding Source of the shipped binary. Rebuild the engine archive on the provenance host (or update the pin deliberately and rebuild)" >&2
    exit 1
fi
# (only the version defines are compared; the package-revision lines in the
# stamp are informational and may drift between distro point releases)

# --- 4. manifest ------------------------------------------------------------
UP_SHA="$(git -C upstream/orcaslicer rev-parse HEAD)"
UP_DESC="$(git -C upstream/orcaslicer describe --tags --always 2>/dev/null || echo "$UP_SHA")"
{
    echo "OrcaPad complete corresponding source"
    echo "Generated: $(date -u +%Y-%m-%dT%H:%M:%SZ)"
    echo "Superproject: $TAG $(git rev-parse HEAD)"
    echo "Upstream pin: upstream/orcaslicer @ $UP_SHA ($UP_DESC)"
    echo "License: GNU AGPL-3.0 (LICENSE); see THIRD_PARTY.md for components."
    echo "Build instructions: BUILDING.md"
    echo
    echo "Host headers (vendored under host-headers/, versions):"
    grep -m1 "BOOST_LIB_VERSION" "$HOST/boost/version.hpp" || true
    grep -m1 "define CGAL_VERSION " "$HOST/CGAL/version.h" || true
    grep -m1 "define EIGEN_WORLD_VERSION\|define EIGEN_MAJOR_VERSION" "$HOST/eigen3/Eigen/src/Core/util/Macros.h" || true
    grep -m1 "__GNU_MP_VERSION" "$HOST/gmp.h" || true
    grep -m1 "MPFR_VERSION_STRING" "$HOST/mpfr.h" || true
    echo
    echo "Owning packages (as recorded at archive time):"
    dpkg-query -W -f='${binary:Package} ${Version}\n' \
        libboost-dev libeigen3-dev libcgal-dev libgmp-dev libmpfr-dev 2>/dev/null || true
} > "$STAGE/ARCHIVE-MANIFEST.txt"

# --- 5. tar + assertions ------------------------------------------------------
tar -C "$STAGE" --sort=name --owner=0 --group=0 --numeric-owner \
    -czf "$OUT" .
LISTING="$(tar -tzf "$OUT")"
for probe in \
    Bridge/engine-sources.sh \
    upstream/orcaslicer/src/libslic3r/libslic3r.cpp \
    upstream/orcaslicer/LICENSE.txt \
    Bridge/cache/nlopt/src/api/general.c \
    host-headers/boost/version.hpp \
    ARCHIVE-MANIFEST.txt; do
    # grep -F: fixed string, full read (a -q early exit would SIGPIPE tar
    # under pipefail and fail the pipeline on success).
    grep -Fx "./$probe" <<<"$LISTING" >/dev/null || {
        echo "::error::archive is missing $probe — not complete source" >&2
        exit 1
    }
done
echo "==> $OUT ($(du -h "$OUT" | cut -f1)) — $TAG, complete corresponding source"
