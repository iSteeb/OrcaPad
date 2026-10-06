#pragma once
// OrcaPad adapter shim (sequential tbb stand-in): tasks run immediately on
// the calling thread; wait/spawn are trivial.
#include <functional>
#include <utility>
namespace tbb {
class task_group {
public:
    template <typename F> void run(F &&f) { f(); }         // eager, serial
    template <typename F> void run(F &&f, void *) { f(); } // dummy-group overload
    void wait() {}
    bool is_canceling() const { return false; }
    void cancel() {}
};
} // namespace tbb
