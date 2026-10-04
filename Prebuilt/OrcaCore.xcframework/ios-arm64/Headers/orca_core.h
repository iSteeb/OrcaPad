#pragma once

#if defined(__cplusplus)
extern "C" {
#endif

#include <stdint.h>

/// Non-owning view into engine-held mesh memory. For orca_stl_load views the
/// memory is valid until orca_mesh_free; for plater views until the next
/// mutation of that object or orca_plater_free.
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
typedef struct orca_plater orca_plater;

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

/// Instance transform, ENGINE space (z-up, mm). `anchor_*` is the
/// instance-matrix-transformed position of the packed mesh's recentring
/// pivot — the point that sits at (anchor_x, anchor_z, -anchor_y) in the
/// viewer's y-up space. rotation_z is radians about engine z; scale is
/// uniform.
typedef struct {
    double offset_x, offset_y, offset_z;   // mm
    double rotation_z;                     // radians about engine z
    double scale;                          // uniform
    double anchor_x, anchor_y, anchor_z;   // mm, engine space
} orca_instance_transform;

/// Plater session: owns a Slic3r::Model (objects + instances). Object and
/// instance ids are INDICES into the current model; deletes renumber, so
/// Swift must resync (query counts) after every mutation.
const char *orca_plater_new(orca_plater **out_plater);
void        orca_plater_free(orca_plater *plater);

const char *orca_plater_add_stl(orca_plater *plater, const char *path,
                                int *out_object_id);
const char *orca_plater_object_count(orca_plater *plater, int *out_count);
const char *orca_plater_object_delete(orca_plater *plater, int object_id);

const char *orca_plater_instance_add(orca_plater *plater, int object_id,
                                     int *out_instance_id);
const char *orca_plater_instance_delete(orca_plater *plater, int object_id,
                                        int instance_id);
const char *orca_plater_instance_count(orca_plater *plater, int object_id,
                                       int *out_count);
const char *orca_plater_instance_set(orca_plater *plater, int object_id,
                                     int instance_id,
                                     const orca_instance_transform *t);
const char *orca_plater_instance_get(orca_plater *plater, int object_id,
                                     int instance_id,
                                     orca_instance_transform *out_t);

/// Packed viewer-space mesh for an object (bed-anchored, recentred, y-up).
const char *orca_plater_mesh_view(orca_plater *plater, int object_id,
                                  orca_mesh_view *out_view);

/// Drops every object so its lowest z sits on the bed (upstream semantic).
const char *orca_plater_ensure_on_bed(orca_plater *plater);

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

/// Same pipeline, but slices the plater's current Model (all objects, all
/// instances, transforms honored). Blocking — call off the main thread.
const char *orca_plater_slice_to_gcode(orca_plater *plater, const char *gcode_path,
                                       orca_progress_fn progress, void *ctx,
                                       double *out_time_estimate_s, long *out_gcode_bytes);

#if defined(__cplusplus)
}
#endif
