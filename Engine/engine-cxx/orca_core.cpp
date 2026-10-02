#include "orca_core.h"

#include "libslic3r/I18N.hpp"
#include "libslic3r/TriangleMesh.hpp"

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

static void write_cube_stl(const char *path) {
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
    FILE *f = fopen(path, "wb");
    char header[80] = {0};
    strncpy(header, "OrcaPad probe cube", 79);
    fwrite(header, 1, 80, f);
    uint32_t n = 12;
    fwrite(&n, 4, 1, f);
    for (const auto &t : tris) {
        float zero[3] = {0, 0, 0};
        fwrite(zero, 4, 3, f); // normal, ignored by reader
        for (int i = 0; i < 3; ++i) {
            float v[3] = {verts[t[i]].x, verts[t[i]].y, verts[t[i]].z};
            fwrite(v, 4, 3, f);
        }
        uint16_t attr = 0;
        fwrite(&attr, 2, 1, f);
    }
    fclose(f);
}

const char *orca_core_stl_probe(int *out_facets, float *out_volume) {
    static std::string result;
    const char *path = "/tmp/orcapad_probe.stl";
    write_cube_stl(path);

    Slic3r::TriangleMesh mesh;
    if (!mesh.ReadSTLFile(path)) {
        *out_facets = -1;
        *out_volume = -1.f;
        result = "OrcaCore: STL read FAILED";
        return result.c_str();
    }

    const auto &its = mesh.its;
    *out_facets = (int)its.indices.size();

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
}
