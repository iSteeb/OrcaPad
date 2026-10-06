#include "orca_bridge.h"

#include "libslic3r/ExPolygon.hpp"
#include "libslic3r/I18N.hpp"
#include "libslic3r/TriangleMesh.hpp"
#include "libslic3r/TriangleMeshSlicer.hpp"

#include <algorithm>
#include <cerrno>
#include <cmath>
#include <cstdint>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <limits>
#include <memory>
#include <mutex>
#include <new>
#include <stdexcept>
#include <string>
#include <vector>

#include <sys/stat.h>

// --- adapter: translation hook --------------------------------------
// Desktop OrcaSlicer defines I18N::translate_fn in utils.cpp (which needs
// macOS-only libproc.h) and the GUI reassigns it at startup. iOS port:
// identity default, assigned here. Upstream untouched.
namespace Slic3r { namespace I18N {
static std::string identity_translate(const char *s) { return s; }
translate_fn_type translate_fn = &identity_translate;
}}

// --- C ABI result ownership ---------------------------------------------

static orca_owned_string orcapad_empty_string() noexcept {
    return { nullptr, 0 };
}

static bool orcapad_copy_string(const char *source, orca_owned_string *out) noexcept {
    if (!out) return false;
    *out = orcapad_empty_string();
    if (!source) source = "";
    const size_t length = std::strlen(source);
    if (length == std::numeric_limits<size_t>::max() ||
        length > static_cast<size_t>(std::numeric_limits<uint64_t>::max()))
        return false;
    char *copy = static_cast<char *>(std::malloc(length + 1));
    if (!copy) return false;
    std::memcpy(copy, source, length + 1);
    out->data = copy;
    out->length = static_cast<uint64_t>(length);
    return true;
}

static orca_result orcapad_ok() noexcept {
    return { ORCA_STATUS_OK, orcapad_empty_string() };
}

static orca_result orcapad_fail(orca_status_code code, const char *operation,
                                const char *detail) noexcept {
    orca_result result { code, orcapad_empty_string() };
    if (!operation) operation = "Bridge";
    if (!detail) detail = "failure";
    const size_t operation_length = std::strlen(operation);
    const size_t detail_length = std::strlen(detail);
    if (detail_length > std::numeric_limits<size_t>::max() - 3 ||
        operation_length >
            std::numeric_limits<size_t>::max() - detail_length - 3) {
        result.code = ORCA_STATUS_OUT_OF_MEMORY;
        return result;
    }
    const size_t length = operation_length + 2 + detail_length;
    char *diagnostic = static_cast<char *>(std::malloc(length + 1));
    if (!diagnostic) {
        result.code = ORCA_STATUS_OUT_OF_MEMORY;
        return result;
    }
    std::memcpy(diagnostic, operation, operation_length);
    diagnostic[operation_length] = ':';
    diagnostic[operation_length + 1] = ' ';
    std::memcpy(diagnostic + operation_length + 2, detail, detail_length + 1);
    result.diagnostic = { diagnostic, static_cast<uint64_t>(length) };
    return result;
}

template <class Function>
static orca_result orcapad_guard(const char *operation, Function &&function) noexcept {
    try {
        return function();
    } catch (const std::bad_alloc &) {
        return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation, "allocation failed");
    } catch (const std::exception &error) {
        return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation, error.what());
    } catch (...) {
        return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                            "unknown C++ exception");
    }
}

uint32_t orca_bridge_abi_version(void) { return ORCA_BRIDGE_ABI_VERSION; }

void orca_owned_string_dispose(orca_owned_string *string) {
    if (!string) return;
    std::free(string->data);
    *string = orcapad_empty_string();
}

void orca_result_dispose(orca_result *result) {
    if (!result) return;
    orca_owned_string_dispose(&result->diagnostic);
    result->code = ORCA_STATUS_OK;
}

// --- mesh handle ------------------------------------------------------

// --- shared packing: engine z-up mesh → viewer-space (y-up) buffers -----
// Packed geometry is recentred on the object's bbox centre (x/y) so it can
// be rendered per-instance as: T(anchor) * Ry(rot_z) * S(scale), where
// anchor = instance_matrix * centre (computed in orca_plater_instance_get).
struct orcapad_packed {
    std::vector<float>    positions;        // viewer-space xyz
    std::vector<uint32_t> indices;          // triangle indices
    float                 emin[3], emax[3]; // engine-space bbox
    float                 center[2];        // engine-space xy pivot
    bool                  valid = false;
};

