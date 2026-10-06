#include "orca_bridge.h"

#include "libslic3r/ExPolygon.hpp"
#include "libslic3r/I18N.hpp"
#include "libslic3r/TriangleMesh.hpp"
#include "libslic3r/TriangleMeshSlicer.hpp"

#include <algorithm>
#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>
#include <vector>

// --- adapter: translation hook --------------------------------------
// Desktop OrcaSlicer defines I18N::translate_fn in utils.cpp (which needs
// macOS-only libproc.h) and the GUI reassigns it at startup. iOS port:
// identity default, assigned here. Upstream untouched.
namespace Slic3r { namespace I18N {
static std::string identity_translate(const char *s) { return s; }
translate_fn_type translate_fn = &identity_translate;
}}

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

static void orcapad_fill_view(const orcapad_packed &p, orca_mesh_view *v) {
    memset(v, 0, sizeof(*v));
    v->positions = p.positions.data();
    v->position_count = (int)(p.positions.size() / 3);
    v->indices = p.indices.data();
    v->index_count = (int)p.indices.size();
    v->bbox_min[0] = p.emin[0] - p.center[0];
    v->bbox_max[0] = p.emax[0] - p.center[0];
    v->bbox_min[1] = p.emin[2];
    v->bbox_max[1] = p.emax[2];
    v->bbox_min[2] = -(p.emax[1] - p.center[1]);
    v->bbox_max[2] = -(p.emin[1] - p.center[1]);
}

struct orca_mesh {
    Slic3r::TriangleMesh mesh;       // original engine-space (z-up) mesh
    orcapad_packed       packed;     // viewer-space buffers + pivot
};

const char *orca_stl_load(const char *path, orca_mesh **out_mesh, orca_mesh_view *out_view) {
    static std::string result;
    *out_mesh = nullptr;
    memset(out_view, 0, sizeof(*out_view));
    if (!path || !path[0]) return "OrcaCore: no path passed";

    try {
        orca_mesh *m = new orca_mesh();
        if (!m->mesh.ReadSTLFile(path)) {
            delete m;
            return "OrcaCore: STL read FAILED (bad format?)";
        }
        const auto &its = m->mesh.its;
        if (its.indices.empty() || its.vertices.empty()) {
            delete m;
            return "OrcaCore: mesh empty";
        }

        orcapad_pack(m->mesh, &m->packed);
        orcapad_fill_view(m->packed, out_view);

        *out_mesh = m;
        result = "OrcaCore: ok";
        return result.c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return "OrcaCore: unknown C++ exception";
    }
}

void orca_mesh_free(orca_mesh *mesh) { delete mesh; }

const char *orca_slice_report(orca_mesh *m, int levels,
                              int *out_levels, int *out_mid_islands, double *out_mid_area_mm2) {
    static std::string result;
    *out_levels = *out_mid_islands = 0;
    *out_mid_area_mm2 = 0.0;
    if (!m) return "OrcaCore: null mesh handle";
    if (levels < 1) levels = 1;

    try {
        const auto &its = m->mesh.its;
        float zmin = 1e30f, zmax = -1e30f;
        for (const auto &v : its.vertices) {
            zmin = std::min(zmin, v.z());
            zmax = std::max(zmax, v.z());
        }
        const float first_layer = 0.2f;
        std::vector<float> zs;
        zs.reserve((size_t)levels);
        for (int i = 0; i < levels; ++i) {
            float t = (float)(i + 1) / (float)(levels + 1); // strictly interior
            zs.push_back(zmin + first_layer + t * ((zmax - first_layer) - zmin));
        }

        Slic3r::MeshSlicingParamsEx params; // defaults
        std::vector<Slic3r::ExPolygons> slices =
            Slic3r::slice_mesh_ex(its, zs, params);

        *out_levels = (int)slices.size();
        const size_t mid = slices.size() / 2;
        *out_mid_islands = (int)slices[mid].size();
        *out_mid_area_mm2 = Slic3r::area(slices[mid]);

        result = "OrcaCore: slice ok";
        return result.c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return "OrcaCore: unknown C++ exception";
    }
}

// --- full slice pipeline ------------------------------------------------

#include "libslic3r/GCode/GCodeProcessor.hpp"
#include "libslic3r/Model.hpp"
#include "libslic3r/Print.hpp"
#include "libslic3r/PrintConfig.hpp"
#include "libslic3r/AppConfig.hpp"
#include "libslic3r/PresetBundle.hpp"
#include "libslic3r/Utils.hpp"

#include <sys/stat.h>

