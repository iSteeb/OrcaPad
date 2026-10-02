#pragma once
#if defined(__cplusplus)

#include <string>
#include <vector>

/// Returns a human-readable version banner (proves the lib loaded).
const char *cxx_probe_version();

/// Allocates and sums a std::vector (proves libc++ runtime works when
/// called from Swift on-device).
int cxx_probe_stl_test(int n);

#endif // __cplusplus
