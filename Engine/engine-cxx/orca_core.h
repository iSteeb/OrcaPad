#pragma once
#if defined(__cplusplus)
#ifdef __cplusplus
extern "C" {
#endif

#include <stdint.h>

/// Non-owning view into engine-held mesh memory. Valid until orca_mesh_free.
/// Positions are in VIEWER space (y-up, bed-anchored): engine z-up was
/// converted, mesh recentred on origin, min-y dropped to 0.
typedef struct {
    const float    *positions;    // xyz triples, position_count entries
    int             position_count;
    const uint32_t *indices;      // 3 per triangle
    int             index_count;
    float           bbox_min[3];  // viewer space, mm
    float           bbox_max[3];
} orca_mesh_view;

typedef struct orca_mesh orca_mesh;

/// Load an STL through OrcaSlicer's real path (admesh read + repair).
/// On success: *out_mesh owns the mesh, *out_view aliases into it.
/// Returns a status string (ok message or loud error — never crashes).
const char *orca_stl_load(const char *path, orca_mesh **out_mesh, orca_mesh_view *out_view);

/// Frees a mesh handle (and any views into it).
void orca_mesh_free(orca_mesh *mesh);

/// Slices the ORIGINAL (engine-space) mesh at `levels` z-heights via
/// slice_mesh_ex — real OrcaSlicer slicing geometry. Reports the middle
/// layer's island count and total area.
const char *orca_slice_report(orca_mesh *mesh, int levels,
                              int *out_levels, int *out_mid_islands, double *out_mid_area_mm2);

#ifdef __cplusplus
}
#endif
#endif // __cplusplus

/// Progress callback: percent (0-100, engine-reported), message, user ctx.
typedef void (*orca_progress_fn)(int percent, const char *message, void *ctx);

/// Full slice: STL in → G-code file out, through OrcaSlicer's real pipeline
/// (Model → Print::apply → Print::process → export_gcode) with default
/// print settings. Blocking — call off the main thread.
/// out_time_estimate_s: total estimated print time (normal mode).
/// out_gcode_bytes: size of the written file.
const char *orca_slice_to_gcode(const char *stl_path, const char *gcode_path,
                                orca_progress_fn progress, void *ctx,
                                double *out_time_estimate_s, long *out_gcode_bytes);
