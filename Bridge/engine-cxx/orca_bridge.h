#pragma once

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/// Version of the C ABI contract in this header. Callers verify it at runtime.
#define ORCA_BRIDGE_ABI_VERSION ((uint32_t)8)

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

typedef uint64_t orca_document_id;
typedef uint64_t orca_object_id;
typedef uint64_t orca_instance_id;
typedef uint64_t orca_revision;

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

/// Canonical engine-space instance transform: z-up, millimetres, radians.
/// Rotation is the engine's own Euler decomposition
/// (Geometry::Transformation::get_rotation / set_rotation); scale is per
/// local axis and each factor must be > 0. Mirroring is not supported.
typedef struct {
    double offset_x, offset_y, offset_z;
    double rotation_x, rotation_y, rotation_z;
    double scale_x, scale_y, scale_z;
} orca_instance_transform;

/// Deep-copied, immutable scene snapshot values. All mesh positions and bounds
/// are canonical engine coordinates (z-up); renderer coordinate policy stays
/// in the Swift client.
typedef struct {
    orca_instance_id id;
    orca_instance_transform transform;
    /// The engine's instance matrix (ModelInstance::get_matrix()),
    /// column-major. Clients render and preview from this matrix and never
    /// re-derive it from the Euler angles.
    double matrix[16];
} orca_scene_instance;

typedef struct {
    orca_object_id id;
    uint64_t mesh_revision;
    orca_owned_string name;
    float *positions;             // xyz triples, position_count entries
    int32_t position_count;
    uint32_t *indices;            // index_count entries
    int32_t index_count;
    float bbox_min[3];            // engine space
    float bbox_max[3];
    float pivot[3];               // object-space packing pivot
    orca_scene_instance *instances;
    int32_t instance_count;
} orca_scene_object;

typedef struct {
    orca_document_id document_id;
    orca_revision revision;
    orca_scene_object *objects;
    int32_t object_count;
} orca_scene_snapshot;

/// Opaque authoritative document session. Fallible engine operations are
/// process-serialized by the Bridge because upstream engine globals require
/// single-threaded entry. A handle must not be freed concurrently with a call.
typedef struct orca_plater orca_plater;

orca_result orca_plater_new(orca_plater **out_plater);
void orca_plater_free(orca_plater *plater);

/// Every successful mutation advances and returns the document revision.
/// Import centers the mesh via upstream `center_around_origin()` (desktop
/// parity) and places the instance at the caller-provided bed center
/// (millimetres, engine z-up space) so placement follows the selected
/// machine's print volume.
orca_result orca_plater_add_stl(orca_plater *plater, const char *path,
                                double bed_center_x, double bed_center_y,
                                orca_object_id *out_object_id,
                                orca_revision *out_revision);
orca_result orca_plater_object_delete(orca_plater *plater,
                                      orca_object_id object_id,
                                      orca_revision *out_revision);
orca_result orca_plater_instance_add(orca_plater *plater,
                                     orca_object_id object_id,
                                     orca_instance_id *out_instance_id,
                                     orca_revision *out_revision);
orca_result orca_plater_instance_delete(orca_plater *plater,
                                        orca_object_id object_id,
                                        orca_instance_id instance_id,
                                        orca_revision *out_revision);
/// Absolute transform. Like desktop manipulation, the instance is then
/// rested on the bed (offset z adjusted so its exact transformed bounding
/// box touches z = 0).
orca_result orca_plater_instance_set(orca_plater *plater,
                                     orca_object_id object_id,
                                     orca_instance_id instance_id,
                                     const orca_instance_transform *transform,
                                     orca_revision *out_revision);
/// Incremental rotation about a WORLD axis (0 = X, 1 = Y, 2 = Z) through the
/// instance origin (the object center after import centering), composed by
/// the engine (ModelInstance::rotate), then rested on the bed. Repeated steps
/// wrap continuously through 360 degrees.
orca_result orca_plater_instance_rotate(orca_plater *plater,
                                        orca_object_id object_id,
                                        orca_instance_id instance_id,
                                        int32_t axis, double radians,
                                        orca_revision *out_revision);
orca_result orca_plater_ensure_on_bed(orca_plater *plater,
                                      orca_revision *out_revision);

/// Produces a deep copy at one authoritative document revision. The caller
/// owns every nested allocation and must call orca_scene_snapshot_dispose().
orca_result orca_plater_snapshot(orca_plater *plater,
                                 orca_scene_snapshot *out_snapshot);
void orca_scene_snapshot_dispose(orca_scene_snapshot *snapshot);

/// System preset bundle loaded from the bundled OrcaSlicer profile tree at
/// `data_dir_path` (<dir>/system/<Vendor>.json and vendor subdirectories).
typedef struct orca_presets orca_presets;
orca_result orca_presets_new(const char *data_dir_path, orca_presets **out);
void orca_presets_free(orca_presets *presets);

/// kind: 0 = machine (printer), 1 = filament, 2 = process (print).
orca_result orca_presets_list_count(orca_presets *presets, int32_t kind,
                                    int32_t *out_count);
/// Returned names are caller-owned and independent of later preset calls.
orca_result orca_presets_list_name(orca_presets *presets, int32_t kind,
                                   int32_t index, orca_owned_string *out_name);

