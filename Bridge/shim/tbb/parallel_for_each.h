#pragma once
// OrcaPad adapter shim (sequential tbb stand-in).
#include <iterator>
namespace tbb {
template <typename It, typename F>
void parallel_for_each(It first, It last, F &&f) {
    for (; first != last; ++first) f(*first);
}
template <typename C, typename F>
void parallel_for_each(C &c, F &&f) {
    parallel_for_each(std::begin(c), std::end(c), std::forward<F>(f));
}
} // namespace tbb
