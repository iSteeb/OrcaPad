#pragma once

#include <stdint.h>

#if defined(__cplusplus)
extern "C" {
#endif

/// Version of the C ABI contract in this header. Callers verify it at runtime.
#define ORCA_BRIDGE_ABI_VERSION ((uint32_t)29)

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
typedef uint64_t orca_volume_id;
typedef uint64_t orca_plate_id;
typedef uint64_t orca_revision;

/// Desktop PartPlateList::MAX_PLATE_COUNT — the arranger never needs more;
/// adding beyond this is a typed INVALID_ARGUMENT.
#define ORCA_PLATE_MAX_COUNT ((int32_t)36)

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
    /// 1 when the instance matrix is left-handed (mirrored on an odd number
    /// of axes); renderers flip face winding / normals for it.
    uint8_t mirrored;
    /// 0 when excluded from slicing (desktop printable toggle).
    uint8_t printable;
    uint8_t reserved[2];
    /// The engine's instance matrix (ModelInstance::get_matrix()),
    /// column-major. Clients render and preview from this matrix and never
    /// re-derive it from the Euler angles.
    double matrix[16];
    /// Plate assignment (index into the snapshot's plate list, derived by
    /// the Bridge: locked-plate pins first, then the first plate whose box
    /// intersects the instance). -1 = on no plate (not sliced).
    int32_t plate;
} orca_scene_instance;

/// One plate of the document (desktop PartPlate, minus GUI state). Plates
/// live in a grid beside the bed: ceil-sqrt columns, 1.2x stride, rows
/// growing in -Y (desktop compute_shape_position).
typedef struct {
    orca_plate_id id;            // stable across reorder
    int32_t index;               // display / slice order
    orca_owned_string name;
    uint8_t locked;              // members pinned, arrange skips them
    uint8_t reserved[3];
    float origin[3];             // engine coords, min corner of the plate box
    float size[3];               // width / depth / height (mm)
    int32_t object_count;        // objects with >= 1 instance on this plate
} orca_scene_plate;

/// Volume roles: desktop ModelVolumeType (object list parts / modifiers).
#define ORCA_VOLUME_PART             ((uint8_t)0)
#define ORCA_VOLUME_NEGATIVE         ((uint8_t)1)
#define ORCA_VOLUME_MODIFIER         ((uint8_t)2)
#define ORCA_VOLUME_SUPPORT_BLOCKER  ((uint8_t)3)
#define ORCA_VOLUME_SUPPORT_ENFORCER ((uint8_t)4)

/// One ModelVolume of an object, in document order. Bounds and positions
/// are OBJECT space (the volume's own transform applied), engine z-up mm.
/// Model parts render through the object's merged mesh and carry no
/// positions; every other role carries its own mesh (desktop draws
/// modifiers / negative volumes / blockers / enforcers separately).
typedef struct {
    orca_volume_id id;            // engine ObjectID of the volume (stable)
    orca_owned_string name;
    uint8_t type;                 // ORCA_VOLUME_*
    uint8_t reserved[3];
    int32_t extruder;             // volume "extruder" option (0 = object's)
    float bbox_min[3];
    float bbox_max[3];
    float *positions;             // xyz triples; NULL for model parts
    int32_t position_count;
    uint32_t *indices;
    int32_t index_count;
    // Model parts only: the volume's triangle range inside the object's
    // merged mesh (raw_mesh() concatenates part volumes in document order,
    // so triangle t lives at flattened indices [3t, 3t+3)). 0/0 for every
    // other role. Enables client-side part picking + highlight without
    // duplicating part geometry in the snapshot.
    uint32_t merged_triangle_start;
    uint32_t merged_triangle_count;
    uint32_t override_count;      // per-volume setting overrides
} orca_scene_volume;

typedef struct {
    orca_object_id id;
    /// Changes whenever ANY volume's geometry, role or composition changes.
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
    orca_scene_volume *volumes;   // >= 1, document order
    int32_t volume_count;
    uint32_t override_count;      // per-object setting overrides
} orca_scene_object;

typedef struct {
    orca_document_id document_id;
    orca_revision revision;
    orca_scene_object *objects;
    int32_t object_count;
    /// The document's plates (index order); always >= 1.
    orca_scene_plate *plates;
    int32_t plate_count;
    /// Index of the selected plate (session state, not undoable).
    int32_t current_plate;
    /// Undo/redo history at this revision (desktop Plater::undo/redo):
    /// step counts and the label of the step each command would apply
    /// (empty when the stack is empty).
    uint32_t undo_count;
    uint32_t redo_count;
    orca_owned_string undo_label;
    orca_owned_string redo_label;
} orca_scene_snapshot;

/// Opaque authoritative document session. Fallible engine operations are
/// process-serialized by the Bridge because upstream engine globals require
/// single-threaded entry. A handle must not be freed concurrently with a call.
typedef struct orca_plater orca_plater;