/// Full preset metadata at the same stable order as orca_presets_list_name.
/// `vendor` is the manufacturer display name (empty when unknown);
/// `compatible` mirrors the engine's own `is_compatible` flag computed by
/// `update_compatible` against the currently selected machine (always 1 for
/// machines themselves).
typedef struct {
    orca_owned_string name;
    orca_owned_string vendor;
    uint8_t          compatible;
} orca_preset_entry;

orca_result orca_presets_list_entry(orca_presets *presets, int32_t kind,
                                    int32_t index,
                                    orca_preset_entry *out_entry);
void orca_preset_entry_dispose(orca_preset_entry *entry);

/// Axis-aligned bounding rectangle of the selected machine's `printable_area`
/// (engine z-up millimetres). The origin position inside the area is
/// MACHINE-DEPENDENT — most cartesians use a corner (0x0..250x210) while
/// some beds (e.g. FLSun deltas) are centered (min<0). Callers must derive
/// placement from this rectangle, never from an origin assumption.
orca_result orca_presets_print_volume(orca_presets *presets,
                                      double *out_min_x, double *out_min_y,
                                      double *out_max_x, double *out_max_y);

/// Plate (bed) type state — desktop sidebar "plate type" parity. Values are
/// the engine's `Slic3r::BedType` (1 = Cool Plate … btCount-1); slicing reads
/// bed temperatures through the project option `curr_bed_type`.
typedef struct {
    int32_t  current;          // project curr_bed_type
    int32_t  machine_default;  // Preset::get_default_bed_type of the machine
    int32_t  count;            // engine btCount (valid values: 1..count-1)
    uint8_t  selectable;       // BBL vendor or support_multi_bed_types
    uint8_t  reserved[3];
    uint32_t supported_mask;   // bit v set ⇔ BedType v offered for the model
} orca_bed_type_state;

orca_result orca_presets_bed_type(orca_presets *presets,
                                  orca_bed_type_state *out_state);
/// Sets project curr_bed_type. Rejects values outside 1..count-1, values the
/// printer model does not support, and any non-default value on machines
/// without selectable plate types. Selecting a different machine resets the
/// value to that machine's default (desktop Sidebar::update_presets).
orca_result orca_presets_set_bed_type(orca_presets *presets, int32_t bed_type);

/// The complete resolved configuration exactly as slicing will consume it
/// (`PresetBundle::full_config()` of the current selection), serialized to a
/// caller-owned JSON object of { "key": "serialized value" }.
orca_result orca_presets_resolved_config(orca_presets *presets,
                                         orca_owned_string *out_json);

/// Desktop-parity config editing: overrides are written to the working
/// (edited) preset of `kind`; `full_config()` merges edited presets, so
/// slicing consumes overrides by construction. Selecting a preset resets its
/// edited copy. `serialized_value` uses the option's own serialization.
orca_result orca_presets_set_value(orca_presets *presets, int32_t kind,
                                   const char *key,
                                   const char *serialized_value);
/// Restores one key of the edited preset from the selected system preset
/// (erasing it when the system preset does not define the key).
orca_result orca_presets_reset_value(orca_presets *presets, int32_t kind,
                                     const char *key);
/// Restores the whole edited preset of `kind` from its selected system
/// preset.
orca_result orca_presets_reset_kind(orca_presets *presets, int32_t kind);
/// Serialized key→value dump of either the edited (`edited` != 0) or the
/// selected system (`edited` == 0) preset config of `kind`; the client diffs
/// the two to detect modified values.
orca_result orca_presets_config_dump(orca_presets *presets, int32_t kind,
                                    uint8_t edited,
                                    orca_owned_string *out_json);

/// Parsed G-code for the toolpath preview. Loading runs the full upstream
/// GCodeProcessor over the file (CPU-heavy: run off the main thread; the
/// engine mutex serializes it against other engine work).
typedef struct orca_gcode orca_gcode;

orca_result orca_gcode_load(const char *path, orca_gcode **out_gcode);
void orca_gcode_free(orca_gcode *gcode);

/// One preview segment. Positions are canonical engine z-up millimetres;
/// `role` carries the engine's own Slic3r::ExtrusionRole values (0..19) and
/// `move_type` its EMoveType values (Travel=8, Extrude=10) — never the
/// libvgcode reorderings.
typedef struct {
    float    start[3];
    float    end[3];
    float    feedrate;      // mm/s
    float    width;         // mm
    float    height;        // mm
    float    mm3_per_mm;    // flow cross-section
    uint8_t  move_type;
    uint8_t  role;
    uint8_t  extruder;
    uint8_t  flags;         // bit0 = internal_only
    uint16_t layer_id;
    uint16_t reserved;
    float    print_z;       // layer z, mm
    float    time_seconds;  // estimated move time (normal mode)
    float    fan_speed;     // part fan, percent
    float    temperature;   // nozzle, degrees C
} orca_tp_segment;

typedef struct {
    float    z;             // layer z, mm
    uint32_t first_segment;
    uint32_t segment_count;
    float    time_seconds;
} orca_tp_layer;

typedef struct {
    uint32_t          segment_count;
    uint32_t          layer_count;
    orca_tp_segment  *segments;   // caller-owned; see dispose
    orca_tp_layer    *layers;
    float             estimated_time_seconds;
    float             printable_height;
} orca_toolpath;

/// Extracts the compact, caller-owned toolpath copy; the `orca_gcode` handle
/// may be freed immediately afterwards.
orca_result orca_gcode_toolpath(orca_gcode *gcode,
                                orca_toolpath *out_toolpath);
void orca_toolpath_dispose(orca_toolpath *toolpath);
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
