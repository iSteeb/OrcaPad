// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: nowide streams over std streams.
#include <fstream>
namespace boost { namespace nowide {
using std::fstream;
using std::ifstream;
using std::ofstream;
}} // namespace boost::nowide
