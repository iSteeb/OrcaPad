#pragma once
// OrcaPad adapter shim (sequential tbb stand-in). Report oneTBB-era version
// so upstream's filter_mode (new API) branch is selected.
#define TBB_VERSION_MAJOR 2021
#define TBB_VERSION_MINOR 0
#define TBB_VERSION_STRING "OrcaPad-sequential-shim"
#define TBB_RUNTIME_VERSION_MAJOR 2021
