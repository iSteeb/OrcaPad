#pragma once
// OrcaPad adapter shim: nowide process-env surface over POSIX.
#include <cstdlib>
namespace boost { namespace nowide {
inline int setenv(const char *k, const char *v, int overwrite) { return ::setenv(k, v, overwrite); }
inline int unsetenv(const char *k) { return ::unsetenv(k); }
inline int putenv(char *str) { return ::putenv(str); }
inline char *getenv(const char *k) { return ::getenv(k); }
}} // namespace boost::nowide