static void orcapad_pack(const Slic3r::TriangleMesh &mesh, orcapad_packed *out) {
    const auto &its = mesh.its;
    for (int i = 0; i < 3; ++i) { out->emin[i] = 1e30f; out->emax[i] = -1e30f; }
    for (const auto &v : its.vertices)
        for (int i = 0; i < 3; ++i) {
            float c = v(i);
            out->emin[i] = std::min(out->emin[i], c);
            out->emax[i] = std::max(out->emax[i], c);
        }
    const float cx = 0.5f * (out->emin[0] + out->emax[0]);
    const float cy = 0.5f * (out->emin[1] + out->emax[1]);
    out->center[0] = cx; out->center[1] = cy;
    out->positions.clear(); out->indices.clear();
    out->positions.reserve(its.vertices.size() * 3);
    for (const auto &v : its.vertices) {
        out->positions.push_back(v.x() - cx);
        out->positions.push_back(v.z());
        out->positions.push_back(-(v.y() - cy));
    }
    out->indices.reserve(its.indices.size() * 3);
    for (const auto &f : its.indices)
        for (int i = 0; i < 3; ++i)
            out->indices.push_back((uint32_t)f(i));
    out->valid = true;
}

static bool orcapad_fill_view(const orcapad_packed &p, orca_mesh_view *v) {
    memset(v, 0, sizeof(*v));
    const size_t position_count = p.positions.size() / 3;
    if (position_count > static_cast<size_t>(std::numeric_limits<int32_t>::max()) ||
        p.indices.size() > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
        return false;
    v->positions = p.positions.data();
    v->position_count = static_cast<int32_t>(position_count);
    v->indices = p.indices.data();
    v->index_count = static_cast<int32_t>(p.indices.size());
    v->bbox_min[0] = p.emin[0] - p.center[0];
    v->bbox_max[0] = p.emax[0] - p.center[0];
    v->bbox_min[1] = p.emin[2];
    v->bbox_max[1] = p.emax[2];
    v->bbox_min[2] = -(p.emax[1] - p.center[1]);
    v->bbox_max[2] = -(p.emin[1] - p.center[1]);
    return true;
}

struct orca_mesh {
    Slic3r::TriangleMesh mesh;       // original engine-space (z-up) mesh
    orcapad_packed       packed;     // viewer-space buffers + pivot
};

orca_result orca_stl_load(const char *path, orca_mesh **out_mesh,
                          orca_mesh_view *out_view) {
    constexpr const char *operation = "orca_stl_load";
    if (out_mesh) *out_mesh = nullptr;
    if (out_view) std::memset(out_view, 0, sizeof(*out_view));
    if (!out_mesh || !out_view)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!path || !path[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty");
    struct stat path_status;
    if (stat(path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                            "input file is not accessible");

    return orcapad_guard(operation, [&]() -> orca_result {
        auto mesh = std::make_unique<orca_mesh>();
        if (!mesh->mesh.ReadSTLFile(path))
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "STL could not be read");
        const auto &indexed = mesh->mesh.its;
        if (indexed.indices.empty() || indexed.vertices.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "mesh is empty");

        orcapad_pack(mesh->mesh, &mesh->packed);
        if (!orcapad_fill_view(mesh->packed, out_view))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "mesh exceeds ABI count range");
        *out_mesh = mesh.release();
        return orcapad_ok();
    });
}

void orca_mesh_free(orca_mesh *mesh) { delete mesh; }

orca_result orca_slice_report(orca_mesh *mesh, int32_t levels,
                              int32_t *out_levels, int32_t *out_mid_islands,
                              double *out_mid_area_mm2) {
    constexpr const char *operation = "orca_slice_report";
    if (out_levels) *out_levels = 0;
    if (out_mid_islands) *out_mid_islands = 0;
    if (out_mid_area_mm2) *out_mid_area_mm2 = 0.0;
    if (!out_levels || !out_mid_islands || !out_mid_area_mm2)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!mesh)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "mesh handle is null");
    if (levels < 1)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "levels must be positive");

    return orcapad_guard(operation, [&]() -> orca_result {
        const auto &indexed = mesh->mesh.its;
        float zmin = 1e30f, zmax = -1e30f;
        for (const auto &vertex : indexed.vertices) {
            zmin = std::min(zmin, vertex.z());
            zmax = std::max(zmax, vertex.z());
        }
        const float first_layer = 0.2f;
        std::vector<float> zs;
        zs.reserve(static_cast<size_t>(levels));
        for (int32_t index = 0; index < levels; ++index) {
            const float fraction = static_cast<float>(index + 1) /
                                   static_cast<float>(levels + 1);
            zs.push_back(zmin + first_layer +
                         fraction * ((zmax - first_layer) - zmin));
        }

        Slic3r::MeshSlicingParamsEx params;
        std::vector<Slic3r::ExPolygons> slices =
            Slic3r::slice_mesh_ex(indexed, zs, params);
        if (slices.empty())
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine returned no slice levels");
        if (slices.size() > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "slice level count exceeds ABI range");

        const size_t middle = slices.size() / 2;
        if (slices[middle].size() >
            static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "island count exceeds ABI range");
        const int32_t level_count = static_cast<int32_t>(slices.size());
        const int32_t island_count =
            static_cast<int32_t>(slices[middle].size());
        const double area_mm2 = Slic3r::area(slices[middle]);
        *out_levels = level_count;
        *out_mid_islands = island_count;
        *out_mid_area_mm2 = area_mm2;
        return orcapad_ok();
    });
}

