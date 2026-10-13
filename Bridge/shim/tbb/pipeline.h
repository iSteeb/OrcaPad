// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: SEQUENTIAL tbb pipeline stand-in (legacy include path).
// The generator (first filter, void->T) is called with a flow_control until
// it calls fc.stop(); each value flows through the remaining filters in
// chain order, one at a time. Correct, single-threaded. Swap for a real
// oneTBB iOS build when slicing perf matters.

#include <cstddef>
#include <functional>
#include <tuple>
#include <type_traits>
#include <utility>

#include "blocked_range.h"
#include "blocked_range2d.h"
#include "spin_mutex.h"
#include "task_arena.h"
#include "parallel_for.h"
#include "parallel_reduce.h"

namespace tbb {

class flow_control {
public:
    void stop() { stopped_ = true; }
    bool is_stopped() const { return stopped_; }
private:
    bool stopped_ = false;
};

enum class filter_mode { parallel, serial_in_order, serial_out_of_order };
enum class filter { parallel, serial_in_order, serial_out_of_order }; // legacy spelling

// Stage filter: In -> Out (In != void)
template <typename In, typename Out>
class filter_node {
public:
    using Fn = std::function<Out(In)>;
    filter_node(filter_mode, Fn f) : fn_(std::move(f)) {}
    filter_node(filter, Fn f) : fn_(std::move(f)) {}
    Out apply(In v) const { return fn_(std::move(v)); }
private:
    Fn fn_;
};

// Source filter: void -> Out (generator driven by flow_control)
template <typename Out>
class filter_node<void, Out> {
public:
    using Gen = std::function<Out(flow_control &)>;
    filter_node(filter_mode, Gen g) : gen_(std::move(g)) {}
    filter_node(filter, Gen g) : gen_(std::move(g)) {}
    Out generate(flow_control &fc) const { return gen_(fc); }
private:
    Gen gen_;
};

// Constructor-based dispatch: for In=void the node only has a Gen ctor
// (flow_control-driven); otherwise only Fn. Explicit <In, Out> template
// args flow through this single generic form.
template <typename In, typename Out, typename F>
filter_node<In, Out> make_filter(filter_mode m, F f) { return filter_node<In, Out>(m, std::move(f)); }
template <typename In, typename Out, typename F>
filter_node<In, Out> make_filter(filter m, F f) { return filter_node<In, Out>(m, std::move(f)); }

template <typename... Fs>
struct filter_chain {
    std::tuple<Fs...> stages;
};

template <typename A, typename B, typename C>
auto operator&(filter_node<A, B> l, filter_node<B, C> r) {
    return filter_chain<filter_node<A, B>, filter_node<B, C>>{std::make_tuple(std::move(l), std::move(r))};
}
template <typename... Fs, typename B, typename C>
auto operator&(filter_chain<Fs...> c, filter_node<B, C> r) {
    return filter_chain<Fs..., filter_node<B, C>>{std::tuple_cat(std::move(c.stages), std::make_tuple(std::move(r)))};
}

namespace detail {
// Types change after each stage (last is void) — constexpr recursion.
template <std::size_t I, typename Tuple, typename V>
void apply_from(const Tuple &t, V &&v) {
    if constexpr (I + 1 < std::tuple_size<Tuple>::value) {
        apply_from<I + 1>(t, std::get<I>(t).apply(std::forward<V>(v)));
    } else {
        std::get<I>(t).apply(std::forward<V>(v));
    }
}
} // namespace detail

template <typename... Fs>
void parallel_pipeline(std::size_t /*max_tokens*/, const filter_chain<Fs...> &chain) {
    auto &source = std::get<0>(chain.stages);
    flow_control fc;
    while (!fc.is_stopped()) {
        auto value = source.generate(fc);
        if (fc.is_stopped()) break;
        detail::apply_from<1>(chain.stages, std::move(value));
    }
}

} // namespace tbb
