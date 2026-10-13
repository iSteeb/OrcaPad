// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

#pragma once
// OrcaPad adapter shim: EdgeGrid includes png.h unconditionally but uses it
// only under EDGE_GRID_DEBUG_OUTPUT (never defined). Stub satisfies include.
