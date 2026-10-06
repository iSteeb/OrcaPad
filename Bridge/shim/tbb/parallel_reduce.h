#pragma once
#include "blocked_range.h"
// OrcaPad adapter shim: serial reduce (sequential tbb stand-in).
namespace tbb {
template <typename Range, typename Value, typename Func, typename Join>
Value parallel_reduce(const Range &r, Value init, const Func &f, const Join &j) {
    return j(init, f(r));
}
} // namespace tbb
