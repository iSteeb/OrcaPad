#pragma once
// OrcaPad adapter shim: sequential tbb stand-in.
#include <unordered_set>
namespace tbb {
template <typename T, typename Hash = std::hash<T>, typename Eq = std::equal_to<T>>
using concurrent_unordered_set = std::unordered_set<T, Hash, Eq>;
} // namespace tbb
