#pragma once
// OrcaPad adapter shim: sequential tbb stand-in.
#include <vector>
namespace tbb {
template <typename T>
using concurrent_vector = std::vector<T>;
} // namespace tbb
