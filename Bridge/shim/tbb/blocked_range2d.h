// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim (sequential tbb stand-in).
#include "blocked_range.h"
namespace tbb {
template <typename RowValue, typename ColValue = RowValue>
class blocked_range2d {
public:
    // 6-arg form: rows (begin,end,grain), cols (begin,end,grain)
    blocked_range2d(RowValue rb, RowValue re, std::size_t rg,
                    ColValue cb, ColValue ce, std::size_t cg)
        : rows_(rb, re, rg), cols_(cb, ce, cg) {}
    // 4-arg form: rows (begin,end), cols (begin,end), unit grains
    blocked_range2d(RowValue rb, RowValue re, ColValue cb, ColValue ce)
        : rows_(rb, re, 1), cols_(cb, ce, 1) {}
    const blocked_range<RowValue> &rows() const { return rows_; }
    const blocked_range<ColValue> &cols() const { return cols_; }
    bool empty() const { return rows_.empty() || cols_.empty(); }
private:
    blocked_range<RowValue> rows_;
    blocked_range<ColValue> cols_;
};
} // namespace tbb
