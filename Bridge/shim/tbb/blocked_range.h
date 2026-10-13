// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: SEQUENTIAL tbb stand-ins. Correct but single-
// threaded; swap for a real oneTBB iOS build when slicing perf matters.
namespace tbb {
template <typename T>
class blocked_range {
public:
    blocked_range(T b, T e, std::size_t g = 1) : m_b(b), m_e(e), m_g(g) {}
    T begin() const { return m_b; }
    T end() const { return m_e; }
    std::size_t size() const { return static_cast<std::size_t>(m_e - m_b); }
    std::size_t grainsize() const { return m_g; }
    bool empty() const { return m_b == m_e; }
    blocked_range(blocked_range &r, float) : m_b(r.m_b), m_e(r.m_e), m_g(r.m_g) {}
private:
    T m_b, m_e; std::size_t m_g;
};
} // namespace tbb
