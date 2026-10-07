// Implementation unit for the vendored header-only nanosvg parser.
// Upstream instantiates it inside the GUI (src/slic3r/GUI/BitmapCache.cpp),
// which OrcaPad does not build; libslic3r's NSVGUtils/Emboss/bbs_3mf only
// see the declarations. Same header, same version, no code changes.
#include <cstdio>
#include <cstring>
#include <cmath>
#define NANOSVG_IMPLEMENTATION
#include "nanosvg/nanosvg.h"
