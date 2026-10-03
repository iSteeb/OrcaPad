#pragma once
// OrcaPad adapter shim: narrow-char fopen/fclose pass-through (no libnowide).
#include <cstdio>
namespace boost { namespace nowide {
inline FILE *fopen(const char *path, const char *mode) { return ::fopen(path, mode); }
inline int fclose(FILE *f) { return ::fclose(f); }
}} // namespace boost::nowide
namespace boost { namespace nowide {
inline FILE *freopen(const char *path, const char *mode, FILE *f) { return ::freopen(path, mode, f); }
}} // namespace boost::nowide

namespace boost { namespace nowide {
inline int remove(const char *path) { return ::remove(path); }
}} // namespace boost::nowide
#include <cstdlib>
namespace boost { namespace nowide {
inline int setenv(const char *k, const char *v, int overwrite) { return ::setenv(k, v, overwrite); }
}}
