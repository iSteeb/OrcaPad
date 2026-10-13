// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: sequential tbb stand-in — single "thread" (this one).
#include <optional>
namespace tbb {
template <typename T>
class enumerable_thread_specific {
public:
    template <typename... A> explicit enumerable_thread_specific(A &&...a) : v_(std::forward<A>(a)...) {}
    T &local() { return v_; }
    T &combine(T &acc) { return acc; }        // identity combine
    template <typename F> void combine_each(F &&) {}
private:
    T v_;
};
} // namespace tbb