// --- full slice pipeline ------------------------------------------------

#include "libslic3r/GCode/GCodeProcessor.hpp"
#include "libslic3r/Model.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/AppConfig.hpp"
#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/Utils.hpp"

#include <fstream>
#include <sstream>

// --- data_dir adapter ----------------------------------------------------
// Upstream defines set_data_dir/data_dir in utils.cpp (needs macOS-only
// libproc.h). Swift owns the path: the app bundle's read-only resource dir
// with the shipped profile tree (<bundle>/system/…).
namespace Slic3r {
static std::mutex  orcapad_data_dir_mutex;
static std::string orcapad_data_dir;

static bool orcapad_initialize_data_dir(const std::string &path) {
    std::lock_guard<std::mutex> lock(orcapad_data_dir_mutex);
    if (orcapad_data_dir.empty()) {
        orcapad_data_dir = path;
        return true;
    }
    return orcapad_data_dir == path;
}

void set_data_dir(const std::string &path) {
    if (!orcapad_initialize_data_dir(path))
        throw std::logic_error("OrcaBridge data directory is already initialized");
}

// Safe without locking: initialization occurs once and the string is never
// mutated afterward.
const std::string &data_dir() { return orcapad_data_dir; }

// --- utils.cpp adapters (same reason: macOS-only bits in the real TU) ----

local_encoded_string encode_path(const char *src) { return local_encoded_string(src); }

std::vector<std::string> split_string(const std::string &str, char delimiter) {
    std::vector<std::string> result;
    std::stringstream ss(str);
    std::string substr;
    while (std::getline(ss, substr, delimiter))
        result.push_back(substr);
    return result;
}

// Upstream: copy to temp + rename so targets are never half-written.
CopyFileResult copy_file(const std::string &from, const std::string &to,
                         std::string &error_message, const bool with_check) {
    std::ifstream src(from, std::ios::in | std::ios::binary);
    if (!src) {
        error_message = "OrcaBridge copy_file: cannot open " + from;
        return CopyFileResult::FAIL_CHECK_ORIGIN_NOT_OPENED;
    }
    const std::string tmp = to + ".orcapad-tmp";
    {
        std::ofstream dst(tmp, std::ios::out | std::ios::binary);
        if (!dst) {
            error_message = "OrcaBridge copy_file: cannot create " + tmp;
            return CopyFileResult::FAIL_COPY_FILE;
        }
        dst << src.rdbuf();
        if (!dst.good()) {
            error_message = "OrcaBridge copy_file: write failed " + tmp;
            return CopyFileResult::FAIL_COPY_FILE;
        }
    }
    if (with_check) {
        struct stat a, b;
        if (stat(from.c_str(), &a) != 0 || stat(tmp.c_str(), &b) != 0 || a.st_size != b.st_size) {
            error_message = "OrcaBridge copy_file: size check failed " + tmp;
            return CopyFileResult::FAIL_FILES_DIFFERENT;
        }
    }
    if (std::rename(tmp.c_str(), to.c_str()) != 0) {
        error_message = "OrcaBridge copy_file: rename failed → " + to;
        return CopyFileResult::FAIL_RENAMING;
    }
    return CopyFileResult::SUCCESS;
}

bool is_shapes_dir(const std::string &dir) {
    (void)dir; // OrcaPad ships no shapes gallery yet — nothing is a shapes dir.
    return false;
}

std::string header_gcodeviewer_generated() {
    return std::string(GCODEVIEWER_APP_NAME " ") + SoftFever_VERSION;
}

bool install_vendor_bundles_from_resources(const std::vector<std::string> &bundle_names,
                                           const std::string &resource_subdir,
                                           const std::string &data_subdir) {
    // OrcaPad adapter: data_dir() points straight at the bundled, read-only
    // resource tree — the "installation" this function performs on desktop
    // already happened at app-build time. Nothing to do; success.
    (void)bundle_names; (void)resource_subdir; (void)data_subdir;
    return true;
}
} // namespace Slic3r

