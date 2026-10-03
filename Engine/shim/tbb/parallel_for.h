#pragma once
#include "task_arena.h"
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

// Partitioners: no-ops under the sequential shim.
namespace tbb {
class simple_partitioner {};
class auto_partitioner {};
class static_partitioner {};
class affinity_partitioner {};
} // namespace tbb

// Partitioner-accepting overloads (partitioners are no-ops here).
namespace tbb {
template <typename Range, typename Body, typename P>
void parallel_for(const Range &r, const Body &body, P) { body(r); }
template <typename T, typename Body, typename P>
void parallel_for(T first, T last, const Body &body, P) {
    for (T i = first; i != last; ++i) body(i);
}
} // namespace tbb
