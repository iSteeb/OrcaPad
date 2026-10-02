#pragma once
#include "blocked_range.h"
// OrcaPad adapter shim: serial execution (sequential tbb stand-in).
namespace tbb {
template <typename Range, typename Body>
void parallel_for(const Range &r, const Body &body) {
    body(r);
}
template <typename T, typename Body>
void parallel_for(T first, T last, const Body &body) {
    for (T i = first; i != last; ++i) body(i);
}
} // namespace tbb
