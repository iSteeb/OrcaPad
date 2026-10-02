#include "orca_core.h"

#include "libslic3r/I18N.hpp"
#include "libslic3r/TriangleMesh.hpp"

#include <cerrno>
#include <cstdint>
#include <cstdio>
#include <cstring>
#include <string>

// --- adapter: translation hook --------------------------------------
// Desktop OrcaSlicer defines I18N::translate_fn in utils.cpp (which needs
// macOS-only libproc.h) and the GUI reassigns it at startup. iOS port:
// identity default, assigned here. Upstream untouched.
namespace Slic3r { namespace I18N {
static std::string identity_translate(const char *s) { return s; }
translate_fn_type translate_fn = &identity_translate;
}}

// --- generate a binary STL: 20mm cube centred on origin, sitting on z=0 ---
// All file I/O is NULL/return-value checked: engine errors surface as
// status strings, never as crashes (lesson: /tmp fopen NULL -> SIGSEGV).

static FILE *open_or_fail(const char *path, const char *mode, std::string &err) {
    FILE *f = fopen(path, mode);
    if (!f) {
        err = std::string("fopen failed for ") + path +
              " (errno " + std::to_string(errno) + ")";
    }
    return f;
}

static bool write_cube_stl(const char *path, std::string &err) {
    struct V { float x, y, z; };
    const float s = 20.f, h = s / 2;
    const V verts[8] = {
        {-h, -h, 0}, { h, -h, 0}, { h,  h, 0}, {-h,  h, 0},
        {-h, -h, s}, { h, -h, s}, { h,  h, s}, {-h,  h, s},
    };
    const int tris[12][3] = {
        {0, 3, 1}, {1, 3, 2},   // bottom
        {4, 5, 7}, {5, 6, 7},   // top
        {0, 1, 5}, {0, 5, 4},   // front
        {1, 2, 6}, {1, 6, 5},   // right
        {2, 3, 7}, {2, 7, 6},   // back
        {3, 0, 4}, {3, 4, 7},   // left
    };
    FILE *f = open_or_fail(path, "wb", err);
    if (!f) return false;
    char header[80] = {0};
    strncpy(header, "OrcaPad probe cube", 79);
    if (fwrite(header, 1, 80, f) != 80) { err = "header write failed"; fclose(f); return false; }
    uint32_t n = 12;
    if (fwrite(&n, 4, 1, f) != 1) { err = "count write failed"; fclose(f); return false; }
    for (const auto &t : tris) {
        float zero[3] = {0, 0, 0};
        if (fwrite(zero, 4, 3, f) != 3) { err = "normal write failed"; fclose(f); return false; }
        for (int i = 0; i < 3; ++i) {
            float v[3] = {verts[t[i]].x, verts[t[i]].y, verts[t[i]].z};
            if (fwrite(v, 4, 3, f) != 3) { err = "vertex write failed"; fclose(f); return false; }
        }
        uint16_t attr = 0;
        if (fwrite(&attr, 2, 1, f) != 1) { err = "attr write failed"; fclose(f); return false; }
    }
    if (fclose(f) != 0) { err = "fclose failed"; return false; }
    return true;
}

const char *orca_core_stl_probe(const char *scratch_dir, int *out_facets, float *out_volume) {
    static std::string result;
    if (!scratch_dir || !scratch_dir[0]) {
        *out_facets = -1; *out_volume = -1.f;
        return "OrcaCore: no scratch dir passed";
    }
    std::string path = std::string(scratch_dir) + "/orcapad_probe.stl";

    std::string err;
    if (!write_cube_stl(path.c_str(), err)) {
        *out_facets = -1; *out_volume = -1.f;
        result = "OrcaCore: " + err;
        return result.c_str();
    }

    try {
        Slic3r::TriangleMesh mesh;
        if (!mesh.ReadSTLFile(path.c_str())) {
            *out_facets = -1; *out_volume = -1.f;
            result = "OrcaCore: STL read FAILED";
            return result.c_str();
        }

        const auto &its = mesh.its;
        *out_facets = (int)its.indices.size();
        if (its.indices.empty() || its.vertices.empty()) {
            *out_volume = -1.f;
            result = "OrcaCore: mesh empty after read";
            return result.c_str();
        }

        // Signed volume via divergence theorem over repaired facets.
        double vol = 0.0;
        for (const auto &face : its.indices) {
            const auto &a = its.vertices[face(0)];
            const auto &b = its.vertices[face(1)];
            const auto &c = its.vertices[face(2)];
            vol += (double)a.x() * ((double)b.y() * c.z() - (double)c.y() * b.z())
                 - (double)a.y() * ((double)b.x() * c.z() - (double)c.x() * b.z())
                 + (double)a.z() * ((double)b.x() * c.y() - (double)c.x() * b.y());
        }
        *out_volume = (float)(vol / 6.0);
        result = "OrcaCore: STL load+repair ok";
        return result.c_str();
    } catch (const std::exception &e) {
        *out_facets = -1; *out_volume = -1.f;
        result = std::string("OrcaCore: C++ exception: ") + e.what();
        return result.c_str();
    } catch (...) {
        *out_facets = -1; *out_volume = -1.f;
        result = "OrcaCore: unknown C++ exception";
        return result.c_str();
    }
}
