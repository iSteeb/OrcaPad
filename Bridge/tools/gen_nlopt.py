#!/usr/bin/env python3
# SPDX-License-Identifier: AGPL-3.0-only
# Copyright (c) 2026 OrcaPad contributors
"""Generates NLopt 2.5.0's configure-time headers for the OrcaPad closure.

Mirrors NLopt's own CMake (src/api/CMakeLists.txt: nlopt.hpp = nlopt-in.hpp
with the algorithm/result enums from nlopt.h inserted at GEN_ENUMS_HERE;
nlopt_config.h = nlopt_config.h.in configured). The config values are the
ones NLopt's CMake detects with OrcaSlicer's deps options
(deps/NLopt/NLopt.cmake) — identical on Darwin/iOS and Linux LP64 for every
flag the sources read (qsort_r.c always uses NLopt's own implementation).
Verified 2026-10-13: semantically identical to CMake's output (whitespace
only differs: CMake's file(STRINGS) drops blank lines).
"""
import re
import sys

src, out = sys.argv[1], sys.argv[2]

lines = open(f"{src}/src/api/nlopt-in.hpp").read().split("\n")
header = open(f"{src}/src/api/nlopt.h").read().split("\n")
result = []
for line in lines:
    result.append(line)
    if "GEN_ENUMS_HERE" in line:
        result.append("  enum algorithm {")
        for h in header:
            if re.search(r"    NLOPT_[A-Z0-9_]+", h):
                result.append(h.replace("NLOPT_", ""))
                if "NLOPT_NUM_ALGORITHMS" in h:
                    result += ["  };", "  enum result {"]
                elif "NLOPT_MAXTIME_REACHED" in h:
                    result.append("  };")
open(f"{out}/nlopt.hpp", "w").write("\n".join(result))

config = {
    "BUGFIX_VERSION": "0", "MAJOR_VERSION": "2", "MINOR_VERSION": "5",
    "SIZEOF_UNSIGNED_INT": "4", "SIZEOF_UNSIGNED_LONG": "8",
    "THREADLOCAL": "__thread",
}
flags = ["HAVE_COPYSIGN", "HAVE_DLFCN_H", "HAVE_FPCLASSIFY", "HAVE_GETOPT_H",
         "HAVE_GETPID", "HAVE_GETTIMEOFDAY", "HAVE_INTTYPES_H", "HAVE_ISINF",
         "HAVE_ISNAN", "HAVE_MEMORY_H", "HAVE_QSORT_R", "HAVE_STDINT_H",
         "HAVE_STDLIB_H", "HAVE_STRINGS_H", "HAVE_STRING_H", "HAVE_SYS_STAT_H",
         "HAVE_SYS_TYPES_H", "HAVE_SYS_TIME_H", "HAVE_TIME", "HAVE_UINT32_T",
         "HAVE_UNISTD_H", "TIME_WITH_SYS_TIME"]
configured = []
for line in open(f"{src}/nlopt_config.h.in").read().split("\n"):
    m = re.match(r"#cmakedefine (\w+)", line)
    if m:
        configured.append(f"#define {m.group(1)}" if m.group(1) in flags
                          else f"/* #undef {m.group(1)} */")
        continue
    for key, value in config.items():
        line = line.replace(f"@NLOPT_{key}@", value).replace(f"@{key}@", value)
    if "@" in line:
        sys.exit(f"gen_nlopt: unconfigured placeholder: {line}")
    configured.append(line)
open(f"{out}/nlopt_config.h", "w").write("\n".join(configured))