#include <fstream>
#include <sstream>

// --- data_dir adapter ----------------------------------------------------
// Upstream defines set_data_dir/data_dir in utils.cpp (needs macOS-only
// libproc.h). Swift owns the path: the app bundle's read-only resource dir
// with the shipped profile tree (<bundle>/system/…).
namespace Slic3r {
static std::string orcapad_data_dir;
void set_data_dir(const std::string &path) { orcapad_data_dir = path; }
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
        error_message = "OrcaCore copy_file: cannot open " + from;
        return CopyFileResult::FAIL_CHECK_ORIGIN_NOT_OPENED;
    }
    const std::string tmp = to + ".orcapad-tmp";
    {
        std::ofstream dst(tmp, std::ios::out | std::ios::binary);
        if (!dst) {
            error_message = "OrcaCore copy_file: cannot create " + tmp;
            return CopyFileResult::FAIL_COPY_FILE;
        }
        dst << src.rdbuf();
        if (!dst.good()) {
            error_message = "OrcaCore copy_file: write failed " + tmp;
            return CopyFileResult::FAIL_COPY_FILE;
        }
    }
    if (with_check) {
        struct stat a, b;
        if (stat(from.c_str(), &a) != 0 || stat(tmp.c_str(), &b) != 0 || a.st_size != b.st_size) {
            error_message = "OrcaCore copy_file: size check failed " + tmp;
            return CopyFileResult::FAIL_FILES_DIFFERENT;
        }
    }
    if (std::rename(tmp.c_str(), to.c_str()) != 0) {
        error_message = "OrcaCore copy_file: rename failed → " + to;
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
    Slic3r::AppConfig    app_config;
    Slic3r::PresetBundle bundle;
    std::string          load_errors;   // per-vendor load warnings (non-fatal)
    std::string          name_scratch;  // stable storage for list_name

    Slic3r::PresetCollection &collection(int kind) {
        switch (kind) {
        case 0: return bundle.printers;
        case 1: return bundle.filaments;
        default: return bundle.prints;
        }
    }
};

