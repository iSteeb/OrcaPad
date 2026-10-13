// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: narrow-char stdio pass-through (no libnowide).
// Env functions (setenv etc.) live in cstdlib.hpp — do not duplicate here.
#include <cstdio>
namespace boost { namespace nowide {
inline FILE *fopen(const char *path, const char *mode) { return ::fopen(path, mode); }
inline int fclose(FILE *f) { return ::fclose(f); }
inline FILE *freopen(const char *path, const char *mode, FILE *f) { return ::freopen(path, mode, f); }
inline int remove(const char *path) { return ::remove(path); }
inline int rename(const char *from, const char *to) { return ::rename(from, to); }
}} // namespace boost::nowide
