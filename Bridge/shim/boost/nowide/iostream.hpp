// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: route nowide streams to std streams.
#include <iostream>
namespace boost { namespace nowide {
using std::cin;
using std::cout;
using std::cerr;
}} // namespace boost::nowide