// --- system preset bundle ------------------------------------------------

struct orca_presets {
    Slic3r::AppConfig app_config;
    std::unique_ptr<Slic3r::PresetBundle> bundle;

    orca_presets() : bundle(std::make_unique<Slic3r::PresetBundle>()) {}

    Slic3r::PresetCollection &collection(int32_t kind) {
        switch (kind) {
        case 0: return bundle->printers;
        case 1: return bundle->filaments;
        default: return bundle->prints;
        }
    }
};

static bool orcapad_valid_preset_kind(int32_t kind) {
    return kind >= 0 && kind <= 2;
}

static std::vector<std::string> orcapad_system_preset_names(
    const Slic3r::PresetCollection &collection) {
    std::vector<std::string> names;
    for (const Slic3r::Preset &preset : collection)
        if (preset.is_system) names.push_back(preset.name);
    std::sort(names.begin(), names.end());
    return names;
}

static bool orcapad_has_exact_system_preset(
    Slic3r::PresetCollection &collection, const char *name) {
    const Slic3r::Preset *preset = collection.find_preset(name, false, true);
    return preset && preset->is_system && preset->name == name;
}

orca_result orca_presets_new(const char *data_dir_path, orca_presets **out) {
    constexpr const char *operation = "orca_presets_new";
    if (out) *out = nullptr;
    if (!out)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!data_dir_path || !data_dir_path[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "data directory is empty");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!Slic3r::orcapad_initialize_data_dir(data_dir_path))
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "data directory differs from the initialized runtime");
        auto presets = std::make_unique<orca_presets>();
        auto substitutions = presets->bundle->load_presets(
            presets->app_config,
            Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent,
            Slic3r::PresetBundle::PresetPreferences());
        (void)substitutions;
        // OrcaPad = desktop "show all presets": vendor machines without
        // declared nozzle variants stay invisible after a headless load.
        for (auto &preset : presets->bundle->printers)
            if (preset.is_system) preset.is_visible = true;
        presets->bundle->update_compatible(
            Slic3r::PresetSelectCompatibleType::Always);
        *out = presets.release();
        return orcapad_ok();
    });
}

void orca_presets_free(orca_presets *presets) { delete presets; }

orca_result orca_presets_list_count(orca_presets *presets, int32_t kind,
                                    int32_t *out_count) {
    constexpr const char *operation = "orca_presets_list_count";
    if (out_count) *out_count = 0;
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_count)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!orcapad_valid_preset_kind(kind))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const size_t count =
            orcapad_system_preset_names(presets->collection(kind)).size();
        if (count > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "preset count exceeds ABI range");
        *out_count = static_cast<int32_t>(count);
        return orcapad_ok();
    });
}

orca_result orca_presets_list_name(orca_presets *presets, int32_t kind,
                                   int32_t index, orca_owned_string *out_name) {
    constexpr const char *operation = "orca_presets_list_name";
    if (out_name) *out_name = orcapad_empty_string();
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_name)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!orcapad_valid_preset_kind(kind))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const auto names =
            orcapad_system_preset_names(presets->collection(kind));
        if (index < 0 || static_cast<size_t>(index) >= names.size())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "preset index was not found");
        if (!orcapad_copy_string(names[static_cast<size_t>(index)].c_str(), out_name))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate preset name");
        return orcapad_ok();
    });
}

