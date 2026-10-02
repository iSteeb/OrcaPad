#pragma once
#if defined(__cplusplus)
#ifdef __cplusplus
extern "C" {
#endif

/// Loads a generated binary STL (20mm cube) through OrcaSlicer's real code
/// path (admesh read + repair), returns a status string and mesh stats.
/// out_facets: triangle count (12 expected). out_volume: mm^3 (~8000).
/// scratch_dir: writable directory (the app's temp dir) — Swift owns paths;
/// the engine never hardcodes filesystem locations.
const char *orca_core_stl_probe(const char *scratch_dir, int *out_facets, float *out_volume);

#ifdef __cplusplus
}
#endif
#endif // __cplusplus