orca_result orca_plater_new(orca_plater **out_plater);
void orca_plater_free(orca_plater *plater);

/// Every successful mutation advances and returns the document revision.
/// Mutations are transactional: a failed mutation (typed failure or engine
/// exception) leaves the document exactly as it was. Every successful
/// mutation is one undo step (history bounded to 64 steps); opening a
/// project starts a new history. Mesh revisions are unique per session, so
/// (object id, mesh revision) identifies mesh content across undo/redo.
/// Imports EVERY object of a model file through upstream
/// `Model::read_from_file` (STL, OBJ, AMF, 3MF geometry — desktop "Import").
/// Each mesh is centered via `center_around_origin()` with instance offsets
/// compensated (file placements are preserved); the imported group's XY
/// bounding-box center is then moved to the caller's bed center (engine
/// z-up millimetres) and every object is dropped onto the bed. One import
/// is one mutation (+1 revision). Object IDs of the import are returned in
/// document order starting at `out_first_object_id`.
orca_result orca_plater_import_model(orca_plater *plater, const char *path,
                                     double bed_center_x, double bed_center_y,
                                     orca_object_id *out_first_object_id,
                                     uint32_t *out_object_count,
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
/// `label` names the undo step ("Move", "Scale", ...); NULL or empty means
/// "Transform".
orca_result orca_plater_instance_set(orca_plater *plater,
                                     orca_object_id object_id,
                                     orca_instance_id instance_id,
                                     const orca_instance_transform *transform,
                                     const char *label,
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
/// Desktop Edit > Undo / Redo: restores the previous / next history step
/// (same stable IDs as when it was recorded) and advances the revision.
/// ORCA_STATUS_NOT_FOUND when the respective stack is empty.
orca_result orca_plater_undo(orca_plater *plater, orca_revision *out_revision);
orca_result orca_plater_redo(orca_plater *plater, orca_revision *out_revision);
/// Desktop object-list rename. Empty / whitespace-only names are
/// ORCA_STATUS_INVALID_ARGUMENT.
orca_result orca_plater_object_rename(orca_plater *plater, orca_object_id object_id,
                                      const char *name, orca_revision *out_revision);
/// Desktop "Delete all": removes every object (one undo step).
/// ORCA_STATUS_INVALID_MODEL when the document is already empty.
orca_result orca_plater_clear(orca_plater *plater, orca_revision *out_revision);

// --- plates (ABI v27) ------------------------------------------------------

/// Bed geometry from the selected printer's print volume (client-driven;
/// desktop resets plate size when the machine changes). Derives every
/// plate's box; assignment is recomputed on the next snapshot. Not undoable,
/// does not advance the revision.
orca_result orca_plater_set_bed(orca_plater *plater,
                               double origin_x, double origin_y,
                               double width, double depth, double height,
                               orca_scene_snapshot *out_snapshot);
/// Adds an empty plate (max ORCA_PLATE_MAX_COUNT). One undo step.
orca_result orca_plater_plate_add(orca_plater *plater,
                                  orca_plate_id *out_plate_id,
                                  orca_revision *out_revision);
/// Deletes a plate: typed INVALID_ARGUMENT for the last remaining plate or
/// one that still carries objects (desktop refuses non-empty plates).
orca_result orca_plater_plate_delete(orca_plater *plater, orca_plate_id plate_id,
                                    orca_revision *out_revision);
/// Renames a plate. One undo step.
orca_result orca_plater_plate_rename(orca_plater *plater, orca_plate_id plate_id,
                                     const char *name,
                                     orca_revision *out_revision);
/// Locks/unlocks: locking PINS every instance currently on the plate (they
/// keep their assignment and are skipped by arrange); unlocking clears the
/// pins. One undo step.
orca_result orca_plater_plate_lock(orca_plater *plater, orca_plate_id plate_id,
                                   uint8_t lock, orca_revision *out_revision);
/// Desktop "Move plate to the front": reorders the plate to index 0 (the
/// layout of the other plates follows). One undo step.
orca_result orca_plater_plate_move_to_front(orca_plater *plater,
                                            orca_plate_id plate_id,
                                            orca_revision *out_revision);
/// Duplicates a plate: copies every object with an instance on it (new
/// stable IDs) onto a new trailing plate. One undo step.
orca_result orca_plater_plate_duplicate(orca_plater *plater, orca_plate_id plate_id,
                                         orca_plate_id *out_new_plate_id,
                                         orca_revision *out_revision);
/// Selects the plate the client works on (import target, slice source).
/// Session state: not undoable, no revision change.
orca_result orca_plater_plate_select(orca_plater *plater, orca_plate_id plate_id,
                                     orca_scene_snapshot *out_snapshot);

/// Built-in shapes (desktop GUI_ObjectList create_mesh). `size_mm` is the
/// desktop side length (10% of the largest bed dimension). SLAB is only
/// valid for volumes: 1.5x the instance footprint, half its height.
#define ORCA_SHAPE_CUBE     ((int32_t)0)
#define ORCA_SHAPE_CYLINDER ((int32_t)1)
#define ORCA_SHAPE_SPHERE   ((int32_t)2)
#define ORCA_SHAPE_CONE     ((int32_t)3)
#define ORCA_SHAPE_DISC     ((int32_t)4)
#define ORCA_SHAPE_TORUS    ((int32_t)5)
#define ORCA_SHAPE_SLAB     ((int32_t)6)

/// Desktop "Add Primitive" (new object): the shape placed at the bed
/// center, resting on the bed.
orca_result orca_plater_add_shape_object(orca_plater *plater, int32_t shape,
                                         double size_mm, double bed_center_x,
                                         double bed_center_y,
                                         orca_object_id *out_object_id,
                                         orca_revision *out_revision);
/// Desktop ObjectList::load_generic_subobject: adds a shape volume of role
/// `type` to `object_id`, aligned with the bed for `instance_id` and placed
/// at that instance's front-right bounding-box corner (slab: centered).
orca_result orca_plater_volume_add_shape(orca_plater *plater, orca_object_id object_id,
                                         orca_instance_id instance_id, uint8_t type,
                                         int32_t shape, double size_mm,
                                         orca_volume_id *out_volume_id,
                                         orca_revision *out_revision);
/// Desktop ObjectList::load_modifier ("Load..."): the file's merged mesh
/// becomes one volume of role `type`, keeping its position relative to the
/// object's first volume in the source coordinates.
orca_result orca_plater_volume_add_file(orca_plater *plater, orca_object_id object_id,
                                        uint8_t type, const char *path,
                                        orca_volume_id *out_volume_id,
                                        orca_revision *out_revision);
/// Changes a volume's role. Turning the last model part into anything
/// else is ORCA_STATUS_INVALID_ARGUMENT (an object keeps a solid part).
orca_result orca_plater_volume_set_type(orca_plater *plater, orca_object_id object_id,
                                        orca_volume_id volume_id, uint8_t type,
                                        orca_revision *out_revision);
/// Deletes a volume; the last model part cannot be deleted
/// (ORCA_STATUS_INVALID_ARGUMENT: delete the object instead).
orca_result orca_plater_volume_delete(orca_plater *plater, orca_object_id object_id,
                                      orca_volume_id volume_id,
                                      orca_revision *out_revision);
orca_result orca_plater_volume_rename(orca_plater *plater, orca_object_id object_id,
                                      orca_volume_id volume_id, const char *name,
                                      orca_revision *out_revision);
/// Desktop "Split to objects" (ModelObject::split): replaces the object by
/// one object per connected mesh (or per part of a multi-part object),
/// each dropped onto the bed. A single-body object is ORCA_STATUS_INVALID_MODEL.
orca_result orca_plater_split_objects(orca_plater *plater, orca_object_id object_id,
                                      orca_object_id *out_first_object_id,
                                      uint32_t *out_object_count,
                                      orca_revision *out_revision);
/// Desktop "Split to parts" (ModelVolume::split) of model part `volume_id`
/// (0 = the object's only model part). A single-body part is
/// ORCA_STATUS_INVALID_MODEL.
orca_result orca_plater_split_parts(orca_plater *plater, orca_object_id object_id,
                                    orca_volume_id volume_id,
                                    uint32_t *out_part_count,
                                    orca_revision *out_revision);
/// Desktop Selection::mirror: toggles the instance mirror on one axis
/// (0 = X, 1 = Y, 2 = Z); the instance is rested on the bed again. Mirrored
/// instances report `mirrored` in snapshots; their transform fields stay
/// absolute (positive scales).
orca_result orca_plater_instance_mirror(orca_plater *plater,
                                        orca_object_id object_id,
                                        orca_instance_id instance_id,
                                        int32_t axis, orca_revision *out_revision);
/// Group (multi-selection) operations: N parallel (object, instance) pairs,
/// applied atomically as ONE mutation and ONE undo step.
/// orca_plater_instances_set applies absolute transforms (rested on bed);
/// `label` names the undo step (NULL/empty = "Transform").
orca_result orca_plater_instances_set(
    orca_plater *plater,
    const orca_object_id *object_ids,
    const orca_instance_id *instance_ids,
    const orca_instance_transform *transforms,
    int32_t count, const char *label,
    orca_revision *out_revision);
/// Rotates every listed instance by the same world-axis step through its own
/// origin (desktop multi-selection rotate), rested on bed.
orca_result orca_plater_instances_rotate(
    orca_plater *plater,
    const orca_object_id *object_ids,
    const orca_instance_id *instance_ids,
    int32_t count, int32_t axis, double radians,
    orca_revision *out_revision);
/// Desktop multi-selection delete of individual instances (subset of an
/// object's instances): every listed (object, instance) pair is removed in
/// ONE undo step (a failure deletes nothing). Duplicate pairs collapse;
/// deleting an object's last instance this way deletes the object.
orca_result orca_plater_instances_delete(
    orca_plater *plater,
    const orca_object_id *object_ids,
    const orca_instance_id *instance_ids,
    int32_t count,
    orca_revision *out_revision);
/// Per-object / per-part setting overrides (desktop object list "Edit
/// Process Settings"): ModelObject::config when `volume_id` is 0, else the
/// ModelVolume::config. Objects accept PrintObjectConfig + PrintRegionConfig
/// keys, volumes PrintRegionConfig keys (desktop SettingsFactory::get_options).
/// Overrides are slice inputs (Print::apply consumes them).
/// Allowed keys for objects (for_volume = 0) or volumes, JSON string array.
orca_result orca_plater_settings_keys(uint8_t for_volume, orca_owned_string *out_json);
/// Current overrides of the target as a JSON object {"key": "serialized"}.
orca_result orca_plater_settings_dump(orca_plater *plater, orca_object_id object_id,
                                      orca_volume_id volume_id,
                                      orca_owned_string *out_json);
/// Sets one override (the option's own serialization). Keys the target does
/// not accept are ORCA_STATUS_INVALID_ARGUMENT; values the engine cannot
/// parse are ORCA_STATUS_INVALID_CONFIGURATION. One undo step.
orca_result orca_plater_settings_set(orca_plater *plater, orca_object_id object_id,
                                     orca_volume_id volume_id, const char *key,
                                     const char *serialized_value,
                                     orca_revision *out_revision);
/// Removes one override (ORCA_STATUS_NOT_FOUND when absent). One undo step.
orca_result orca_plater_settings_erase(orca_plater *plater, orca_object_id object_id,
                                       orca_volume_id volume_id, const char *key,
                                       orca_revision *out_revision);
/// Desktop "Paste Process Settings": REPLACES every override of the target
/// with the given key/value pairs in ONE undo step (a failure changes
/// nothing). Semantics follow ObjectList::paste_settings_into_list: existing
/// overrides are cleared, then each pair is applied after validation; every
/// key must be accepted by the target kind (INVALID_ARGUMENT otherwise) and
/// every value must parse (INVALID_CONFIGURATION otherwise).
orca_result orca_plater_settings_apply(orca_plater *plater, orca_object_id object_id,
                                       orca_volume_id volume_id,
                                       const char *const *keys,
                                       const char *const *serialized_values,
                                       int32_t count, orca_revision *out_revision);
/// Desktop printable toggle: `instance_id` 0 applies to the object and all
/// its instances. Non-printable instances are skipped by slicing.
orca_result orca_plater_set_printable(orca_plater *plater, orca_object_id object_id,
                                      orca_instance_id instance_id, uint8_t printable,
                                      orca_revision *out_revision);
/// Desktop "Set number of instances": adds (offset copies of the last
/// instance) or removes trailing instances; count 1..1000. One undo step.
orca_result orca_plater_set_instance_count(orca_plater *plater, orca_object_id object_id,
                                           int32_t count, orca_revision *out_revision);
/// Desktop Clone: `count` (1..100) object copies beside the original;
/// callers arrange afterwards when requested. One undo step.
orca_result orca_plater_clone_object(orca_plater *plater, orca_object_id object_id,
                                     int32_t count, orca_object_id *out_first_object_id,
                                     orca_revision *out_revision);
/// Desktop "Set as an individual object": moves one instance (of an object
/// with several) into a new object.
orca_result orca_plater_instance_to_object(orca_plater *plater, orca_object_id object_id,
                                           orca_instance_id instance_id,
                                           orca_object_id *out_object_id,
                                           orca_revision *out_revision);
/// Desktop "Assemble" (ObjectList::merge): >= 2 single-instance objects
/// become one multi-part object named "Assembly", world placement kept.
orca_result orca_plater_merge_objects(orca_plater *plater, const orca_object_id *object_ids,
                                      int32_t count, orca_object_id *out_object_id,
                                      orca_revision *out_revision);
/// Desktop unit conversion (ModelObject::convert_units); the converted
/// object replaces the original.
#define ORCA_UNITS_FROM_INCH  ((int32_t)0)
#define ORCA_UNITS_TO_INCH    ((int32_t)1)
#define ORCA_UNITS_FROM_METER ((int32_t)2)
#define ORCA_UNITS_TO_METER   ((int32_t)3)
orca_result orca_plater_convert_units(orca_plater *plater, orca_object_id object_id,
                                      int32_t conversion, orca_object_id *out_object_id,
                                      orca_revision *out_revision);
/// Per-layer custom G-code (desktop layer-slider ticks, plate 0):
/// Model::plates_custom_gcodes — colour changes, pauses, tool changes and
/// raw custom G-code, consumed by slicing (tool ordering / M600 / pauses).
#define ORCA_CUSTOM_COLOR_CHANGE ((int32_t)0)
#define ORCA_CUSTOM_PAUSE_PRINT  ((int32_t)1)
#define ORCA_CUSTOM_TOOL_CHANGE  ((int32_t)2)
#define ORCA_CUSTOM_TEMPLATE     ((int32_t)3)
#define ORCA_CUSTOM_CUSTOM       ((int32_t)4)
typedef struct {
    double             print_z;   // first layer printed with it applied
    int32_t            type;      // ORCA_CUSTOM_*
    int32_t            extruder;  // 1-based (colour / tool changes)
    orca_owned_string  color;     // #rrggbb (colour changes; pause message)
    orca_owned_string  extra;     // G-code text (custom), message (pause)
} orca_custom_gcode_item;
void orca_custom_gcode_item_dispose(orca_custom_gcode_item *item);
orca_result orca_plater_custom_gcode_count(orca_plater *plater, int32_t *out_count);
/// Item at `index`, in ascending print_z order.
orca_result orca_plater_custom_gcode_item(orca_plater *plater, int32_t index,
                                          orca_custom_gcode_item *out_item);
/// Adds (or replaces the item at the same print_z within 1e-6). Colour and
/// tool changes need extruder >= 1; TEMPLATE needs the preset template
/// G-code and is a typed unsupported capability. One undo step.
orca_result orca_plater_custom_gcode_add(orca_plater *plater, double print_z,
                                         int32_t type, int32_t extruder,
                                         const char *color, const char *extra,
                                         orca_revision *out_revision);
/// Removes the item at `print_z` (within 1e-6; NOT_FOUND when absent).
orca_result orca_plater_custom_gcode_delete(orca_plater *plater, double print_z,
                                            orca_revision *out_revision);
/// Desktop clipboard: copies one object (volumes + instances). No document
/// change, no undo step. Superseded by orca_plater_objects_copy (kept as a
/// count = 1 convenience wrapper).
orca_result orca_plater_object_copy(orca_plater *plater, orca_object_id object_id);
/// Pastes the clipboard object at (bed_center_x, bed_center_y)
/// (ORCA_STATUS_NOT_FOUND when the clipboard is empty). One undo step.
orca_result orca_plater_object_paste(orca_plater *plater, double bed_center_x,
                                     double bed_center_y,
                                     orca_object_id *out_object_id,
                                     orca_revision *out_revision);
/// Desktop "Cut"/group delete: removes every listed object in ONE undo
/// step (a failure deletes nothing). Duplicate IDs are collapsed.
orca_result orca_plater_objects_delete(orca_plater *plater,
                                       const orca_object_id *object_ids,
                                       int32_t count,
                                       orca_revision *out_revision);
/// Desktop multi-object clipboard: copies all listed objects (volumes +
/// instances) keeping their relative placements. No document change, no
/// undo step. Duplicate IDs are collapsed; every ID must exist.
orca_result orca_plater_objects_copy(orca_plater *plater,
                                     const orca_object_id *object_ids,
                                     int32_t count);
/// Pastes every clipboard object: the first lands centred at
/// (bed_center_x, bed_center_y), the others keep their relative placement
/// (ORCA_STATUS_NOT_FOUND when the clipboard is empty). One undo step for
/// the whole batch. out_ids receives the pasted object IDs in clipboard
/// order (capacity must be >= the clipboard size; pass the actual capacity,
/// the call fails with INVALID_ARGUMENT when it is too small).
orca_result orca_plater_objects_paste(orca_plater *plater,
                                     double bed_center_x, double bed_center_y,
                                     orca_object_id *out_ids, int32_t capacity,
                                     int32_t *out_count,
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
/// Listed presets of a kind: every non-default preset (system, user,
/// project-embedded, external), sorted by name — the stable order shared by
/// list_name and list_entry. `orca_presets_select` accepts exactly these.
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
#define ORCA_PRESET_ORIGIN_SYSTEM   ((uint8_t)0)
#define ORCA_PRESET_ORIGIN_USER     ((uint8_t)1) // user / imported bundle
#define ORCA_PRESET_ORIGIN_PROJECT  ((uint8_t)2) // embedded in a loaded project
#define ORCA_PRESET_ORIGIN_EXTERNAL ((uint8_t)3) // loaded from a file's config

typedef struct {
    orca_owned_string name;
    orca_owned_string vendor;
    uint8_t          compatible;
    uint8_t          origin;     // ORCA_PRESET_ORIGIN_*
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

/// Desktop Tab::save_preset: saves the edited preset of `kind` as the user
/// preset `name` (new, or overwriting an existing user preset), selects it,
/// and writes <data_dir>/user/default/<kind>/<name>.json (+ .info). `detach`
/// clears the link to the parent system preset. Name rules are desktop
/// SavePresetDialog's: non-empty, no leading/trailing space, none of
/// <>[]:/\|?*" , no "(modified)" suffix, not a reserved/alias name —
/// violations are ORCA_STATUS_INVALID_ARGUMENT; overwriting a system preset
/// is ORCA_STATUS_INVALID_CONFIGURATION.
orca_result orca_presets_save_user(orca_presets *presets, int32_t kind,
                                   const char *name, uint8_t detach);
/// Desktop Tab::delete_preset: deletes user preset `name` of `kind` (file +
/// entry). Deleting the selected preset selects the next visible one.
/// System/default presets and presets other presets inherit from are
/// ORCA_STATUS_INVALID_CONFIGURATION.
orca_result orca_presets_delete_user(orca_presets *presets, int32_t kind,
                                     const char *name);

/// Physical printers (desktop PhysicalPrinterDialog / Device tab): persisted
/// through the engine's own PhysicalPrinterCollection as JSON under
/// <data_dir>/user/default/physical_machine. `host_type` is one of the
/// engine's `print_host_type` enum values ("octoprint", "moonraker", …).
typedef struct {
    orca_owned_string name;
    orca_owned_string host_type;
    orca_owned_string url;          // print_host, e.g. http://192.168.1.2
    orca_owned_string webui;        // print_host_webui ("" = the Device tab
                                    // shows `url`, PrintHost::get_print_host_webui)
    orca_owned_string api_key;      // printhost_apikey
    orca_owned_string preset_names; // '\n'-joined printer presets
} orca_physical_printer;
void orca_physical_printer_dispose(orca_physical_printer *printer);

orca_result orca_physical_printer_count(orca_presets *presets, int32_t *out_count);
orca_result orca_physical_printer_list(orca_presets *presets, int32_t index,
                                       orca_physical_printer *out_printer);
/// Creates or updates the physical printer `name` and ties it to printer
/// preset `preset_name`. Rejects unknown host types and non-http(s) URLs.
/// `webui_url` (print_host_webui, the desktop "Device UI" field) may be
/// empty; a non-empty value must be http(s) as well.
orca_result orca_physical_printer_upsert(orca_presets *presets, const char *name,
                                         const char *host_type, const char *url,
                                         const char *webui_url,
                                         const char *api_key,
                                         const char *preset_name);
orca_result orca_physical_printer_delete(orca_presets *presets, const char *name);

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

/// Desktop "Open project": loads a 3MF project (model + embedded presets +
/// project settings, `PresetBundle::load_config_model`) and REPLACES the
/// document (new document id, revision +1) and the preset session
/// atomically — nothing changes on failure. Object placements are kept
/// exactly (project semantics). Projects whose plates 2+ hold objects are
/// rejected with ORCA_STATUS_UNSUPPORTED_CAPABILITY (single plate only).
#define ORCA_PROJECT_FROM_ORCA   ((uint8_t)0)
#define ORCA_PROJECT_FROM_BBS    ((uint8_t)1)
#define ORCA_PROJECT_FROM_PRUSA  ((uint8_t)2)
#define ORCA_PROJECT_FROM_OTHER  ((uint8_t)3)
typedef struct {
    orca_revision revision;
    uint32_t      object_count;
    uint32_t      plate_count;     // plates described by the file (0 = none)
    uint8_t       config_applied;  // project settings adopted into presets
    uint8_t       source;          // ORCA_PROJECT_FROM_*
    uint8_t       reserved[6];
} orca_project_info;
orca_result orca_project_open(orca_plater *plater, orca_presets *presets,
                              const char *path, orca_project_info *out_info);

/// Desktop "Scale to build volume": uniform scale so the instance fits the
/// selected machine's volume (0.01 mm slack), centered on the bed.
orca_result orca_plater_scale_to_fit(orca_plater *plater, orca_presets *presets,
                                     orca_object_id object_id, orca_instance_id instance_id,
                                     orca_revision *out_revision);

/// Desktop "Auto orient" (OrientJob): orients the selected instance, or
/// every instance when object_id == 0, using the engine's orienter
/// (min-area mode by default) with `support_threshold_angle` from the
/// current preset full config (`presets` may be null for engine defaults).
/// One mutation: revision +1.
orca_result orca_plater_orient(orca_plater *plater, orca_presets *presets,
                               orca_object_id object_id,
                               orca_instance_id instance_id,
                               orca_revision *out_revision);

/// Desktop "Lay flat" (Flatten gizmo): rotates the instance so the given
/// face normal (ENGINE z-up world space, from a tapped facet) points down,
/// then rests the object on the bed. One mutation: revision +1.
orca_result orca_plater_instance_lay_flat(orca_plater *plater,
                                          orca_object_id object_id,
                                          orca_instance_id instance_id,
                                          double nx, double ny, double nz,
                                          orca_revision *out_revision);

/// One candidate resting plane of the desktop Flatten gizmo: a convex
/// polygon on the instance's hull (world/engine coordinates, shrunk 10%
/// toward its centroid like desktop), its OUTWARD world normal and its
/// area in square millimetres.
typedef struct {
    int32_t vertex_count;
    float (*vertices)[3];
    double normal[3];
    float area;
} orca_flatten_plane;

typedef struct {
    uint32_t plane_count;
    orca_flatten_plane *planes;
} orca_flatten_planes;

void orca_flatten_planes_dispose(orca_flatten_planes *planes);

/// Desktop GLGizmoFlatten::update_planes (ABI v29): merged convex hull of
/// the object's parts, hull facets grouped into coplanar planes (BFS over
/// face neighbors, normal epsilon 0.001), discarding slivers (< 1 mm
/// side), planes under 5 mm^2 and angles over 179 degrees. Read-only; not
/// a mutation. Empty result (no plane passes the filters) is a typed
/// ORCA_STATUS_INVALID_MODEL.
orca_result orca_plater_flatten_planes(orca_plater *plater,
                                       orca_object_id object_id,
                                       orca_instance_id instance_id,
                                       orca_flatten_planes *out);

/// Desktop "Arrange" (ArrangeJob/CLI flow: update_arrange_params →
/// inflation → get_shrink_bedpts → arrangement::arrange → apply). Arranges
/// EVERY instance. Items that do not fit the bed are placed on the next
/// virtual bed (shifted beside the printable area) and counted in
/// out_unprintable — desktop shows them on extra plates. One mutation.
orca_result orca_plater_arrange(orca_plater *plater, orca_presets *presets,
                                uint8_t allow_rotations,
                                uint32_t *out_unprintable,
                                orca_revision *out_revision);

/// Desktop "Save project": writes the document as a single-plate Orca 3MF
/// (`store_bbs_3mf`) with the session's secure full config
/// (`full_config_secure`, no print-host credentials) and project-embedded
/// presets, plus the plate thumbnail when `thumbnail_rgba` is non-null
/// (top-down RGBA8, `thumbnail_size` square). Saving is not a mutation.
orca_result orca_project_save(orca_plater *plater, orca_presets *presets,
                              const char *path, uint32_t thumbnail_size,
                              const uint8_t *thumbnail_rgba);

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
    uint8_t  move_type;     // EMoveType; marker types (Seam, Retract, …)
                             // are POINT segments: start == end
    uint8_t  role;
    uint8_t  extruder;
    uint8_t  flags;         // bit0 = internal_only
    uint16_t layer_id;
    uint16_t reserved;
    float    print_z;       // layer z, mm
    float    time_seconds;  // estimated move time (normal mode)
    float    fan_speed;     // part fan, percent
    float    temperature;   // nozzle, degrees C
    float    actual_feedrate;       // after machine limits, mm/s
    float    volumetric_rate;       // feedrate × mm3_per_mm, mm³/s
    float    actual_volumetric_rate; // actual_feedrate × mm3_per_mm
    float    pressure_advance;      // s
    float    acceleration;          // mm/s²
    float    jerk;                  // mm/s
    float    layer_duration;        // s (of the segment's layer)
    float    time_stealth;          // estimated move time (silent mode), s
} orca_tp_segment;

#define ORCA_TP_MAX_EXTRUDERS 16

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
    float             estimated_time_seconds;      // normal mode
    float             estimated_stealth_seconds;   // silent mode (0 if same)
    float             printable_height;
    // Per-extruder totals for the legend (desktop Total Estimation).
    uint32_t          extruder_count;              // 1..ORCA_TP_MAX_EXTRUDERS
    float             filament_diameters[ORCA_TP_MAX_EXTRUDERS];  // mm
    float             filament_densities[ORCA_TP_MAX_EXTRUDERS]; // g/cm³
    float             filament_costs[ORCA_TP_MAX_EXTRUDERS];     // per kg
    double            total_volumes[ORCA_TP_MAX_EXTRUDERS];      // mm³
} orca_toolpath;

/// Extracts the compact, caller-owned toolpath copy; the `orca_gcode` handle
/// may be freed immediately afterwards.
orca_result orca_gcode_toolpath(orca_gcode *gcode,
                                orca_toolpath *out_toolpath);
void orca_toolpath_dispose(orca_toolpath *toolpath);
orca_result orca_presets_select(orca_presets *presets, const char *machine,
                                const char *filament, const char *process);

/// Desktop Sidebar printer change (ABI v25): selects `machine` and lets the
/// engine resolve a compatible process and filament — the machine's declared
/// default_print_profile / default_filament_profile is adopted while the
/// current selection is still a default preset (upstream load_selections /
/// ConfigWizard semantics), then update_compatible(Always) swaps any
/// incompatible selection. Read the resulting selection back with
/// orca_presets_current. No undo step (preset session, not a document).
orca_result orca_presets_select_machine(orca_presets *presets,
                                        const char *machine);
orca_result orca_presets_current(orca_presets *presets, int32_t kind,
                                 orca_owned_string *out_name);

/// Progress callbacks run synchronously on the thread executing the slice;
/// message strings are borrowed and valid only for the callback.
typedef void (*orca_progress_fn)(int32_t percent, const char *message, void *ctx);

/// Cancellation token for one slice call (desktop "Cancel" parity). Create
/// before slicing, pass to the slice call, and `cancel` from ANY thread while
/// it runs (never takes the engine lock). Cancelling before the slice starts
/// makes it return ORCA_STATUS_CANCELLED immediately. Free only after the
/// slice call returned.
typedef struct orca_slice_job orca_slice_job;
orca_result orca_slice_job_new(orca_slice_job **out_job);
void orca_slice_job_cancel(orca_slice_job *job);
void orca_slice_job_free(orca_slice_job *job);
/// Plate image for G-code thumbnails (desktop renders the scene per size;
/// OrcaPad renders once): `size`×`size` top-down RGBA8. The engine's own
/// `thumbnails` config decides sizes/formats; the Bridge box-filters this
/// image to each requested size. Without it, no thumbnails are written
/// (BBL printers carry thumbnails in the 3MF instead — engine behaviour).
orca_result orca_slice_job_set_thumbnail(orca_slice_job *job, uint32_t size,
                                         const uint8_t *rgba);

/// Engine G-code-processor severities map onto these (its level 2 and 3
/// both arrive as CRITICAL; slicing is never failed on them, like desktop).
#define ORCA_SLICE_WARNING_TIP      ((int32_t)0)
#define ORCA_SLICE_WARNING_WARNING  ((int32_t)1)
#define ORCA_SLICE_WARNING_CRITICAL ((int32_t)2)

#define ORCA_SLICE_SOURCE_VALIDATE     ((int32_t)1) // Print::validate warning
#define ORCA_SLICE_SOURCE_PRINT_STEP   ((int32_t)2) // Print step warnings
#define ORCA_SLICE_SOURCE_OBJECT_STEP  ((int32_t)3) // PrintObject step warnings
#define ORCA_SLICE_SOURCE_GCODE        ((int32_t)4) // GCodeProcessorResult::warnings
#define ORCA_SLICE_SOURCE_CONFLICT     ((int32_t)5) // G-code path conflict

/// One engine-reported slicing warning. `code` is the engine identifier
/// (G-code warning id such as "bed_temperature_too_high_than_filament",
/// validate opt_key, or "gcode_path_conflict") and may be empty; `message` is
/// engine text and may be empty for coded G-code warnings; `detail` carries
/// the object name or newline-joined params.
typedef struct {
    int32_t           level;
    int32_t           source;
    orca_owned_string code;
    orca_owned_string message;
    orca_owned_string detail;
} orca_slice_warning;

/// Caller-owned slice outcome; valid only when the slice result is OK.
typedef struct {
    double              time_estimate_s;   // normal mode
    int64_t             gcode_bytes;
    uint32_t            warning_count;
    orca_slice_warning *warnings;
} orca_slice_report;
void orca_slice_report_dispose(orca_slice_report *report);

/// Full slice: model in → validated (Print::validate: errors are
/// ORCA_STATUS_INVALID_CONFIGURATION with the engine message) → processed →
/// G-code file out. Blocking; run off the main thread. `job` may be null.
/// Cancellation returns ORCA_STATUS_CANCELLED.
orca_result orca_slice_to_gcode(const char *stl_path, const char *gcode_path,
                                orca_progress_fn progress, void *ctx,
                                orca_slice_job *job,
                                orca_slice_report *out_report);

/// Desktop "Slice all" (ABI v27): slices every non-empty plate in order and
/// concatenates them into ONE G-code, each plate wrapped in
/// `; ORCA_PLATE ... begin` / `end` marker lines (unknown comments for every
/// loader, including desktop OrcaSlicer and OrcaPad's own preview). The
/// per-plate `plate_name` config placeholder carries the plate's name;
/// machine start/end G-code run per plate, exactly like desktop's plate-by-
/// plate background slicing. Empty plates are skipped; every plate empty is
/// ORCA_STATUS_INVALID_MODEL. Progress is scaled across all plates; the
/// report aggregates warnings, time and bytes.
orca_result orca_plater_slice_all_to_gcode(orca_plater *plater,
                                           const char *gcode_path,
                                           orca_progress_fn progress, void *ctx,
                                           orca_slice_job *job,
                                           orca_slice_report *out_report);
orca_result orca_plater_slice_all_to_gcode_with_presets(
    orca_plater *plater, orca_presets *presets, const char *gcode_path,
    orca_progress_fn progress, void *ctx, orca_slice_job *job,
    orca_slice_report *out_report);

orca_result orca_plater_slice_to_gcode(orca_plater *plater,
                                       const char *gcode_path,
                                       orca_progress_fn progress, void *ctx,
                                       orca_slice_job *job,
                                       orca_slice_report *out_report);

orca_result orca_plater_slice_to_gcode_with_presets(
    orca_plater *plater, orca_presets *presets, const char *gcode_path,
    orca_progress_fn progress, void *ctx, orca_slice_job *job,
    orca_slice_report *out_report);

#if defined(__cplusplus)
}
#endif