orca_result orca_presets_select(orca_presets *presets, const char *machine,
                                const char *filament, const char *process) {
    constexpr const char *operation = "orca_presets_select";
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!machine || !machine[0] || !filament || !filament[0] ||
        !process || !process[0])
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset name is empty");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (!orcapad_has_exact_system_preset(
                presets->bundle->printers, machine))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "machine preset was not found");
        if (!orcapad_has_exact_system_preset(
                presets->bundle->filaments, filament))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "filament preset was not found");
        if (!orcapad_has_exact_system_preset(
                presets->bundle->prints, process))
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "process preset was not found");

        auto candidate =
            std::make_unique<Slic3r::PresetBundle>(*presets->bundle);
        candidate->printers.select_preset_by_name(machine, false);
        candidate->update_compatible(
            Slic3r::PresetSelectCompatibleType::Always);
        candidate->filaments.select_preset_by_name(filament, false);
        candidate->prints.select_preset_by_name(process, false);
        if (candidate->printers.get_selected_preset().name != machine ||
            candidate->filaments.get_selected_preset().name != filament ||
            candidate->prints.get_selected_preset().name != process)
            return orcapad_fail(ORCA_STATUS_INVALID_CONFIGURATION, operation,
                                "preset combination is not selectable");

        presets->bundle.swap(candidate);
        return orcapad_ok();
    });
}

orca_result orca_presets_current(orca_presets *presets, int32_t kind,
                                 orca_owned_string *out_name) {
    constexpr const char *operation = "orca_presets_current";
    if (out_name) *out_name = orcapad_empty_string();
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!out_name)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!orcapad_valid_preset_kind(kind))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "preset kind is invalid");

    return orcapad_guard(operation, [&]() -> orca_result {
        const std::string &name =
            presets->collection(kind).get_selected_preset().name;
        if (name.empty())
            return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                                "no preset is selected");
        if (!orcapad_copy_string(name.c_str(), out_name))
            return orcapad_fail(ORCA_STATUS_OUT_OF_MEMORY, operation,
                                "could not allocate preset name");
        return orcapad_ok();
    });
}

// --- plater session ------------------------------------------------------

struct orca_plater {
    Slic3r::Model               model;
    std::vector<orcapad_packed> cache;   // per object; only add/delete invalidates

    orcapad_packed *packed_for(int32_t object_id) {
        if (object_id < 0 || static_cast<size_t>(object_id) >= model.objects.size())
            return nullptr;
        orcapad_packed *packed = &cache[static_cast<size_t>(object_id)];
        if (!packed->valid)
            orcapad_pack(model.objects[static_cast<size_t>(object_id)]->raw_mesh(),
                         packed);
        return packed;
    }
};

static Slic3r::ModelObject *plater_obj(orca_plater *plater, int32_t id) {
    if (!plater || id < 0 || static_cast<size_t>(id) >= plater->model.objects.size())
        return nullptr;
    return plater->model.objects[static_cast<size_t>(id)];
}

static bool orcapad_valid_transform(const orca_instance_transform &transform) {
    return std::isfinite(transform.offset_x) &&
           std::isfinite(transform.offset_y) &&
           std::isfinite(transform.offset_z) &&
           std::isfinite(transform.rotation_z) &&
           std::isfinite(transform.scale) && transform.scale > 0.0;
}

orca_result orca_plater_new(orca_plater **out) {
    constexpr const char *operation = "orca_plater_new";
    if (out) *out = nullptr;
    if (!out)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        *out = new orca_plater();
        return orcapad_ok();
    });
}

void orca_plater_free(orca_plater *plater) { delete plater; }

orca_result orca_plater_add_stl(orca_plater *plater, const char *path,
                                int32_t *out_object_id) {
    constexpr const char *operation = "orca_plater_add_stl";
    if (out_object_id) *out_object_id = -1;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!path || !path[0] || !out_object_id)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    struct stat path_status;
    if (stat(path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                            "input file is not accessible");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::Model temporary = Slic3r::Model::read_from_file(path);
        if (temporary.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "input contains no model object");
        if (plater->model.objects.size() >=
            static_cast<size_t>(std::numeric_limits<int32_t>::max()))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "object count exceeds ABI range");
        temporary.objects[0]->ensure_on_bed(false);
        plater->cache.emplace_back();
        try {
            plater->model.objects.push_back(std::move(temporary.objects[0]));
        } catch (...) {
            plater->cache.pop_back();
            throw;
        }
        temporary.objects.clear();
        *out_object_id = static_cast<int32_t>(plater->model.objects.size() - 1);
        return orcapad_ok();
    });
}

