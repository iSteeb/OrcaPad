#pragma once

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/// Version of the C ABI contract in this header. Callers may verify it at
/// runtime with orca_bridge_abi_version().
#define ORCA_BRIDGE_ABI_VERSION ((uint32_t)1)

typedef int32_t orca_status_code;
#define ORCA_STATUS_OK                     ((orca_status_code)0)
#define ORCA_STATUS_INVALID_ARGUMENT       ((orca_status_code)1)
#define ORCA_STATUS_INVALID_HANDLE         ((orca_status_code)2)
#define ORCA_STATUS_NOT_FOUND              ((orca_status_code)3)
#define ORCA_STATUS_UNSUPPORTED_CAPABILITY ((orca_status_code)4)
#define ORCA_STATUS_CANCELLED              ((orca_status_code)5)
#define ORCA_STATUS_IO_FAILURE             ((orca_status_code)6)
#define ORCA_STATUS_INVALID_MODEL          ((orca_status_code)7)
#define ORCA_STATUS_INVALID_CONFIGURATION  ((orca_status_code)8)
#define ORCA_STATUS_ENGINE_FAILURE         ((orca_status_code)9)
#define ORCA_STATUS_OUT_OF_MEMORY          ((orca_status_code)10)
#define ORCA_STATUS_INTERNAL_INVARIANT      ((orca_status_code)11)

/// Bridge-allocated UTF-8. The caller owns `data` and must call
/// orca_owned_string_dispose(), including for an empty string.
typedef struct {
    char    *data;
    uint64_t length; // bytes, excluding the trailing NUL
} orca_owned_string;

/// Every fallible Bridge call returns this typed result. `diagnostic` is empty
/// on success and caller-owned on failure. Messages are diagnostic only;
/// callers must branch exclusively on `code`.
typedef struct {
    orca_status_code code;
    orca_owned_string diagnostic;
} orca_result;

uint32_t orca_bridge_abi_version(void);
void orca_owned_string_dispose(orca_owned_string *string);
void orca_result_dispose(orca_result *result);

/// Non-owning view into engine-held mesh memory. For orca_stl_load views the
/// memory is valid until orca_mesh_free; for plater views until the next
/// mutation of the plater or orca_plater_free. Copy synchronously.
/// Positions are in VIEWER space (y-up, bed-anchored): engine z-up was
/// converted, mesh recentred on origin, min-y dropped to 0.
typedef struct {
    const float    *positions;    // xyz triples, position_count entries
    int32_t         position_count;
    const uint32_t *indices;      // 3 per triangle
    int32_t         index_count;
    float           bbox_min[3];  // viewer space, mm
    float           bbox_max[3];
} orca_mesh_view;

typedef struct orca_mesh orca_mesh;
typedef struct orca_plater orca_plater;
typedef struct orca_presets orca_presets;

/// Load an STL through OrcaSlicer's real path (admesh read + repair).
/// On success: *out_mesh owns the mesh, *out_view aliases into it.
orca_result orca_stl_load(const char *path, orca_mesh **out_mesh,
                          orca_mesh_view *out_view);

/// Cleanup functions accept NULL and never throw.
void orca_mesh_free(orca_mesh *mesh);

/// Slices the ORIGINAL (engine-space) mesh at `levels` z-heights via
/// slice_mesh_ex — real OrcaSlicer slicing geometry. Reports the middle
/// layer's island count and total area.
orca_result orca_slice_report(orca_mesh *mesh, int32_t levels,
                              int32_t *out_levels, int32_t *out_mid_islands,
                              double *out_mid_area_mm2);

/// Instance transform, ENGINE space (z-up, mm). `anchor_*` is the
/// instance-matrix-transformed position of the packed mesh's recentring
/// pivot — the point that sits at (anchor_x, anchor_z, -anchor_y) in the
/// viewer's y-up space. rotation_z is radians about engine z; scale is
/// uniform.
typedef struct {
    double offset_x, offset_y, offset_z;   // mm
    double rotation_z;                     // radians about engine z
    double scale;                          // uniform and greater than zero
    double anchor_x, anchor_y, anchor_z;   // mm, engine space
} orca_instance_transform;

