// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim (sequential tbb stand-in).
#include <mutex>
namespace tbb {
class spin_mutex {
public:
    class scoped_lock {
    public:
        explicit scoped_lock(spin_mutex &m) : m_l(m.m_m) {}
        void release() { m_l.unlock(); }
    private:
        std::unique_lock<std::mutex> m_l;
    };
    void lock() { m_m.lock(); }
    void unlock() { m_m.unlock(); }
private:
    std::mutex m_m;
};
} // namespace tbb