orca_result orca_plater_object_count(orca_plater *plater, int32_t *out_count) {
    constexpr const char *operation = "orca_plater_object_count";
    if (out_count) *out_count = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_count)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    const size_t count = plater->model.objects.size();
    if (count > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
        return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                            "object count exceeds ABI range");
    *out_count = static_cast<int32_t>(count);
    return orcapad_ok();
}

orca_result orca_plater_object_delete(orca_plater *plater, int32_t object_id) {
    constexpr const char *operation = "orca_plater_object_delete";
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!plater_obj(plater, object_id))
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");
    return orcapad_guard(operation, [&]() -> orca_result {
        plater->model.delete_object(static_cast<size_t>(object_id));
        plater->cache.erase(plater->cache.begin() + object_id);
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_add(orca_plater *plater, int32_t object_id,
                                     int32_t *out_instance_id) {
    constexpr const char *operation = "orca_plater_instance_add";
    if (out_instance_id) *out_instance_id = -1;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_instance_id)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    Slic3r::ModelObject *object = plater_obj(plater, object_id);
    if (!object)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");
    if (object->instances.size() >=
        static_cast<size_t>(std::numeric_limits<int32_t>::max()))
        return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                            "instance count exceeds ABI range");

    return orcapad_guard(operation, [&]() -> orca_result {
        const size_t original_count = object->instances.size();
        Slic3r::ModelInstance *instance = object->instances.empty()
            ? object->add_instance()
            : object->add_instance(*object->instances.back());
        if (!instance)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "engine did not create an instance");
        try {
            instance->set_offset(instance->get_offset() +
                                 Slic3r::Vec3d(10.0, 10.0, 0.0));
            object->invalidate_bounding_box();
        } catch (...) {
            if (object->instances.size() > original_count)
                object->delete_instance(object->instances.size() - 1);
            throw;
        }
        *out_instance_id = static_cast<int32_t>(object->instances.size() - 1);
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_delete(orca_plater *plater, int32_t object_id,
                                        int32_t instance_id) {
    constexpr const char *operation = "orca_plater_instance_delete";
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    Slic3r::ModelObject *object = plater_obj(plater, object_id);
    if (!object)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");
    if (instance_id < 0 ||
        static_cast<size_t>(instance_id) >= object->instances.size())
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "instance was not found");
    if (object->instances.size() == 1)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "last instance requires deleting the object");

    return orcapad_guard(operation, [&]() -> orca_result {
        object->delete_instance(static_cast<size_t>(instance_id));
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_count(orca_plater *plater, int32_t object_id,
                                       int32_t *out_count) {
    constexpr const char *operation = "orca_plater_instance_count";
    if (out_count) *out_count = 0;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_count)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    Slic3r::ModelObject *object = plater_obj(plater, object_id);
    if (!object)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");
    const size_t count = object->instances.size();
    if (count > static_cast<size_t>(std::numeric_limits<int32_t>::max()))
        return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                            "instance count exceeds ABI range");
    *out_count = static_cast<int32_t>(count);
    return orcapad_ok();
}

orca_result orca_plater_instance_set(orca_plater *plater, int32_t object_id,
                                     int32_t instance_id,
                                     const orca_instance_transform *transform) {
    constexpr const char *operation = "orca_plater_instance_set";
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!transform)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "transform pointer is null");
    if (!orcapad_valid_transform(*transform))
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "transform contains a non-finite value or invalid scale");
    Slic3r::ModelObject *object = plater_obj(plater, object_id);
    if (!object)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");
    if (instance_id < 0 ||
        static_cast<size_t>(instance_id) >= object->instances.size())
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "instance was not found");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::ModelInstance *instance =
            object->instances[static_cast<size_t>(instance_id)];
        instance->set_offset(Slic3r::Vec3d(
            transform->offset_x, transform->offset_y, transform->offset_z));
        instance->set_rotation(
            Slic3r::Vec3d(0.0, 0.0, transform->rotation_z));
        instance->set_scaling_factor(Slic3r::Vec3d(
            transform->scale, transform->scale, transform->scale));
        object->invalidate_bounding_box();
        return orcapad_ok();
    });
}

