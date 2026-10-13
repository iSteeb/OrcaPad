#!/usr/bin/env bash
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
#
# Host-header provenance stamp (COMPLIANCE.md W2): the exact host headers the
# engine archive was compiled against. build-core.sh writes this into
# Prebuilt/HOST-HEADERS.txt; make-source-archive.sh re-runs it and refuses to
# build a source archive on a host whose headers differ from the stamp — the
# archive must be Corresponding Source of the SHIPPED binary.
set -euo pipefail

echo "# Host headers the engine archive was compiled against (COMPLIANCE.md W2)."
echo "boost: $(grep -m1 'define BOOST_LIB_VERSION' /usr/include/boost/version.hpp)"
echo "cgal:  $(grep -m1 'define CGAL_VERSION ' /usr/include/CGAL/version.h)"
echo "eigen: $(grep -m1 'define EIGEN_WORLD_VERSION' /usr/include/eigen3/Eigen/src/Core/util/Macros.h)"
GMP_H="$(ls /usr/include/x86_64-linux-gnu/gmp.h /usr/include/gmp.h 2>/dev/null | head -1 || true)"
echo "gmp:   $(grep -m1 '__GNU_MP_VERSION' "$GMP_H")"
echo "mpfr:  $(grep -m1 'MPFR_VERSION_STRING' /usr/include/mpfr.h)"
echo "packages:"
dpkg-query -W -f='${binary:Package} ${Version}\n' \
    libboost-dev libeigen3-dev libcgal-dev libgmp-dev libmpfr-dev 2>/dev/null || true
