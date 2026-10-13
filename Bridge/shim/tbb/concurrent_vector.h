// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: sequential tbb stand-in.
#include <vector>
namespace tbb {
template <typename T>
using concurrent_vector = std::vector<T>;
} // namespace tbb