orca_result orca_plater_instance_get(orca_plater *plater, int32_t object_id,
                                     int32_t instance_id,
                                     orca_instance_transform *out_transform) {
    constexpr const char *operation = "orca_plater_instance_get";
    if (out_transform) std::memset(out_transform, 0, sizeof(*out_transform));
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_transform)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    Slic3r::ModelObject *object = plater_obj(plater, object_id);
    if (!object)
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");
    if (instance_id < 0 ||
        static_cast<size_t>(instance_id) >= object->instances.size())
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "instance was not found");

    return orcapad_guard(operation, [&]() -> orca_result {
        const Slic3r::ModelInstance *instance =
            object->instances[static_cast<size_t>(instance_id)];
        orca_instance_transform value {};
        value.offset_x = instance->get_offset().x();
        value.offset_y = instance->get_offset().y();
        value.offset_z = instance->get_offset().z();
        value.rotation_z = instance->get_rotation().z();
        value.scale = instance->get_scaling_factor().x();
        orcapad_packed *packed = plater->packed_for(object_id);
        if (!packed)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "packing cache is unavailable");
        const Slic3r::Transform3d matrix = instance->get_matrix();
        const Slic3r::Vec3d anchor =
            (matrix * Slic3r::Vec4d(
                packed->center[0], packed->center[1], 0.0, 1.0)).head<3>();
        value.anchor_x = anchor.x();
        value.anchor_y = anchor.y();
        value.anchor_z = anchor.z();
        *out_transform = value;
        return orcapad_ok();
    });
}

orca_result orca_plater_mesh_view(orca_plater *plater, int32_t object_id,
                                  orca_mesh_view *out_view) {
    constexpr const char *operation = "orca_plater_mesh_view";
    if (out_view) std::memset(out_view, 0, sizeof(*out_view));
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!out_view)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "output pointer is null");
    if (!plater_obj(plater, object_id))
        return orcapad_fail(ORCA_STATUS_NOT_FOUND, operation,
                            "object was not found");

    return orcapad_guard(operation, [&]() -> orca_result {
        orcapad_packed *packed = plater->packed_for(object_id);
        if (!packed)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "packing cache is unavailable");
        if (!orcapad_fill_view(*packed, out_view))
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "mesh exceeds ABI count range");
        return orcapad_ok();
    });
}

orca_result orca_plater_ensure_on_bed(orca_plater *plater) {
    constexpr const char *operation = "orca_plater_ensure_on_bed";
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    return orcapad_guard(operation, [&]() -> orca_result {
        for (Slic3r::ModelObject *object : plater->model.objects)
            object->ensure_on_bed(false);
        return orcapad_ok();
    });
}

// --- config overlays + shared slice-pipeline tail -------------------------

static void orcapad_config_overlays(Slic3r::DynamicPrintConfig &config) {
    // The preset-free compatibility path starts from raw defaults, which
    // carry physical values the desktop never emits because presets normally
    // override them. Never apply these values to a preset-backed slice.
    // filament_density = 0 in the exported gcode
    // SEGFAULTS desktop OrcaSlicer's gcode viewer (division by zero in
    // filament stats — proven by mutation test on a desktop-sliced
    // file, 2026-10-03). Generic-PLA overlay until presets land.
    config.set_key_value("filament_density", new Slic3r::ConfigOptionFloats{1.24});
    // `; nozzle_type =` (empty coEnums) round-trips as a ZERO-length
    // vector on desktop load; GCodeProcessor::update_slice_warnings()
    // then indexes nozzle_hrc_lists (sized by nozzle_type) through
    // m_filament_maps → out-of-bounds read → segfault (gdb-verified
    // 2026-10-03). Desktop presets always set a concrete value.
    // Mutate the def-created option in place — replacing it with a raw
    // ConfigOptionStrings swaps the dynamic type away from
    // ConfigOptionEnumsGenericNullable (typed accessor = bad cast).
    if (auto *nt = dynamic_cast<Slic3r::ConfigOptionStrings *>(
            config.option("nozzle_type", true)))
        nt->values = { "brass" };
}