const char *orca_presets_new(const char *data_dir_path, orca_presets **out) {
    static std::string result;
    if (!out) return "OrcaCore: null out";
    *out = nullptr;
    if (!data_dir_path || !data_dir_path[0]) return "OrcaCore: null data dir";
    try {
        Slic3r::set_data_dir(data_dir_path);
        std::unique_ptr<orca_presets> p(new orca_presets());
        auto subs = p->bundle.load_presets(
            p->app_config,
            Slic3r::ForwardCompatibilitySubstitutionRule::EnableSilent,
            Slic3r::PresetBundle::PresetPreferences());
        (void)subs; // substitutions resolved silently (system presets)
        // OrcaPad = desktop "show all presets": vendor machines without
        // declared nozzle variants in their vendor json (Prusa-style, e.g.
        // Positron3D) stay invisible after a headless load and
        // select_preset_by_name rejects invisible presets (293 loaded, only
        // 29 selectable — probe-verified 2026-10-05). Flip visibility on all
        // system printers; filaments/processes are gated by compatibility,
        // re-evaluated below.
        for (auto &preset : p->bundle.printers)
            if (preset.is_system) preset.is_visible = true;
        p->bundle.update_compatible(Slic3r::PresetSelectCompatibleType::Always);
        const int machines = (int)p->bundle.printers.system_preset_names().size();
        const int filaments = (int)p->bundle.filaments.system_preset_names().size();
        const int processes = (int)p->bundle.prints.system_preset_names().size();
        result = "OrcaCore: presets ok · " + std::to_string(machines) +
                 " machines · " + std::to_string(filaments) + " filaments · " +
                 std::to_string(processes) + " processes";
        *out = p.release();
        return result.c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

void orca_presets_free(orca_presets *p) { delete p; }

const char *orca_presets_list_count(orca_presets *p, int kind, int *out_count) {
    if (!p || !out_count) return "OrcaCore: null presets/out";
    *out_count = (int)p->collection(kind).system_preset_names().size();
    return "OrcaCore: ok";
}

const char *orca_presets_list_name(orca_presets *p, int kind, int idx,
                                   const char **out_name) {
    if (!p || !out_name) return "OrcaCore: null presets/out";
    *out_name = nullptr;
    // system_preset_names() returns BY VALUE — c_str() into the temporary
    // dangles after return (garbled names in the UI). Copy into the
    // session's stable storage; the caller (under the same lock) reads it
    // before any further preset call.
    const auto names = p->collection(kind).system_preset_names();
    if (idx < 0 || idx >= (int)names.size()) return "OrcaCore: bad index";
    p->name_scratch = names[idx];
    *out_name = p->name_scratch.c_str();
    return "OrcaCore: ok";
}

const char *orca_presets_select(orca_presets *p, const char *machine,
                                const char *filament, const char *process) {
    static std::string result;
    if (!p || !machine || !filament || !process) return "OrcaCore: null args";
    try {
        // Machine first, then a compatibility pass — Positron-style processes
        // only become visible/selectable once their machine is active
        // (mirrors the desktop preset flow).
        p->bundle.printers.select_preset_by_name(machine, false);
        p->bundle.update_compatible(Slic3r::PresetSelectCompatibleType::Always);
        p->bundle.filaments.select_preset_by_name(filament, false);
        p->bundle.prints.select_preset_by_name(process, false);
        std::string miss;
        if (p->bundle.printers.get_selected_preset().name != machine) miss = machine;
        else if (p->bundle.filaments.get_selected_preset().name != filament) miss = filament;
        else if (p->bundle.prints.get_selected_preset().name != process) miss = process;
        if (!miss.empty()) {
            result = "OrcaCore: preset not found — " + miss;
            return result.c_str();
        }
        return (result = "OrcaCore: selected").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_presets_current(orca_presets *p, int kind, const char **out_name) {
    if (!p || !out_name) return "OrcaCore: null presets/out";
    const Slic3r::Preset &preset = p->collection(kind).get_selected_preset();
    *out_name = preset.name.c_str();
    return "OrcaCore: ok";
}

// --- plater session ------------------------------------------------------

struct orca_plater {
    Slic3r::Model               model;
    std::vector<orcapad_packed> cache;   // per object; only add/delete invalidates

    orcapad_packed *packed_for(int object_id) {
        if (object_id < 0 || object_id >= (int)model.objects.size()) return nullptr;
        orcapad_packed *p = &cache[object_id];
        if (!p->valid) orcapad_pack(model.objects[object_id]->raw_mesh(), p);
        return p;
    }
};

static Slic3r::ModelObject *plater_obj(orca_plater *p, int id) {
    if (!p || id < 0 || id >= (int)p->model.objects.size()) return nullptr;
    return p->model.objects[id];
}

const char *orca_plater_new(orca_plater **out) {
    if (!out) return "OrcaCore: null out";
    *out = new orca_plater();
    return "OrcaCore: plater ok";
}

void orca_plater_free(orca_plater *p) { delete p; }

const char *orca_plater_add_stl(orca_plater *p, const char *path, int *out_object_id) {
    static std::string result;
    if (out_object_id) *out_object_id = -1;
    if (!p || !path || !path[0]) return "OrcaCore: null plater/path";
    try {
        Slic3r::Model tmp = Slic3r::Model::read_from_file(path);
        if (tmp.objects.empty()) return "OrcaCore: no object in file";
        p->model.objects.push_back(std::move(tmp.objects[0]));
        tmp.objects.clear();
        p->cache.emplace_back();
        const int id = (int)p->model.objects.size() - 1;
        p->model.objects[id]->ensure_on_bed(false);
        if (out_object_id) *out_object_id = id;
        return (result = "OrcaCore: object added").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_object_count(orca_plater *p, int *out_count) {
    if (!p || !out_count) return "OrcaCore: null plater/out";
    *out_count = (int)p->model.objects.size();
    return "OrcaCore: ok";
}

const char *orca_plater_object_delete(orca_plater *p, int object_id) {
    static std::string result;
    if (!plater_obj(p, object_id)) return "OrcaCore: bad object id";
    try {
        p->model.delete_object((size_t)object_id);
        p->cache.erase(p->cache.begin() + object_id);
        return (result = "OrcaCore: object deleted").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_instance_add(orca_plater *p, int object_id, int *out_instance_id) {
    static std::string result;
    if (out_instance_id) *out_instance_id = -1;
    Slic3r::ModelObject *obj = plater_obj(p, object_id);
    if (!obj) return "OrcaCore: bad object id";
    try {
        // Copy the last instance (desktop "add instance" semantics) and
        // nudge it so both copies remain visible/selectable.
        Slic3r::ModelInstance *mi = obj->instances.empty()
            ? obj->add_instance()
            : obj->add_instance(*obj->instances.back());
        if (!mi) return (result = "OrcaCore: add_instance failed").c_str();
        mi->set_offset(mi->get_offset() + Slic3r::Vec3d(10.0, 10.0, 0.0));
        obj->invalidate_bounding_box();
        if (out_instance_id) *out_instance_id = (int)obj->instances.size() - 1;
        return (result = "OrcaCore: instance added").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_instance_delete(orca_plater *p, int object_id, int instance_id) {
    static std::string result;
    Slic3r::ModelObject *obj = plater_obj(p, object_id);
    if (!obj) return "OrcaCore: bad object id";
    if (instance_id < 0 || instance_id >= (int)obj->instances.size())
        return "OrcaCore: bad instance id";
    if (obj->instances.size() == 1)
        return "OrcaCore: last instance — delete the object instead";
    try {
        obj->delete_instance((size_t)instance_id);
        return (result = "OrcaCore: instance deleted").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_instance_count(orca_plater *p, int object_id, int *out_count) {
    Slic3r::ModelObject *obj = plater_obj(p, object_id);
    if (!obj || !out_count) return "OrcaCore: bad object id / null out";
    *out_count = (int)obj->instances.size();
    return "OrcaCore: ok";
}

const char *orca_plater_instance_set(orca_plater *p, int object_id, int instance_id,
                                     const orca_instance_transform *t) {
    static std::string result;
    Slic3r::ModelObject *obj = plater_obj(p, object_id);
    if (!obj) return "OrcaCore: bad object id";
    if (!t) return "OrcaCore: null transform";
    if (instance_id < 0 || instance_id >= (int)obj->instances.size())
        return "OrcaCore: bad instance id";
    try {
        Slic3r::ModelInstance *mi = obj->instances[instance_id];
        mi->set_offset(Slic3r::Vec3d(t->offset_x, t->offset_y, t->offset_z));
        mi->set_rotation(Slic3r::Vec3d(0.0, 0.0, t->rotation_z));
        mi->set_scaling_factor(Slic3r::Vec3d(t->scale, t->scale, t->scale));
        obj->invalidate_bounding_box();
        return (result = "OrcaCore: transform set").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_instance_get(orca_plater *p, int object_id, int instance_id,
                                     orca_instance_transform *out_t) {
    static std::string result;
    if (out_t) memset(out_t, 0, sizeof(*out_t));
    Slic3r::ModelObject *obj = plater_obj(p, object_id);
    if (!obj || !out_t) return "OrcaCore: bad object id / null out";
    if (instance_id < 0 || instance_id >= (int)obj->instances.size())
        return "OrcaCore: bad instance id";
    try {
        const Slic3r::ModelInstance *mi = obj->instances[instance_id];
        out_t->offset_x = mi->get_offset().x();
        out_t->offset_y = mi->get_offset().y();
        out_t->offset_z = mi->get_offset().z();
        out_t->rotation_z = mi->get_rotation().z();
        out_t->scale = mi->get_scaling_factor().x();
        // anchor = full instance matrix applied to the packed pivot —
        // Swift renders T(anchor_x, anchor_z, -anchor_y) * Ry(rot_z) * S.
        orcapad_packed *pk = p->packed_for(object_id);
        if (!pk) return (result = "OrcaCore: packing failed").c_str();
        const Slic3r::Transform3d m = mi->get_matrix();
        const Slic3r::Vec3d a =
            (m * Slic3r::Vec4d(pk->center[0], pk->center[1], 0.0, 1.0)).head<3>();
        out_t->anchor_x = a.x();
        out_t->anchor_y = a.y();
        out_t->anchor_z = a.z();
        return (result = "OrcaCore: transform ok").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_mesh_view(orca_plater *p, int object_id, orca_mesh_view *out_view) {
    static std::string result;
    if (!out_view) return "OrcaCore: null out";
    memset(out_view, 0, sizeof(*out_view));
    if (!p) return "OrcaCore: null plater";
    try {
        orcapad_packed *pk = p->packed_for(object_id);
        if (!pk) return (result = "OrcaCore: bad object id").c_str();
        orcapad_fill_view(*pk, out_view);
        return (result = "OrcaCore: mesh ok").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_ensure_on_bed(orca_plater *p) {
    static std::string result;
    if (!p) return "OrcaCore: null plater";
    try {
        for (Slic3r::ModelObject *obj : p->model.objects)
            obj->ensure_on_bed(false);
        return (result = "OrcaCore: on bed").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

// --- config overlays + shared slice-pipeline tail -------------------------

static void orcapad_config_overlays(Slic3r::DynamicPrintConfig &config) {
    // OrcaPad has no preset bundles yet (Phase 3); raw defaults carry
    // physical values the desktop never emits because presets always
    // override them. filament_density = 0 in the exported gcode
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

static const char *orcapad_run_print(Slic3r::Print &print, const char *gcode_path,
                                     orca_progress_fn progress, void *ctx,
                                     double *out_time_estimate_s, long *out_gcode_bytes) {
    static std::string result;
    try {
        print.set_status_callback([progress, ctx](const Slic3r::PrintBase::SlicingStatus &s) {
            if (progress) progress(s.percent, s.text.c_str(), ctx);
        });

        if (progress) progress(3, "slicing", ctx);
        print.process(); // status callback drives 0-100 through the pipeline

        if (progress) progress(98, "exporting gcode", ctx);
        Slic3r::GCodeProcessorResult processor_result;
        std::string final_path = print.export_gcode(gcode_path, &processor_result, nullptr);

        struct stat st;
        if (out_gcode_bytes) {
            *out_gcode_bytes = (stat(final_path.c_str(), &st) == 0) ? (long)st.st_size : -1;
        }
        if (out_time_estimate_s && !processor_result.print_statistics.modes.empty()) {
            *out_time_estimate_s = processor_result.print_statistics.modes.front().time;
        }

        if (progress) progress(100, "done", ctx);
        return (result = "OrcaCore: slice ok").c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_slice_to_gcode(const char *stl_path, const char *gcode_path,
                                orca_progress_fn progress, void *ctx,
                                double *out_time_estimate_s, long *out_gcode_bytes) {
    static std::string result;
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!stl_path || !gcode_path) return "OrcaCore: null path";

    try {
        if (progress) progress(1, "loading model", ctx);
        Slic3r::Model model = Slic3r::Model::read_from_file(stl_path);

        Slic3r::DynamicPrintConfig config = Slic3r::DynamicPrintConfig::full_print_config();
        orcapad_config_overlays(config);

        if (progress) progress(2, "applying config", ctx);
        Slic3r::Print print;
        print.apply(model, std::move(config));
        // Desktop GUI derives this from the preset vendor
        // (BackgroundSlicingProcess.cpp:199); the upstream member ships
        // uninitialized and libslic3r never assigns it. OrcaPad slices
        // with generic-printer settings — never BBL. An accidentally-true
        // value emits a Bambu-flavored gcode with empty printer identity.
        print.is_BBL_printer() = false;
        return orcapad_run_print(print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return "OrcaCore: unknown C++ exception";
    }
}

const char *orca_plater_slice_to_gcode(orca_plater *p, const char *gcode_path,
                                        orca_progress_fn progress, void *ctx,
                                        double *out_time_estimate_s, long *out_gcode_bytes) {
    static std::string result;
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!p || !gcode_path) return "OrcaCore: null plater/path";
    try {
        if (p->model.objects.empty()) return "OrcaCore: plater empty — nothing to slice";
        Slic3r::DynamicPrintConfig config = Slic3r::DynamicPrintConfig::full_print_config();
        orcapad_config_overlays(config);
        if (progress) progress(1, "applying plater", ctx);
        Slic3r::Print print;
        print.apply(p->model, std::move(config));
        print.is_BBL_printer() = false; // see note in orca_slice_to_gcode
        return orcapad_run_print(print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}

const char *orca_plater_slice_to_gcode_with_presets(orca_plater *p,
                                                    orca_presets *presets,
                                                    const char *gcode_path,
                                                    orca_progress_fn progress, void *ctx,
                                                    double *out_time_estimate_s,
                                                    long *out_gcode_bytes) {
    static std::string result;
    if (out_time_estimate_s) *out_time_estimate_s = -1.0;
    if (out_gcode_bytes) *out_gcode_bytes = -1;
    if (!p || !presets || !gcode_path) return "OrcaCore: null plater/presets/path";
    try {
        if (p->model.objects.empty()) return "OrcaCore: plater empty — nothing to slice";
        // Merged machine+filament+process config (inheritance resolved by
        // upstream PresetBundle), then only fill keys the presets left empty.
        Slic3r::DynamicPrintConfig config = presets->bundle.full_config();
        orcapad_config_overlays(config);
        if (progress) progress(1, "applying presets", ctx);
        Slic3r::Print print;
        print.apply(p->model, std::move(config));
        // Proper vendor detection at last — the desktop GUI's own rule.
        print.is_BBL_printer() = presets->bundle.is_bbl_vendor();
        return orcapad_run_print(print, gcode_path, progress, ctx,
                                 out_time_estimate_s, out_gcode_bytes);
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return (result = "OrcaCore: unknown C++ exception").c_str();
    }
}
