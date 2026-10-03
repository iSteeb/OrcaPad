#pragma once
// OrcaPad adapter shim (sequential tbb stand-in).
#include <unordered_map>
namespace tbb {
template <typename K, typename V, typename Hash = std::hash<K>, typename Eq = std::equal_to<K>>
using concurrent_unordered_map = std::unordered_map<K, V, Hash, Eq>;
} // namespace tbb