static orca_result orcapad_run_print(const char *operation,
                                     Slic3r::Print &print,
                                     const char *gcode_path,
                                     orca_progress_fn progress, void *ctx,
                                     double *out_time_estimate_s,
                                     int64_t *out_gcode_bytes) {
    return orcapad_guard(operation, [&]() -> orca_result {
        print.set_status_callback(
            [progress, ctx](const Slic3r::PrintBase::SlicingStatus &status) {
                if (progress)
                    progress(static_cast<int32_t>(status.percent),
                             status.text.c_str(), ctx);
            });

        if (progress) progress(3, "slicing", ctx);
        print.process();

        if (progress) progress(98, "exporting gcode", ctx);
        Slic3r::GCodeProcessorResult processor_result;
        const std::string final_path =
            print.export_gcode(gcode_path, &processor_result, nullptr);
        if (final_path.empty())
            return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                "engine returned an empty G-code path");

        struct stat file_status;
        if (stat(final_path.c_str(), &file_status) != 0)
            return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                                "exported G-code could not be inspected");
        if (file_status.st_size < 0)
            return orcapad_fail(ORCA_STATUS_INTERNAL_INVARIANT, operation,
                                "exported G-code has a negative size");
        if (processor_result.print_statistics.modes.empty())
            return orcapad_fail(ORCA_STATUS_ENGINE_FAILURE, operation,
                                "engine returned no print-time estimate");

        *out_gcode_bytes = static_cast<int64_t>(file_status.st_size);
        *out_time_estimate_s =
            processor_result.print_statistics.modes.front().time;
        if (progress) progress(100, "done", ctx);
        return orcapad_ok();
    });
}

orca_result orca_slice_to_gcode(const char *stl_path, const char *gcode_path,
                                orca_progress_fn progress, void *ctx,
                                double *out_time_estimate_s,
                                int64_t *out_gcode_bytes) {
    constexpr const char *operation = "orca_slice_to_gcode";
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!stl_path || !stl_path[0] || !gcode_path || !gcode_path[0] ||
        !out_time_estimate_s || !out_gcode_bytes)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    struct stat path_status;
    if (stat(stl_path, &path_status) != 0)
        return orcapad_fail(ORCA_STATUS_IO_FAILURE, operation,
                            "input file is not accessible");

    return orcapad_guard(operation, [&]() -> orca_result {
        if (progress) progress(1, "loading model", ctx);
        Slic3r::Model model = Slic3r::Model::read_from_file(stl_path);
        if (model.objects.empty())
            return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                                "input contains no model object");

        Slic3r::DynamicPrintConfig config =
            Slic3r::DynamicPrintConfig::full_print_config();
        orcapad_config_overlays(config);

        if (progress) progress(2, "applying config", ctx);
        Slic3r::Print print;
        print.apply(model, std::move(config));
        print.is_BBL_printer() = false;
        return orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    });
}

orca_result orca_plater_slice_to_gcode(orca_plater *plater,
                                       const char *gcode_path,
                                       orca_progress_fn progress, void *ctx,
                                       double *out_time_estimate_s,
                                       int64_t *out_gcode_bytes) {
    constexpr const char *operation = "orca_plater_slice_to_gcode";
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!gcode_path || !gcode_path[0] || !out_time_estimate_s ||
        !out_gcode_bytes)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    if (plater->model.objects.empty())
        return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                            "document contains no model object");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::DynamicPrintConfig config =
            Slic3r::DynamicPrintConfig::full_print_config();
        orcapad_config_overlays(config);
        if (progress) progress(1, "applying plater", ctx);
        Slic3r::Print print;
        print.apply(plater->model, std::move(config));
        print.is_BBL_printer() = false;
        return orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    });
}

orca_result orca_plater_slice_to_gcode_with_presets(
    orca_plater *plater, orca_presets *presets, const char *gcode_path,
    orca_progress_fn progress, void *ctx, double *out_time_estimate_s,
    int64_t *out_gcode_bytes) {
    constexpr const char *operation =
        "orca_plater_slice_to_gcode_with_presets";
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!plater)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "plater handle is null");
    if (!presets)
        return orcapad_fail(ORCA_STATUS_INVALID_HANDLE, operation,
                            "presets handle is null");
    if (!gcode_path || !gcode_path[0] || !out_time_estimate_s ||
        !out_gcode_bytes)
        return orcapad_fail(ORCA_STATUS_INVALID_ARGUMENT, operation,
                            "path is empty or output pointer is null");
    if (plater->model.objects.empty())
        return orcapad_fail(ORCA_STATUS_INVALID_MODEL, operation,
                            "document contains no model object");

    return orcapad_guard(operation, [&]() -> orca_result {
        Slic3r::DynamicPrintConfig config = presets->bundle->full_config();
        if (progress) progress(1, "applying presets", ctx);
        Slic3r::Print print;
        print.apply(plater->model, std::move(config));
        print.is_BBL_printer() = presets->bundle->is_bbl_vendor();
        return orcapad_run_print(operation, print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    });
}
