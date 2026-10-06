#pragma once
// OrcaPad adapter shim: tbb::scalable_allocator backed by malloc/free
// (tbbmalloc is a perf optimization, not semantics). Avoids building oneTBB
// for the geometry-core subset. Upstream sources untouched.
#include <cstddef>
#include <cstdlib>
#include <new>

namespace tbb {

template <typename T>
class scalable_allocator {
public:
    using value_type = T;
    using propagate_on_container_move_assignment = std::true_type;
    using is_always_equal = std::true_type;

    scalable_allocator() = default;
    template <typename U> scalable_allocator(const scalable_allocator<U> &) {}

    template <typename U> struct rebind { using other = scalable_allocator<U>; };

    T *allocate(std::size_t n) {
        if (n == 0) return nullptr;
        if (n > static_cast<std::size_t>(-1) / sizeof(T)) throw std::bad_alloc();
        return static_cast<T *>(std::malloc(n * sizeof(T)));
    }
    void deallocate(T *p, std::size_t) { std::free(p); }
};

template <typename T, typename U>
bool operator==(const scalable_allocator<T> &, const scalable_allocator<U> &) { return true; }
template <typename T, typename U>
bool operator!=(const scalable_allocator<T> &, const scalable_allocator<U> &) { return false; }

} // namespace tbb