/// Plater session: owns a Slic3r::Model (objects + instances). IDs remain
/// indices temporarily; Architecture Gate A replaces them with stable IDs.
orca_result orca_plater_new(orca_plater **out_plater);
void orca_plater_free(orca_plater *plater);

orca_result orca_plater_add_stl(orca_plater *plater, const char *path,
                                int32_t *out_object_id);
orca_result orca_plater_object_count(orca_plater *plater, int32_t *out_count);
orca_result orca_plater_object_delete(orca_plater *plater, int32_t object_id);

orca_result orca_plater_instance_add(orca_plater *plater, int32_t object_id,
                                     int32_t *out_instance_id);
orca_result orca_plater_instance_delete(orca_plater *plater, int32_t object_id,
                                        int32_t instance_id);
orca_result orca_plater_instance_count(orca_plater *plater, int32_t object_id,
                                       int32_t *out_count);
orca_result orca_plater_instance_set(orca_plater *plater, int32_t object_id,
                                     int32_t instance_id,
                                     const orca_instance_transform *transform);
orca_result orca_plater_instance_get(orca_plater *plater, int32_t object_id,
                                     int32_t instance_id,
                                     orca_instance_transform *out_transform);

/// Packed viewer-space mesh for an object. The view remains valid only until
/// the next mutation of the plater or until the plater is freed.
orca_result orca_plater_mesh_view(orca_plater *plater, int32_t object_id,
                                  orca_mesh_view *out_view);

/// Drops every object so its lowest z sits on the bed (upstream semantic).
orca_result orca_plater_ensure_on_bed(orca_plater *plater);

/// System preset bundle loaded from the bundled OrcaSlicer profile tree at
/// `data_dir_path` (<dir>/system/<Vendor>.json and vendor subdirectories).
orca_result orca_presets_new(const char *data_dir_path, orca_presets **out);
void orca_presets_free(orca_presets *presets);

/// kind: 0 = machine (printer), 1 = filament, 2 = process (print).
orca_result orca_presets_list_count(orca_presets *presets, int32_t kind,
                                    int32_t *out_count);
/// Returned names are caller-owned and independent of later preset calls.
orca_result orca_presets_list_name(orca_presets *presets, int32_t kind,
                                   int32_t index, orca_owned_string *out_name);
orca_result orca_presets_select(orca_presets *presets, const char *machine,
                                const char *filament, const char *process);
orca_result orca_presets_current(orca_presets *presets, int32_t kind,
                                 orca_owned_string *out_name);

/// Progress callbacks run synchronously on the thread executing the slice;
/// message strings are borrowed and valid only for the callback.
typedef void (*orca_progress_fn)(int32_t percent, const char *message, void *ctx);

/// Full slice: STL in → G-code file out, through OrcaSlicer's real pipeline.
/// All slice calls are blocking and must run off the main thread. Output
/// values are initialized defensively and valid only when the result is OK.
orca_result orca_slice_to_gcode(const char *stl_path, const char *gcode_path,
                                orca_progress_fn progress, void *ctx,
                                double *out_time_estimate_s,
                                int64_t *out_gcode_bytes);

orca_result orca_plater_slice_to_gcode(orca_plater *plater,
                                       const char *gcode_path,
                                       orca_progress_fn progress, void *ctx,
                                       double *out_time_estimate_s,
                                       int64_t *out_gcode_bytes);

orca_result orca_plater_slice_to_gcode_with_presets(
    orca_plater *plater, orca_presets *presets, const char *gcode_path,
    orca_progress_fn progress, void *ctx, double *out_time_estimate_s,
    int64_t *out_gcode_bytes);

#if defined(__cplusplus)
}
#endif
