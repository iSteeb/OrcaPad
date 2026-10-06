#pragma once
// OrcaPad adapter shim (sequential tbb stand-in).
#include <thread>
namespace tbb {
namespace this_task_arena {
inline int max_concurrency() { return 1; }
inline bool is_current_thread_registered() { return true; }
} // namespace this_task_arena
} // namespace tbb
