#include "orca_core.h"

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

struct orca_mesh {
    Slic3r::TriangleMesh mesh;       // original engine-space (z-up) mesh
    std::vector<float>    positions; // packed viewer-space xyz
    std::vector<uint32_t> indices;   // packed triangle indices
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

        // Engine bbox (z-up).
        float emin[3] = {1e30f, 1e30f, 1e30f}, emax[3] = {-1e30f, -1e30f, -1e30f};
        for (const auto &v : its.vertices)
            for (int i = 0; i < 3; ++i) {
                float c = v(i);
                emin[i] = std::min(emin[i], c);
                emax[i] = std::max(emax[i], c);
            }

        // Pack viewer-space positions: (x,y,z)e -> (x, z, -y)v, recentred
        // in x/y(viewer) and bed-anchored (min viewer-y = 0).
        const float cx = 0.5f * (emin[0] + emax[0]);
        const float cy = 0.5f * (emin[1] + emax[1]); // engine y -> viewer -z
        m->positions.reserve(its.vertices.size() * 3);
        for (const auto &v : its.vertices) {
            m->positions.push_back(v.x() - cx);
            m->positions.push_back(v.z());
            m->positions.push_back(-(v.y() - cy));
        }
        m->indices.reserve(its.indices.size() * 3);
        for (const auto &f : its.indices)
            for (int i = 0; i < 3; ++i)
                m->indices.push_back((uint32_t)f(i));

        out_view->positions = m->positions.data();
        out_view->position_count = (int)its.vertices.size();
        out_view->indices = m->indices.data();
        out_view->index_count = (int)m->indices.size();
        // viewer-space bbox from engine bbox
        out_view->bbox_min[0] = emin[0] - cx;  out_view->bbox_max[0] = emax[0] - cx;
        out_view->bbox_min[1] = emin[2];       out_view->bbox_max[1] = emax[2];
        out_view->bbox_min[2] = -(emax[1] - cy); out_view->bbox_max[2] = -(emin[1] - cy);

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

#include <sys/stat.h>

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
        // OrcaPad has no preset bundles yet (Phase 3); raw defaults carry
        // physical values the desktop never emits because presets always
        // override them. filament_density = 0 in the exported gcode
        // SEGFAULTS desktop OrcaSlicer's gcode viewer (division by zero in
        // filament stats — proven by mutation test on a desktop-sliced
        // file, 2026-10-03). Generic-PLA overlay until presets land.
        config.set_key_value("filament_density", new Slic3r::ConfigOptionFloats{1.24});

        if (progress) progress(2, "applying config", ctx);
        Slic3r::Print print;
        print.set_status_callback([progress, ctx](const Slic3r::PrintBase::SlicingStatus &s) {
            if (progress) progress(s.percent, s.text.c_str(), ctx);
        });
        print.apply(model, std::move(config));
        // Desktop GUI derives this from the preset vendor
        // (BackgroundSlicingProcess.cpp:199); the upstream member ships
        // uninitialized and libslic3r never assigns it. OrcaPad slices
        // with generic-printer settings — never BBL. An accidentally-true
        // value emits a Bambu-flavored gcode with empty printer identity.
        print.is_BBL_printer() = false;

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
        result = "OrcaCore: slice ok";
        return result.c_str();
    } catch (const std::exception &e) {
        return (result = std::string("OrcaCore: C++ exception: ") + e.what()).c_str();
    } catch (...) {
        return "OrcaCore: unknown C++ exception";
    }
}
