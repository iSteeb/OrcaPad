// Bridge contract tests — host executable.
//
// Exercises the C ABI exactly as the Swift facade consumes it: ABI version,
// typed failures, owned diagnostics, defensive outputs, stable engine IDs,
// monotonic revisions, revision/snapshot equality, deep-copied snapshot
// ownership, transform validation, mutation atomicity, transactional preset
// selection, progress callbacks, end-to-end slicing, and process-wide engine
// serialization.
//
// Runs via Bridge/build-host-tests.sh (same engine closure as the shipped
// iOS archive, asserts enabled).

#include "orca_bridge.h"
#include "miniz.h"

#include <atomic>
#include <cerrno>
#include <cmath>
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <string>
#include <sys/stat.h>
#include <thread>
#include <unistd.h>
#include <vector>

// Self-check that the host md5 shim is a real implementation, not a fake.
#include <openssl/md5.h>

// ---------------------------------------------------------------------------
// micro harness
// ---------------------------------------------------------------------------

static int checks = 0;
static int failures = 0;

static void fail(const char *file, int line, const char *what) {
    ++failures;
    fprintf(stderr, "FAIL %s:%d: %s\n", file, line, what);
}

#define CHECK(cond)                                                          \
    do {                                                                     \
        ++checks;                                                            \
        if (!(cond)) fail(__FILE__, __LINE__, #cond);                        \
    } while (0)

static bool eq_int(long long a, long long b, const char *ea, const char *eb,
                   const char *file, int line) {
    ++checks;
    if (a != b) {
        char buf[512];
        snprintf(buf, sizeof buf, "%s (%lld) == %s (%lld)", ea, a, eb, b);
        fail(file, line, buf);
        return false;
    }
    return true;
}
#define CHECK_EQ(a, b) eq_int((long long)(a), (long long)(b), #a, #b, __FILE__, __LINE__)

static void eq_f(double a, double b, double tol, const char *ea, const char *eb,
                 const char *file, int line) {
    ++checks;
    if (!(std::fabs(a - b) <= tol)) {
        char buf[512];
        snprintf(buf, sizeof buf, "%s (%f) ~= %s (%f) tol %f", ea, a, eb, b, tol);
        fail(file, line, buf);
    }
}
#define CHECK_NEAR(a, b, tol) eq_f((a), (b), (tol), #a, #b, __FILE__, __LINE__)

// RAII: every orca_result is disposed exactly once, including on failure.
struct ResultGuard {
    orca_result r;
    explicit ResultGuard(orca_result value) : r(value) {}
    ~ResultGuard() { orca_result_dispose(&r); }
    ResultGuard(const ResultGuard &) = delete;
    ResultGuard &operator=(const ResultGuard &) = delete;
    bool ok() const { return r.code == ORCA_STATUS_OK; }
    orca_status_code code() const { return r.code; }
    const char *diagnostic() const {
        return r.diagnostic.data ? r.diagnostic.data : "";
    }
};

#define GUARD(name, expr) ResultGuard name(expr)

static void expect_ok(const ResultGuard &guard, const char *what) {
    ++checks;
    if (guard.r.code != ORCA_STATUS_OK) {
        char buf[600];
        snprintf(buf, sizeof buf, "%s: expected OK, got status %d (%s)", what,
                 (int)guard.r.code, guard.diagnostic());
        fail(__FILE__, __LINE__, buf);
    }
}

static void expect_code(const ResultGuard &guard, orca_status_code want,
                        const char *what) {
    ++checks;
    if (guard.r.code != want) {
        char buf[600];
        snprintf(buf, sizeof buf,
                 "%s: expected status %d, got %d (%s)", what, (int)want,
                 (int)guard.r.code, guard.diagnostic());
        fail(__FILE__, __LINE__, buf);
    }
}

static void expect_owned_diagnostic(const ResultGuard &guard, const char *what) {
    ++checks;
    if (guard.r.code == ORCA_STATUS_OK) return; // only failures carry one
    if (!guard.r.diagnostic.data || guard.r.diagnostic.length == 0) {
        char buf[256];
        snprintf(buf, sizeof buf, "%s: failure carried no owned diagnostic", what);
        fail(__FILE__, __LINE__, buf);
    }
}

// ---------------------------------------------------------------------------
// fixtures
// ---------------------------------------------------------------------------

static std::string test_dir() {
    char template_path[] = "/tmp/orcapad-contract-XXXXXX";
    char *created = mkdtemp(template_path);
    if (!created) {
        fprintf(stderr, "FATAL: mkdtemp failed\n");
        exit(2);
    }
    return std::string(created);
}

// Binary STL: 20 mm cube at the origin, correct outward winding.
static std::string write_cube_stl(const std::string &dir, const char *name) {
    const std::string path = dir + "/" + name;
    FILE *file = fopen(path.c_str(), "wb");
    if (!file) {
        fprintf(stderr, "FATAL: cannot write %s\n", path.c_str());
        exit(2);
    }
    char header[80];
    memset(header, 0, sizeof header);
    fwrite(header, 1, 80, file);
    unsigned int count = 12;
    fwrite(&count, 4, 1, file);

    const float v[8][3] = {
        {0, 0, 0}, {20, 0, 0}, {20, 20, 0}, {0, 20, 0},
        {0, 0, 20}, {20, 0, 20}, {20, 20, 20}, {0, 20, 20},
    };
    const int facets[12][3] = {
        {0, 2, 1}, {0, 3, 2}, // bottom  (-z)
        {4, 5, 6}, {4, 6, 7}, // top     (+z)
        {0, 1, 5}, {0, 5, 4}, // front   (-y)
        {1, 2, 6}, {1, 6, 5}, // right   (+x)
        {2, 3, 7}, {2, 7, 6}, // back    (+y)
        {3, 0, 4}, {3, 4, 7}, // left    (-x)
    };
    for (const auto &facet : facets) {
        const float *a = v[facet[0]];
        const float *b = v[facet[1]];
        const float *c = v[facet[2]];
        float normal[3] = {
            (b[1] - a[1]) * (c[2] - a[2]) - (b[2] - a[2]) * (c[1] - a[1]),
            (b[2] - a[2]) * (c[0] - a[0]) - (b[0] - a[0]) * (c[2] - a[2]),
            (b[0] - a[0]) * (c[1] - a[1]) - (b[1] - a[1]) * (c[0] - a[0]),
        };
        float length = std::sqrt(normal[0] * normal[0] +
                                 normal[1] * normal[1] +
                                 normal[2] * normal[2]);
        if (length > 0)
            for (int axis = 0; axis < 3; ++axis) normal[axis] /= length;
        fwrite(normal, 4, 3, file);
        fwrite(a, 4, 3, file);
        fwrite(b, 4, 3, file);
        fwrite(c, 4, 3, file);
        unsigned short attribute = 0;
        fwrite(&attribute, 2, 1, file);
    }
    fclose(file);
    return path;
}

static std::string write_garbage_file(const std::string &dir) {
    const std::string path = dir + "/garbage.stl";
    FILE *file = fopen(path.c_str(), "wb");
    if (!file) exit(2);
    fprintf(file, "this is definitely not a valid STL file\n");
    fclose(file);
    return path;
}

static orca_scene_snapshot take_snapshot(orca_plater *plater) {
    orca_scene_snapshot snap;
    GUARD(guard, orca_plater_snapshot(plater, &snap));
    if (!guard.ok()) {
        fprintf(stderr, "FATAL: snapshot failed: %s\n", guard.diagnostic());
        exit(2);
    }
    return snap;
}

// Two separate 20 mm cubes (x 0..20 and x 50..70) as plain-XML AMF —
// a multi-object geometry file without placements.
static std::string write_two_cube_amf(const std::string &dir, const char *name) {
    const std::string path = dir + "/" + name;
    FILE *file = fopen(path.c_str(), "w");
    if (!file) { fprintf(stderr, "FATAL: cannot write %s\n", path.c_str()); exit(2); }
    fprintf(file, "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n<amf unit=\"millimeter\">\n");
    const int facets[12][3] = {{0,2,1},{0,3,2},{4,5,6},{4,6,7},{0,1,5},{0,5,4},
                               {1,2,6},{1,6,5},{2,3,7},{2,7,6},{3,0,4},{3,4,7}};
    for (int object = 0; object < 2; ++object) {
        const float x0 = object == 0 ? 0.f : 50.f;
        const float v[8][3] = {{x0,0,0},{x0+20,0,0},{x0+20,20,0},{x0,20,0},
                               {x0,0,20},{x0+20,0,20},{x0+20,20,20},{x0,20,20}};
        fprintf(file, " <object id=\"%d\"><mesh><vertices>\n", object);
        for (const auto &p : v)
            fprintf(file, "  <vertex><coordinates><x>%g</x><y>%g</y><z>%g</z></coordinates></vertex>\n", p[0], p[1], p[2]);
        fprintf(file, " </vertices><volume>\n");
        for (const auto &f : facets)
            fprintf(file, "  <triangle><v1>%d</v1><v2>%d</v2><v3>%d</v3></triangle>\n", f[0], f[1], f[2]);
        fprintf(file, " </volume></mesh></object>\n");
    }
    fprintf(file, "</amf>\n");
    fclose(file);
    return path;
}

// Single-object import helper for the many cube-based tests.
static orca_result import_one(orca_plater *plater, const char *path,
                              double x, double y, orca_object_id *out_id,
                              orca_revision *out_revision) {
    uint32_t count = 0;
    orca_result result = orca_plater_import_model(plater, path, x, y, out_id,
                                                  out_id ? &count : nullptr,
                                                  out_revision);
    if (result.code == ORCA_STATUS_OK) CHECK_EQ(count, 1u);
    return result;
}

static orca_revision snapshot_revision(orca_plater *plater) {
    orca_scene_snapshot snap = take_snapshot(plater);
    const orca_revision revision = snap.revision;
    orca_scene_snapshot_dispose(&snap);
    return revision;
}

static const orca_scene_object *find_object(const orca_scene_snapshot &snap,
                                            orca_object_id id) {
    for (int32_t index = 0; index < snap.object_count; ++index)
        if (snap.objects[index].id == id) return &snap.objects[index];
    return nullptr;
}

// ---------------------------------------------------------------------------
// tests
// ---------------------------------------------------------------------------

static void test_md5_shim() {
    const char *abc = "abc";
    unsigned char digest[MD5_DIGEST_LENGTH];
    MD5(reinterpret_cast<const unsigned char *>(abc), 3, digest);
    char hex[33];
    for (int i = 0; i < 16; ++i) sprintf(&hex[i * 2], "%02x", digest[i]);
    CHECK(strcmp(hex, "900150983cd24fb0d6963f7d28e17f72") == 0);

    MD5(reinterpret_cast<const unsigned char *>(""), 0, digest);
    for (int i = 0; i < 16; ++i) sprintf(&hex[i * 2], "%02x", digest[i]);
    CHECK(strcmp(hex, "d41d8cd98f00b204e9800998ecf8427e") == 0);
}

static void test_abi_version() {
    CHECK_EQ(orca_bridge_abi_version(), ORCA_BRIDGE_ABI_VERSION);
    CHECK_EQ(ORCA_BRIDGE_ABI_VERSION, 22);
}

static std::string snapshot_label(const orca_owned_string &label) {
    return label.data ? std::string(label.data, static_cast<size_t>(label.length)) : std::string();
}

// ABI v18: transactional mutations, undo/redo with stable IDs, rename,
// delete all, per-session-unique mesh revisions.
static void test_history(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;

    // empty history: typed NOT_FOUND, revision untouched
    GUARD(e1, orca_plater_undo(plater, &revision));
    expect_code(e1, ORCA_STATUS_NOT_FOUND, "undo empty");
    GUARD(e2, orca_plater_redo(plater, &revision));
    expect_code(e2, ORCA_STATUS_NOT_FOUND, "redo empty");
    GUARD(e3, orca_plater_undo(nullptr, &revision));
    expect_code(e3, ORCA_STATUS_INVALID_HANDLE, "undo null plater");
    GUARD(e4, orca_plater_clear(plater, &revision));
    expect_code(e4, ORCA_STATUS_INVALID_MODEL, "clear empty");
    CHECK_EQ(snapshot_revision(plater), 0);

    const std::string cube = write_cube_stl(dir, "history_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100, 100, &object_id, &revision));
    expect_ok(g1, "import");
    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(snap.undo_count, 1u);
    CHECK_EQ(snap.redo_count, 0u);
    CHECK(snapshot_label(snap.undo_label) == "Import");
    CHECK(snapshot_label(snap.redo_label).empty());
    const orca_instance_id instance_id = snap.objects[0].instances[0].id;
    const orca_instance_transform original = snap.objects[0].instances[0].transform;
    const uint64_t first_mesh_revision = snap.objects[0].mesh_revision;
    orca_scene_snapshot_dispose(&snap);

    // labelled transform -> undo restores it with the same IDs -> redo
    orca_instance_transform moved = original;
    moved.offset_x += 25.0;
    GUARD(g2, orca_plater_instance_set(plater, object_id, instance_id, &moved, "Move", &revision));
    expect_ok(g2, "move");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.undo_count, 2u);
    CHECK(snapshot_label(snap.undo_label) == "Move");
    orca_scene_snapshot_dispose(&snap);

    const orca_revision before_undo = revision;
    GUARD(g3, orca_plater_undo(plater, &revision));
    expect_ok(g3, "undo move");
    CHECK(revision > before_undo); // revisions advance, never rewind
    snap = take_snapshot(plater);
    CHECK_EQ(snap.revision, revision);
    CHECK_EQ(snap.undo_count, 1u);
    CHECK_EQ(snap.redo_count, 1u);
    CHECK(snapshot_label(snap.redo_label) == "Move");
    const orca_scene_object *restored = find_object(snap, object_id);
    CHECK(restored != nullptr);
    if (restored) {
        CHECK_EQ(restored->instances[0].id, instance_id);
        CHECK_NEAR(restored->instances[0].transform.offset_x, original.offset_x, 1e-9);
        CHECK_EQ(restored->mesh_revision, first_mesh_revision);
    }
    orca_scene_snapshot_dispose(&snap);

    GUARD(g4, orca_plater_redo(plater, &revision));
    expect_ok(g4, "redo move");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.undo_count, 2u);
    CHECK_EQ(snap.redo_count, 0u);
    restored = find_object(snap, object_id);
    if (restored) CHECK_NEAR(restored->instances[0].transform.offset_x, original.offset_x + 25.0, 1e-9);
    orca_scene_snapshot_dispose(&snap);

    // a new mutation after undo drops the redo branch
    GUARD(g5, orca_plater_undo(plater, &revision));
    expect_ok(g5, "undo again");
    GUARD(g6, orca_plater_instance_add(plater, object_id, nullptr, &revision));
    expect_code(g6, ORCA_STATUS_INVALID_ARGUMENT, "add instance null out");
    orca_instance_id added = 0;
    GUARD(g7, orca_plater_instance_add(plater, object_id, &added, &revision));
    expect_ok(g7, "add instance");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.redo_count, 0u);
    CHECK(snapshot_label(snap.undo_label) == "Add instance");
    orca_scene_snapshot_dispose(&snap);

    // failed mutation: no history step, document unchanged
    GUARD(g8, orca_plater_instance_delete(plater, object_id, 0x7fffffff, &revision));
    expect_code(g8, ORCA_STATUS_NOT_FOUND, "delete bogus instance");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.undo_count, 2u);
    CHECK_EQ(snap.objects[0].instance_count, 2);
    orca_scene_snapshot_dispose(&snap);

    // rename
    GUARD(g9, orca_plater_object_rename(plater, object_id, "   ", &revision));
    expect_code(g9, ORCA_STATUS_INVALID_ARGUMENT, "rename blank");
    GUARD(g10, orca_plater_object_rename(plater, object_id, nullptr, &revision));
    expect_code(g10, ORCA_STATUS_INVALID_ARGUMENT, "rename null");
    GUARD(g11, orca_plater_object_rename(plater, 0x7fffffff, "x", &revision));
    expect_code(g11, ORCA_STATUS_NOT_FOUND, "rename bogus object");
    snap = take_snapshot(plater);
    const std::string original_name = snapshot_label(snap.objects[0].name);
    CHECK(!original_name.empty());
    orca_scene_snapshot_dispose(&snap);
    GUARD(g12, orca_plater_object_rename(plater, object_id, "Bracket v2", &revision));
    expect_ok(g12, "rename");
    snap = take_snapshot(plater);
    CHECK(snapshot_label(snap.objects[0].name) == "Bracket v2");
    CHECK(snapshot_label(snap.undo_label) == "Rename");
    orca_scene_snapshot_dispose(&snap);
    GUARD(g13, orca_plater_undo(plater, &revision));
    expect_ok(g13, "undo rename");
    snap = take_snapshot(plater);
    CHECK(snapshot_label(snap.objects[0].name) == original_name);
    orca_scene_snapshot_dispose(&snap);

    // delete all + undo brings the same IDs and mesh content back
    GUARD(g14, orca_plater_clear(plater, &revision));
    expect_ok(g14, "clear");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 0);
    CHECK(snapshot_label(snap.undo_label) == "Delete all");
    orca_scene_snapshot_dispose(&snap);
    GUARD(g15, orca_plater_undo(plater, &revision));
    expect_ok(g15, "undo clear");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 1);
    restored = find_object(snap, object_id);
    CHECK(restored != nullptr);
    if (restored) {
        CHECK_EQ(restored->instance_count, 2);
        CHECK_EQ(restored->mesh_revision, first_mesh_revision);
    }
    orca_scene_snapshot_dispose(&snap);

    // a second import gets a NEW mesh revision (session-unique)
    orca_object_id second_id = 0;
    GUARD(g16, import_one(plater, cube.c_str(), 50, 50, &second_id, &revision));
    expect_ok(g16, "second import");
    snap = take_snapshot(plater);
    const orca_scene_object *second = find_object(snap, second_id);
    CHECK(second != nullptr);
    if (second) CHECK(second->mesh_revision != first_mesh_revision);
    orca_scene_snapshot_dispose(&snap);

    // bounded history: 64 steps
    for (int step = 0; step < 70; ++step) {
        GUARD(gs, orca_plater_object_rename(plater, object_id,
                                            ("name " + std::to_string(step)).c_str(), &revision));
        expect_ok(gs, "rename loop");
    }
    snap = take_snapshot(plater);
    CHECK_EQ(snap.undo_count, 64u);
    orca_scene_snapshot_dispose(&snap);
    orca_plater_free(plater);
}

static void test_document_lifecycle(const std::string &dir) {
    // null outputs / handles are typed rejections, not crashes
    GUARD(g1, orca_plater_new(nullptr));
    expect_code(g1, ORCA_STATUS_INVALID_ARGUMENT, "plater_new(null out)");

    orca_plater *plater = nullptr;
    GUARD(g2, orca_plater_new(&plater));
    expect_ok(g2, "plater_new");
    CHECK(plater != nullptr);

    orca_scene_snapshot snap;
    GUARD(g3, orca_plater_snapshot(nullptr, &snap));
    expect_code(g3, ORCA_STATUS_INVALID_HANDLE, "snapshot(null plater)");
    GUARD(g4, orca_plater_snapshot(plater, nullptr));
    expect_code(g4, ORCA_STATUS_INVALID_ARGUMENT, "snapshot(null out)");

    // empty document: revision 0, no objects, valid document identity
    orca_scene_snapshot empty;
    GUARD(g5, orca_plater_snapshot(plater, &empty));
    expect_ok(g5, "snapshot empty");
    CHECK_EQ(empty.revision, 0);
    CHECK_EQ(empty.object_count, 0);
    CHECK(empty.document_id != 0);
    orca_scene_snapshot_dispose(&empty);
    orca_scene_snapshot_dispose(&empty); // idempotent double dispose
    orca_scene_snapshot_dispose(nullptr); // null-safe

    // slicing an empty document is a typed failure
    orca_slice_report empty_report;
    GUARD(g6, orca_plater_slice_to_gcode(plater, (dir + "/empty.gcode").c_str(),
                                         nullptr, nullptr, nullptr,
                                         &empty_report));
    expect_code(g6, ORCA_STATUS_INVALID_MODEL, "slice empty document");
    expect_owned_diagnostic(g6, "slice empty document");

    orca_plater_free(nullptr); // null-safe
    orca_plater_free(plater);
}

static void test_add_failures(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");

    orca_object_id object_id = 0;
    orca_revision revision = 0;

    // null handle
    GUARD(g1, import_one(nullptr, "/x.stl", 100.0, 100.0, &object_id, &revision));
    expect_code(g1, ORCA_STATUS_INVALID_HANDLE, "add_stl(null plater)");

    // empty path and null outputs
    GUARD(g2, import_one(plater, "", 100.0, 100.0, &object_id, &revision));
    expect_code(g2, ORCA_STATUS_INVALID_ARGUMENT, "add_stl(empty path)");
    GUARD(g3, import_one(plater, "/x.stl", 100.0, 100.0, nullptr, &revision));
    expect_code(g3, ORCA_STATUS_INVALID_ARGUMENT, "add_stl(null object out)");
    GUARD(g4, import_one(plater, "/x.stl", 100.0, 100.0, &object_id, nullptr));
    expect_code(g4, ORCA_STATUS_INVALID_ARGUMENT, "add_stl(null revision out)");

    // missing file
    GUARD(g5, import_one(plater, (dir + "/missing.stl").c_str(),
                                  100.0, 100.0, &object_id, &revision));
    expect_code(g5, ORCA_STATUS_IO_FAILURE, "add_stl(missing file)");
    expect_owned_diagnostic(g5, "add_stl(missing file)");

    // garbage input: typed loud failure, either model or engine level
    const std::string garbage = write_garbage_file(dir);
    GUARD(g6, import_one(plater, garbage.c_str(), 100.0, 100.0, &object_id,
                                  &revision));
    ++checks;
    if (g6.ok()) {
        fail(__FILE__, __LINE__, "add_stl(garbage) must fail");
    } else {
        expect_owned_diagnostic(g6, "add_stl(garbage)");
        CHECK(g6.code() == ORCA_STATUS_INVALID_MODEL ||
              g6.code() == ORCA_STATUS_ENGINE_FAILURE);
    }

    // no failure may advance the document revision
    CHECK_EQ(snapshot_revision(plater), 0);
    orca_plater_free(plater);
}

static void test_stable_ids_and_revisions(const std::string &dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube.stl");

    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");

    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "add cube");
    CHECK(object_id != 0);
    CHECK_EQ(revision, 1); // first successful mutation → revision 1

    // snapshot matches the mutation's revision and describes the cube
    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(snap.revision, revision);
    CHECK_EQ(snap.object_count, 1);
    const orca_scene_object *object = find_object(snap, object_id);
    CHECK(object != nullptr);
    if (object) {
        CHECK(object->id == object_id);
        CHECK(object->name.data != nullptr && object->name.length > 0);
        CHECK_EQ(strlen(object->name.data), object->name.length);
        CHECK(object->position_count >= 8);
        CHECK_EQ(object->index_count, 36); // 12 triangles
        CHECK_EQ(object->instance_count, 1);
        CHECK(object->instances[0].id != 0);
        // Centered import: the mesh bbox is centered on the origin and the
        // instance sits at the caller's bed center (100, 100).
        CHECK_NEAR(object->bbox_min[0], -10.0, 0.01);
        CHECK_NEAR(object->bbox_min[1], -10.0, 0.01);
        CHECK_NEAR(object->bbox_min[2], -10.0, 0.01);
        CHECK_NEAR(object->bbox_max[0], 10.0, 0.01);
        CHECK_NEAR(object->bbox_max[1], 10.0, 0.01);
        CHECK_NEAR(object->bbox_max[2], 10.0, 0.01);
        CHECK_NEAR(object->pivot[0], 0.0, 0.01);
        CHECK_NEAR(object->pivot[1], 0.0, 0.01);
        const orca_instance_transform &t = object->instances[0].transform;
        CHECK_NEAR(t.offset_x, 100.0, 0.01);
        CHECK_NEAR(t.offset_y, 100.0, 0.01);
        // z is lifted by ensure_on_bed: the mesh bbox is z-centered (-10..10),
        // so the instance offset raises the bottom onto the bed (+10).
        CHECK_NEAR(t.offset_z, 10.0, 0.01);
        CHECK_NEAR(t.scale_x, 1.0, 1e-9);
        CHECK_NEAR(t.scale_y, 1.0, 1e-9);
        CHECK_NEAR(t.scale_z, 1.0, 1e-9);
        CHECK_NEAR(t.rotation_x, 0.0, 1e-9);
        CHECK_NEAR(t.rotation_y, 0.0, 1e-9);
        const uint64_t mesh_revision = object->mesh_revision;
        CHECK(mesh_revision != 0);
        const orca_document_id document_id = snap.document_id;
        const orca_instance_id instance_id = object->instances[0].id;
        const double original_offset_x = t.offset_x;

        // transform set: revision +1, IDs and mesh revision unchanged
        orca_instance_transform moved = t;
        moved.offset_x = original_offset_x + 5.0;
        orca_revision revision2 = 0;
        GUARD(g2, orca_plater_instance_set(plater, object_id, instance_id,
                                           &moved, nullptr, &revision2));
        expect_ok(g2, "set transform");
        CHECK_EQ(revision2, 2);

        orca_scene_snapshot snap2 = take_snapshot(plater);
        CHECK_EQ(snap2.revision, revision2);
        const orca_scene_object *object2 = find_object(snap2, object_id);
        CHECK(object2 != nullptr);
        if (object2) {
            CHECK_EQ(object2->instances[0].id, instance_id);
            CHECK_EQ(object2->mesh_revision, mesh_revision);
            CHECK_NEAR(object2->instances[0].transform.offset_x,
                       original_offset_x + 5.0, 1e-9);
        }

        // add instance: new engine identity, revision +1
        orca_instance_id second_instance = 0;
        orca_revision revision3 = 0;
        GUARD(g3, orca_plater_instance_add(plater, object_id,
                                           &second_instance, &revision3));
        expect_ok(g3, "add instance");
        CHECK(second_instance != 0);
        CHECK(second_instance != instance_id);
        CHECK_EQ(revision3, 3);

        // delete that instance: revision +1, first instance identity kept
        orca_revision revision4 = 0;
        GUARD(g4, orca_plater_instance_delete(plater, object_id,
                                              second_instance, &revision4));
        expect_ok(g4, "delete instance");
        CHECK_EQ(revision4, 4);
        orca_scene_snapshot snap3 = take_snapshot(plater);
        CHECK_EQ(snap3.revision, revision4);
        const orca_scene_object *object3 = find_object(snap3, object_id);
        CHECK(object3 != nullptr);
        if (object3) {
            CHECK_EQ(object3->instance_count, 1);
            CHECK_EQ(object3->instances[0].id, instance_id);
        }

        // ensure-on-bed: revision +1, document/object/instance IDs preserved
        orca_revision revision5 = 0;
        GUARD(g5, orca_plater_ensure_on_bed(plater, &revision5));
        expect_ok(g5, "ensure on bed");
        CHECK_EQ(revision5, 5);
        orca_scene_snapshot snap4 = take_snapshot(plater);
        CHECK_EQ(snap4.revision, revision5);
        CHECK(snap4.document_id == document_id);
        const orca_scene_object *object4 = find_object(snap4, object_id);
        CHECK(object4 != nullptr);
        if (object4) {
            CHECK_EQ(object4->id, object_id);
            CHECK_EQ(object4->instances[0].id, instance_id);
        }
        orca_scene_snapshot_dispose(&snap4);
        orca_scene_snapshot_dispose(&snap3);
        orca_scene_snapshot_dispose(&snap2);
    }

    // deleting the last instance is rejected atomically
    orca_scene_snapshot snap5 = take_snapshot(plater);
    const orca_scene_object *last = find_object(snap5, object_id);
    CHECK(last != nullptr && last->instance_count == 1);
    orca_revision before = snap5.revision;
    orca_instance_id last_instance =
        last ? last->instances[0].id : 0;
    orca_revision revision6 = 99;
    GUARD(g6, orca_plater_instance_delete(plater, object_id, last_instance,
                                          &revision6));
    expect_code(g6, ORCA_STATUS_INVALID_ARGUMENT, "delete last instance");
    CHECK_EQ(snapshot_revision(plater), before); // no partial mutation
    orca_scene_snapshot_dispose(&snap5);

    // object deletion succeeds and bumps the revision once
    orca_revision revision7 = 0;
    GUARD(g7, orca_plater_object_delete(plater, object_id, &revision7));
    expect_ok(g7, "delete object");
    CHECK_EQ(revision7, before + 1);

    orca_scene_snapshot_dispose(&snap);
    orca_plater_free(plater);
}

static void test_not_found_and_validation(const std::string &dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube2.stl");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");

    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "add cube");
    const orca_revision baseline = revision;

    orca_scene_snapshot snap = take_snapshot(plater);
    const orca_instance_id instance = snap.objects[0].instances[0].id;
    const orca_instance_transform valid =
        snap.objects[0].instances[0].transform;
    orca_scene_snapshot_dispose(&snap);

    // NOT FOUND family
    orca_revision out_revision = 99;
    GUARD(g2, orca_plater_object_delete(plater, 0x7fffffffffff, &out_revision));
    expect_code(g2, ORCA_STATUS_NOT_FOUND, "delete bogus object");
    GUARD(g3, orca_plater_object_delete(plater, 0, &out_revision));
    expect_code(g3, ORCA_STATUS_NOT_FOUND, "delete zero object");
    orca_instance_id ignored_instance = 0;
    GUARD(g4, orca_plater_instance_add(plater, 0x7fffffffffff,
                                       &ignored_instance, &out_revision));
    expect_code(g4, ORCA_STATUS_NOT_FOUND, "add instance bogus object");
    GUARD(g5, orca_plater_instance_delete(plater, object_id,
                                          0x7fffffffffff, &out_revision));
    expect_code(g5, ORCA_STATUS_NOT_FOUND, "delete bogus instance");
    GUARD(g6, orca_plater_instance_set(plater, object_id, 0x7fffffffffff,
                                       &valid, nullptr, &out_revision));
    expect_code(g6, ORCA_STATUS_NOT_FOUND, "set transform bogus instance");

    // INVALID ARGUMENT family: bad transforms
    orca_instance_transform bad = valid;
    bad.offset_x = std::nan("");
    GUARD(g7, orca_plater_instance_set(plater, object_id, instance, &bad, nullptr,
                                       &out_revision));
    expect_code(g7, ORCA_STATUS_INVALID_ARGUMENT, "set NaN offset");
    bad = valid;
    bad.scale_y = 0.0;
    GUARD(g8, orca_plater_instance_set(plater, object_id, instance, &bad, nullptr,
                                       &out_revision));
    expect_code(g8, ORCA_STATUS_INVALID_ARGUMENT, "set zero scale");
    bad = valid;
    bad.scale_z = std::nan("");
    GUARD(g9, orca_plater_instance_set(plater, object_id, instance, &bad, nullptr,
                                       &out_revision));
    expect_code(g9, ORCA_STATUS_INVALID_ARGUMENT, "set NaN scale");
    bad = valid;
    bad.rotation_z = HUGE_VAL;
    GUARD(g10, orca_plater_instance_set(plater, object_id, instance, &bad, nullptr,
                                        &out_revision));
    expect_code(g10, ORCA_STATUS_INVALID_ARGUMENT, "set infinite rotation");
    GUARD(g11, orca_plater_instance_set(plater, object_id, instance, nullptr, nullptr,
                                        &out_revision));
    expect_code(g11, ORCA_STATUS_INVALID_ARGUMENT, "set null transform");

    // no rejection may advance the revision
    CHECK_EQ(snapshot_revision(plater), baseline);
    orca_plater_free(plater);
}

// Instance-space min z of an object's mesh under its engine matrix.
static double instance_min_z(const orca_scene_object &object, const double *m) {
    double lowest = 1e300;
    for (int32_t i = 0; i < object.position_count; ++i) {
        const float *p = object.positions + static_cast<size_t>(i) * 3;
        const double z = m[2] * p[0] + m[6] * p[1] + m[10] * p[2] + m[14];
        if (z < lowest) lowest = z;
    }
    return lowest;
}

// ABI v19: volumes (parts / modifiers / negative volumes), split to
// objects / parts, shape objects and shape volumes.
static void test_volumes(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;

    const std::string cube = write_cube_stl(dir, "vol_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100, 100, &object_id, &revision));
    expect_ok(g1, "import cube");
    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(snap.objects[0].volume_count, 1);
    CHECK_EQ(snap.objects[0].volumes[0].type, ORCA_VOLUME_PART);
    CHECK_EQ(snap.objects[0].volumes[0].positions, nullptr);
    CHECK_EQ(snap.objects[0].volumes[0].indices, nullptr);
    CHECK(snap.objects[0].volumes[0].id != 0);
    CHECK(snap.objects[0].volumes[0].bbox_max[2] > snap.objects[0].volumes[0].bbox_min[2]);
    const orca_instance_id instance_id = snap.objects[0].instances[0].id;
    const uint64_t base_mesh_revision = snap.objects[0].mesh_revision;
    const double base_z = snap.objects[0].instances[0].transform.offset_z;
    orca_scene_snapshot_dispose(&snap);

    // --- shape object (desktop Add Primitive) -----------------------------
    orca_object_id shape_id = 0;
    GUARD(e1, orca_plater_add_shape_object(plater, ORCA_SHAPE_SLAB, 20, 100, 100,
                                           &shape_id, &revision));
    expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "slab is not an object shape");
    GUARD(e2, orca_plater_add_shape_object(plater, 99, 20, 100, 100, &shape_id, &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "bogus shape");
    GUARD(g2, orca_plater_add_shape_object(plater, ORCA_SHAPE_CYLINDER, 25, 60, 60,
                                           &shape_id, &revision));
    expect_ok(g2, "add shape object");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 2);
    const orca_scene_object *shape = find_object(snap, shape_id);
    CHECK(shape != nullptr);
    if (shape) {
        CHECK(snapshot_label(shape->name) == "Cylinder");
        CHECK_EQ(shape->instances[0].transform.offset_x, 60.0);
        CHECK_EQ(shape->instances[0].transform.offset_y, 60.0);
        // rest on bed: transformed bbox touches z = 0
        CHECK_NEAR(instance_min_z(*shape, shape->instances[0].matrix), 0.0, 1e-6);
        CHECK_EQ(shape->volume_count, 1);
    }
    orca_scene_snapshot_dispose(&snap);
    GUARD(g3, orca_plater_object_delete(plater, shape_id, &revision));
    expect_ok(g3, "delete shape object");

    // --- shape volume (desktop Add Modifier / Part / Negative volume) -----
    orca_volume_id modifier_id = 0;
    GUARD(e3, orca_plater_volume_add_shape(plater, 0x7fffffff, instance_id,
                                           ORCA_VOLUME_MODIFIER, ORCA_SHAPE_CUBE, 20,
                                           &modifier_id, &revision));
    expect_code(e3, ORCA_STATUS_NOT_FOUND, "add volume to bogus object");
    GUARD(e4, orca_plater_volume_add_shape(plater, object_id, instance_id, 99,
                                           ORCA_SHAPE_CUBE, 20, &modifier_id, &revision));
    expect_code(e4, ORCA_STATUS_INVALID_ARGUMENT, "add volume with bogus type");
    GUARD(g4, orca_plater_volume_add_shape(plater, object_id, instance_id,
                                           ORCA_VOLUME_MODIFIER, ORCA_SHAPE_CUBE, 20,
                                           &modifier_id, &revision));
    expect_ok(g4, "add modifier cube");
    snap = take_snapshot(plater);
    const orca_scene_object *host = find_object(snap, object_id);
    CHECK(host != nullptr);
    if (host) {
        CHECK_EQ(host->volume_count, 2);
        CHECK_EQ(host->volumes[1].type, ORCA_VOLUME_MODIFIER);
        CHECK(modifier_id != 0);
        CHECK(host->volumes[1].id == modifier_id);
        CHECK(snapshot_label(host->volumes[1].name) == "Generic-Cube");
        CHECK(host->volumes[1].positions != nullptr);
        CHECK(host->volumes[1].indices != nullptr);
        CHECK(host->volumes[1].index_count >= 36); // 12 faces x 3
        CHECK(host->mesh_revision != base_mesh_revision);
        // merged part mesh unchanged: same object bounds
        CHECK_NEAR(host->instances[0].transform.offset_z, base_z, 1e-9);
    }
    orca_scene_snapshot_dispose(&snap);

    // undo restores the single-part object (mesh revision goes back)
    GUARD(g5, orca_plater_undo(plater, &revision));
    expect_ok(g5, "undo add modifier");
    snap = take_snapshot(plater);
    host = find_object(snap, object_id);
    if (host) {
        CHECK_EQ(host->volume_count, 1);
        CHECK_EQ(host->mesh_revision, base_mesh_revision);
    }
    orca_scene_snapshot_dispose(&snap);
    GUARD(g6, orca_plater_redo(plater, &revision));
    expect_ok(g6, "redo add modifier");

    // --- volume rename / type / delete ------------------------------------
    GUARD(e5, orca_plater_volume_rename(plater, object_id, modifier_id, "  ", &revision));
    expect_code(e5, ORCA_STATUS_INVALID_ARGUMENT, "blank volume rename");
    GUARD(g7, orca_plater_volume_rename(plater, object_id, modifier_id, "My modifier", &revision));
    expect_ok(g7, "volume rename");
    snap = take_snapshot(plater);
    host = find_object(snap, object_id);
    if (host) CHECK(snapshot_label(host->volumes[1].name) == "My modifier");
    orca_scene_snapshot_dispose(&snap);

    GUARD(g8, orca_plater_volume_set_type(plater, object_id, modifier_id,
                                          ORCA_VOLUME_NEGATIVE, &revision));
    expect_ok(g8, "modifier -> negative volume");
    snap = take_snapshot(plater);
    host = find_object(snap, object_id);
    if (host) CHECK_EQ(host->volumes[1].type, ORCA_VOLUME_NEGATIVE);
    orca_scene_snapshot_dispose(&snap);

    // last solid part may not be retyped or deleted
    orca_volume_id part_id = 0;
    snap = take_snapshot(plater);
    host = find_object(snap, object_id);
    if (host) part_id = host->volumes[0].id;
    orca_scene_snapshot_dispose(&snap);
    GUARD(e6, orca_plater_volume_set_type(plater, object_id, part_id,
                                          ORCA_VOLUME_MODIFIER, &revision));
    expect_code(e6, ORCA_STATUS_INVALID_ARGUMENT, "retype last solid part");
    GUARD(e7, orca_plater_volume_delete(plater, object_id, part_id, &revision));
    expect_code(e7, ORCA_STATUS_INVALID_ARGUMENT, "delete last solid part");
    GUARD(g9, orca_plater_volume_delete(plater, object_id, modifier_id, &revision));
    expect_ok(g9, "delete modifier");
    snap = take_snapshot(plater);
    host = find_object(snap, object_id);
    if (host) CHECK_EQ(host->volume_count, 1);
    orca_scene_snapshot_dispose(&snap);

    // --- volume from file (desktop Load... part) ---------------------------
    write_garbage_file(dir);
    const std::string two_cubes = write_two_cube_amf(dir, "vol_two.amf");
    orca_volume_id file_part = 0;
    GUARD(e8, orca_plater_volume_add_file(plater, object_id, ORCA_VOLUME_PART,
                                          (dir + "/garbage.stl").c_str(),
                                          &file_part, &revision));
    expect_code(e8, ORCA_STATUS_ENGINE_FAILURE, "garbage part file");
    GUARD(g10, orca_plater_volume_add_file(plater, object_id, ORCA_VOLUME_PART,
                                           two_cubes.c_str(), &file_part, &revision));
    expect_ok(g10, "add two-cube part");
    snap = take_snapshot(plater);
    host = find_object(snap, object_id);
    CHECK(host != nullptr);
    if (host) {
        CHECK_EQ(host->volume_count, 2);
        CHECK_EQ(host->volumes[1].type, ORCA_VOLUME_PART);
        // merged object mesh now covers both disjoint cubes: wide bounds
        CHECK(host->bbox_max[0] - host->bbox_min[0] > 60.0);
    }
    orca_scene_snapshot_dispose(&snap);

    // --- split to objects (two disjoint bodies) ----------------------------
    GUARD(e9, orca_plater_split_objects(plater, object_id, &shape_id, nullptr, &revision));
    expect_code(e9, ORCA_STATUS_INVALID_ARGUMENT, "split with null count");
    uint32_t split_count = 0;
    orca_object_id first_split = 0;
    GUARD(g11, orca_plater_split_objects(plater, object_id, &first_split,
                                         &split_count, &revision));
    expect_ok(g11, "split two-body object");
    CHECK_EQ(split_count, 2u);
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 2);
    CHECK(find_object(snap, object_id) == nullptr);
    if (const orca_scene_object *split_obj = find_object(snap, first_split))
        CHECK_NEAR(instance_min_z(*split_obj, split_obj->instances[0].matrix), 0.0, 1e-6);
    orca_scene_snapshot_dispose(&snap);
    // undo split: original object with 2 volumes returns
    GUARD(g12, orca_plater_undo(plater, &revision));
    expect_ok(g12, "undo split to objects");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 1);
    host = find_object(snap, object_id);
    if (host) CHECK_EQ(host->volume_count, 2);
    orca_scene_snapshot_dispose(&snap);

    // --- split to parts -----------------------------------------------------
    uint32_t parts = 0;
    GUARD(g13, orca_plater_split_parts(plater, object_id, file_part, &parts, &revision));
    expect_ok(g13, "split part to parts");
    CHECK_EQ(parts, 2u);
    snap = take_snapshot(plater);
    host = find_object(snap, object_id);
    if (host) {
        CHECK_EQ(host->volume_count, 3);
        // both new parts are solid
        int solid = 0;
        for (int i = 0; i < host->volume_count; ++i)
            if (host->volumes[i].type == ORCA_VOLUME_PART) ++solid;
        CHECK_EQ(solid, 3);
    }
    orca_scene_snapshot_dispose(&snap);

    // single-body object cannot be split
    GUARD(g14, orca_plater_object_delete(plater, object_id, &revision));
    expect_ok(g14, "delete object");
    GUARD(g15, import_one(plater, cube.c_str(), 90, 90, &object_id, &revision));
    expect_ok(g15, "reimport single cube");
    GUARD(e10, orca_plater_split_objects(plater, object_id, &first_split,
                                         &split_count, &revision));
    expect_code(e10, ORCA_STATUS_INVALID_MODEL, "single body cannot split to objects");
    GUARD(e11, orca_plater_split_parts(plater, object_id, 0, &parts, &revision));
    expect_code(e11, ORCA_STATUS_INVALID_MODEL, "single body cannot split to parts");

    orca_plater_free(plater);
}

// ABI v20: mirroring (left-handed instances in snapshots) and the
// copy / paste clipboard.
static void test_mirror_clipboard(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "mirror_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100, 100, &object_id, &revision));
    expect_ok(g1, "import");

    // paste with an empty clipboard
    orca_object_id pasted_id = 0;
    GUARD(e1, orca_plater_object_paste(plater, 60, 60, &pasted_id, &revision));
    expect_code(e1, ORCA_STATUS_NOT_FOUND, "paste empty clipboard");

    // copy / paste
    GUARD(g2, orca_plater_object_copy(plater, object_id));
    expect_ok(g2, "copy");
    GUARD(g3, orca_plater_object_paste(plater, 60, 60, &pasted_id, &revision));
    expect_ok(g3, "paste");
    CHECK(pasted_id != 0 && pasted_id != object_id);
    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 2);
    CHECK(find_object(snap, pasted_id) != nullptr);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g4, orca_plater_undo(plater, &revision));
    expect_ok(g4, "undo paste");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 1);
    orca_scene_snapshot_dispose(&snap);

    // mirror
    orca_instance_id instance_id = 0;
    snap = take_snapshot(plater);
    instance_id = snap.objects[0].instances[0].id;
    CHECK_EQ(snap.objects[0].instances[0].mirrored, 0);
    const double matrix_before[16] = {
        snap.objects[0].instances[0].matrix[0], snap.objects[0].instances[0].matrix[1],
        snap.objects[0].instances[0].matrix[4], snap.objects[0].instances[0].matrix[5],
        snap.objects[0].instances[0].matrix[8], snap.objects[0].instances[0].matrix[9],
        snap.objects[0].instances[0].matrix[12], snap.objects[0].instances[0].matrix[13]};
    (void) matrix_before;
    orca_scene_snapshot_dispose(&snap);
    GUARD(e2, orca_plater_instance_mirror(plater, object_id, instance_id, 3, &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "mirror bogus axis");
    GUARD(g5, orca_plater_instance_mirror(plater, object_id, instance_id, 0, &revision));
    expect_ok(g5, "mirror X");
    snap = take_snapshot(plater);
    const orca_scene_instance &mirrored = snap.objects[0].instances[0];
    CHECK_EQ(mirrored.mirrored, 1);
    // transform stays representable (positive scales)
    CHECK(mirrored.transform.scale_x > 0 && mirrored.transform.scale_y > 0);
    // matrix determinant < 0 (left handed)
    const double *m = mirrored.matrix;
    const double det =
        m[0] * (m[5] * m[10] * m[15] + m[6] * m[11] * m[13] + m[7] * m[9] * m[14]
             - m[7] * m[10] * m[13] - m[6] * m[9] * m[15] - m[5] * m[11] * m[14])
      - m[4] * (m[1] * m[10] * m[15] + m[2] * m[11] * m[13] + m[3] * m[9] * m[14]
             - m[3] * m[10] * m[13] - m[2] * m[9] * m[15] - m[1] * m[11] * m[14])
      + m[8] * (m[1] * m[6] * m[15] + m[2] * m[7] * m[13] + m[3] * m[5] * m[14]
             - m[3] * m[6] * m[13] - m[2] * m[5] * m[15] - m[1] * m[7] * m[14])
      - m[12] * (m[1] * m[6] * m[11] + m[2] * m[7] * m[9] + m[3] * m[5] * m[10]
              - m[3] * m[6] * m[9] - m[2] * m[5] * m[11] - m[1] * m[7] * m[10]);
    CHECK(det < 0.0);
    orca_scene_snapshot_dispose(&snap);
    // mirror again toggles back
    GUARD(g6, orca_plater_instance_mirror(plater, object_id, instance_id, 0, &revision));
    expect_ok(g6, "mirror X again");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.objects[0].instances[0].mirrored, 0);
    orca_scene_snapshot_dispose(&snap);
    // undo restores the mirrored state
    GUARD(g7, orca_plater_undo(plater, &revision));
    expect_ok(g7, "undo unmirror");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.objects[0].instances[0].mirrored, 1);
    orca_scene_snapshot_dispose(&snap);

    orca_plater_free(plater);
}
// ABI v21: group (multi-selection) transforms, one mutation / undo step.
static void test_group_transforms(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "group_cube.stl");
    orca_object_id a = 0, b = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 80, 80, &a, &revision));
    expect_ok(g1, "import a");
    GUARD(g2, import_one(plater, cube.c_str(), 140, 80, &b, &revision));
    expect_ok(g2, "import b");
    orca_scene_snapshot snap = take_snapshot(plater);
    const orca_object_id objects[2] = { a, b };
    const orca_instance_id instances[2] = {
        snap.objects[0].instances[0].id, snap.objects[1].instances[0].id
    };
    orca_instance_transform transforms[2] = {
        snap.objects[0].instances[0].transform,
        snap.objects[1].instances[0].transform
    };
    const uint32_t undo_before = snap.undo_count;
    const double ax = snap.objects[0].instances[0].transform.offset_x;
    orca_scene_snapshot_dispose(&snap);

    // invalid group: bogus instance
    const orca_instance_id bogus[2] = { instances[0], 0x7fffffff };
    GUARD(e1, orca_plater_instances_rotate(plater, objects, bogus, 2, 2, 1.5,
                                           &revision));
    expect_code(e1, ORCA_STATUS_NOT_FOUND, "group rotate bogus instance");
    // duplicate instance rejected
    const orca_object_id dup_o[2] = { a, a };
    const orca_instance_id dup_i[2] = { instances[0], instances[0] };
    GUARD(e2, orca_plater_instances_rotate(plater, dup_o, dup_i, 2, 2, 1.5,
                                           &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "group rotate duplicate");

    // group move: one mutation, one undo step
    transforms[0].offset_x += 10.0;
    transforms[1].offset_x += 10.0;
    GUARD(g3, orca_plater_instances_set(plater, objects, instances, transforms, 2,
                                        "Move", &revision));
    expect_ok(g3, "group set");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.undo_count, undo_before + 1);
    CHECK(snapshot_label(snap.undo_label) == "Move");
    CHECK_NEAR(snap.objects[0].instances[0].transform.offset_x, ax + 10.0, 1e-9);
    orca_scene_snapshot_dispose(&snap);

    // one undo reverts BOTH instances
    GUARD(g4, orca_plater_undo(plater, &revision));
    expect_ok(g4, "undo group move");
    snap = take_snapshot(plater);
    CHECK_NEAR(snap.objects[0].instances[0].transform.offset_x, ax, 1e-9);
    orca_scene_snapshot_dispose(&snap);

    // group rotate
    GUARD(g5, orca_plater_instances_rotate(plater, objects, instances, 2, 0,
                                           0.5, &revision));
    expect_ok(g5, "group rotate");
    snap = take_snapshot(plater);
    CHECK(snapshot_label(snap.undo_label) == "Rotate");
    CHECK_NEAR(snap.objects[0].instances[0].transform.rotation_x, 0.5, 1e-9);
    CHECK_NEAR(snap.objects[1].instances[0].transform.rotation_x, 0.5, 1e-9);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g6, orca_plater_undo(plater, &revision));
    expect_ok(g6, "undo group rotate");
    snap = take_snapshot(plater);
    CHECK_NEAR(snap.objects[0].instances[0].transform.rotation_x, 0.0, 1e-9);
    orca_scene_snapshot_dispose(&snap);

    orca_plater_free(plater);
}
// ABI v22: per-object / per-part setting overrides.
static void test_object_settings(const std::string &dir) {
    orca_owned_string keys{};
    GUARD(g0, orca_plater_settings_keys(0, &keys));
    expect_ok(g0, "object keys");
    CHECK(keys.data && strstr(keys.data, "\"layer_height\"") != nullptr);
    CHECK(keys.data && strstr(keys.data, "\"sparse_infill_density\"") != nullptr);
    orca_owned_string_dispose(&keys);
    GUARD(g1, orca_plater_settings_keys(1, &keys));
    expect_ok(g1, "volume keys");
    CHECK(keys.data && strstr(keys.data, "\"sparse_infill_density\"") != nullptr);
    CHECK(keys.data && strstr(keys.data, "\"layer_height\"") == nullptr);
    orca_owned_string_dispose(&keys);

    orca_plater *plater = nullptr;
    GUARD(g2, orca_plater_new(&plater));
    expect_ok(g2, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "settings_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g3, import_one(plater, cube.c_str(), 100, 100, &object_id, &revision));
    expect_ok(g3, "import");
    orca_volume_id part_id = 0;
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        part_id = snap.objects[0].volumes[0].id;
        CHECK_EQ(snap.objects[0].override_count, 0u);
        orca_scene_snapshot_dispose(&snap);
    }

    GUARD(e1, orca_plater_settings_set(plater, object_id, 0, "no_such_key", "1", &revision));
    expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "unknown key");
    GUARD(e2, orca_plater_settings_set(plater, object_id, part_id, "layer_height", "0.1", &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "object-only key on a part");
    GUARD(e3, orca_plater_settings_set(plater, object_id, 0, "wall_loops", "lots", &revision));
    expect_code(e3, ORCA_STATUS_INVALID_CONFIGURATION, "unparsable value");
    GUARD(e4, orca_plater_settings_erase(plater, object_id, 0, "wall_loops", &revision));
    expect_code(e4, ORCA_STATUS_NOT_FOUND, "erase absent override");

    GUARD(g4, orca_plater_settings_set(plater, object_id, 0, "sparse_infill_density", "35%", &revision));
    expect_ok(g4, "object override");
    GUARD(g5, orca_plater_settings_set(plater, object_id, part_id, "wall_loops", "5", &revision));
    expect_ok(g5, "part override");
    orca_owned_string dump{};
    GUARD(g6, orca_plater_settings_dump(plater, object_id, 0, &dump));
    expect_ok(g6, "object dump");
    CHECK(dump.data && strstr(dump.data, "\"sparse_infill_density\":\"35%\"") != nullptr);
    orca_owned_string_dispose(&dump);
    GUARD(g7, orca_plater_settings_dump(plater, object_id, part_id, &dump));
    expect_ok(g7, "part dump");
    CHECK(dump.data && strstr(dump.data, "\"wall_loops\":\"5\"") != nullptr);
    orca_owned_string_dispose(&dump);
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        CHECK_EQ(snap.objects[0].override_count, 1u);
        CHECK_EQ(snap.objects[0].volumes[0].override_count, 1u);
        CHECK(snapshot_label(snap.undo_label) == "Part setting");
        orca_scene_snapshot_dispose(&snap);
    }
    // undo removes the part override, erase removes the object one
    GUARD(g8, orca_plater_undo(plater, &revision));
    expect_ok(g8, "undo part override");
    GUARD(g9, orca_plater_settings_erase(plater, object_id, 0, "sparse_infill_density", &revision));
    expect_ok(g9, "erase object override");
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        CHECK_EQ(snap.objects[0].override_count, 0u);
        CHECK_EQ(snap.objects[0].volumes[0].override_count, 0u);
        orca_scene_snapshot_dispose(&snap);
    }
    orca_plater_free(plater);
}

static void test_multi_object_import(const std::string &dir) {
    const std::string amf = write_two_cube_amf(dir, "orcapad-two-cubes.amf");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");

    orca_object_id first = 0;
    uint32_t count = 0;
    orca_revision revision = 0;
    GUARD(gn, orca_plater_import_model(plater, amf.c_str(), 100.0, 100.0, &first, nullptr, &revision));
    expect_code(gn, ORCA_STATUS_INVALID_ARGUMENT, "import(null count)");

    GUARD(g1, orca_plater_import_model(plater, amf.c_str(), 120.0, 80.0, &first, &count, &revision));
    expect_ok(g1, "import two-object AMF");
    CHECK_EQ(count, 2u);
    CHECK_EQ(revision, (orca_revision)1); // one import = one mutation
    CHECK(first != 0);

    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 2);
    if (snap.object_count == 2) {
        CHECK_EQ(snap.objects[0].id, first);
        const auto &a = snap.objects[0].instances[0].transform;
        const auto &b = snap.objects[1].instances[0].transform;
        // relative layout preserved: centers 50 mm apart in X, same Y
        CHECK_NEAR(b.offset_x - a.offset_x, 50.0, 1e-6);
        CHECK_NEAR(b.offset_y - a.offset_y, 0.0, 1e-6);
        // group centered on the requested bed center, resting on the bed
        CHECK_NEAR((a.offset_x + b.offset_x) / 2.0, 120.0, 1e-6);
        CHECK_NEAR(a.offset_y, 80.0, 1e-6);
        CHECK_NEAR(a.offset_z, 10.0, 1e-6);
        CHECK_NEAR(b.offset_z, 10.0, 1e-6);
        // meshes centered on their origin (rotation/scale pivot)
        for (int i = 0; i < 2; ++i) {
            CHECK_NEAR(snap.objects[i].bbox_min[0] + snap.objects[i].bbox_max[0], 0.0, 1e-4);
            CHECK_NEAR(snap.objects[i].bbox_min[2] + snap.objects[i].bbox_max[2], 0.0, 1e-4);
        }
    }
    orca_scene_snapshot_dispose(&snap);
    orca_plater_free(plater);
}

static void test_full_transforms(const std::string &dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube-transform.stl");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "add cube");
    orca_scene_snapshot snap = take_snapshot(plater);
    const orca_instance_id instance = snap.objects[0].instances[0].id;
    double original[16];
    memcpy(original, snap.objects[0].instances[0].matrix, sizeof original);
    // matrix translation equals the reported offset
    CHECK_NEAR(original[12], snap.objects[0].instances[0].transform.offset_x, 1e-9);
    CHECK_NEAR(original[13], snap.objects[0].instances[0].transform.offset_y, 1e-9);
    CHECK_NEAR(original[14], snap.objects[0].instances[0].transform.offset_z, 1e-9);
    orca_scene_snapshot_dispose(&snap);

    // typed rejections, no revision bump
    orca_revision out = 99;
    GUARD(g2, orca_plater_instance_rotate(plater, object_id, instance, 3, 0.1, &out));
    expect_code(g2, ORCA_STATUS_INVALID_ARGUMENT, "rotate(bad axis)");
    GUARD(g3, orca_plater_instance_rotate(plater, object_id, instance, 0, std::nan(""), &out));
    expect_code(g3, ORCA_STATUS_INVALID_ARGUMENT, "rotate(NaN)");
    GUARD(g4, orca_plater_instance_rotate(plater, object_id, 0x7fffffffffff, 0, 0.1, &out));
    expect_code(g4, ORCA_STATUS_NOT_FOUND, "rotate(bogus instance)");
    CHECK_EQ(snapshot_revision(plater), revision);

    // world X rotation by 90 degrees: +1 revision, rests on the bed
    GUARD(g5, orca_plater_instance_rotate(plater, object_id, instance, 0, M_PI / 2, &out));
    expect_ok(g5, "rotate X 90");
    CHECK_EQ(out, revision + 1);
    snap = take_snapshot(plater);
    const orca_scene_object &rotated = snap.objects[0];
    CHECK_NEAR(std::fabs(rotated.instances[0].transform.rotation_x), M_PI / 2, 1e-6);
    CHECK_NEAR(instance_min_z(rotated, rotated.instances[0].matrix), 0.0, 1e-4);
    // local +Z maps onto world -Y for a +90 deg rotation about world X
    CHECK_NEAR(rotated.instances[0].matrix[9], -1.0, 1e-6);
    orca_scene_snapshot_dispose(&snap);

    // 24 x 15 deg about Z wraps all the way through 360 back to the start
    GUARD(g6, orca_plater_instance_rotate(plater, object_id, instance, 0, -M_PI / 2, &out));
    expect_ok(g6, "rotate X back");
    for (int step = 0; step < 24; ++step) {
        orca_result r = orca_plater_instance_rotate(plater, object_id, instance, 2, M_PI / 12, &out);
        CHECK(r.code == ORCA_STATUS_OK);
        orca_result_dispose(&r);
    }
    snap = take_snapshot(plater);
    for (int i = 0; i < 16; ++i)
        CHECK_NEAR(snap.objects[0].instances[0].matrix[i], original[i], 1e-6);
    orca_instance_transform t = snap.objects[0].instances[0].transform;
    orca_scene_snapshot_dispose(&snap);

    // non-uniform scale: reported per axis, still resting on the bed
    t.scale_x = 2.0; t.scale_y = 1.0; t.scale_z = 0.5;
    t.offset_z = 50.0; // deliberately floating: the engine must re-rest it
    GUARD(g7, orca_plater_instance_set(plater, object_id, instance, &t, nullptr, &out));
    expect_ok(g7, "set non-uniform scale");
    snap = take_snapshot(plater);
    const orca_scene_object &scaled = snap.objects[0];
    CHECK_NEAR(scaled.instances[0].transform.scale_x, 2.0, 1e-9);
    CHECK_NEAR(scaled.instances[0].transform.scale_y, 1.0, 1e-9);
    CHECK_NEAR(scaled.instances[0].transform.scale_z, 0.5, 1e-9);
    CHECK_NEAR(instance_min_z(scaled, scaled.instances[0].matrix), 0.0, 1e-4);
    CHECK_NEAR(scaled.instances[0].transform.offset_z, 5.0, 1e-4); // 20 mm * 0.5 / 2
    orca_scene_snapshot_dispose(&snap);

    // absolute X/Y/Z rotation via set is accepted and reported back
    t.scale_x = t.scale_y = t.scale_z = 1.0;
    t.rotation_x = 0.3; t.rotation_y = -0.2; t.rotation_z = 1.1;
    GUARD(g8, orca_plater_instance_set(plater, object_id, instance, &t, nullptr, &out));
    expect_ok(g8, "set absolute XYZ rotation");
    snap = take_snapshot(plater);
    CHECK_NEAR(snap.objects[0].instances[0].transform.rotation_x, 0.3, 1e-6);
    CHECK_NEAR(snap.objects[0].instances[0].transform.rotation_y, -0.2, 1e-6);
    CHECK_NEAR(snap.objects[0].instances[0].transform.rotation_z, 1.1, 1e-6);
    CHECK_NEAR(instance_min_z(snap.objects[0], snap.objects[0].instances[0].matrix), 0.0, 1e-4);
    orca_scene_snapshot_dispose(&snap);

    orca_plater_free(plater);
}

static void test_snapshot_ownership(const std::string &dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube3.stl");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "add cube");

    // copy A
    orca_scene_snapshot a = take_snapshot(plater);
    const orca_scene_object *object_a = find_object(a, object_id);
    CHECK(object_a != nullptr);
    std::vector<float> positions_a;
    const double offset_a =
        object_a ? object_a->instances[0].transform.offset_x : 0;
    if (object_a)
        positions_a.assign(object_a->positions,
                           object_a->positions +
                               static_cast<size_t>(object_a->position_count) *
                                   3);

    // mutate the engine after the copy
    orca_instance_transform moved =
        object_a ? object_a->instances[0].transform
                 : orca_instance_transform{};
    moved.offset_x += 7.0;
    orca_revision revision2 = 0;
    GUARD(g2, orca_plater_instance_set(plater, object_id,
                                       object_a ? object_a->instances[0].id
                                                : orca_instance_id(0),
                                       &moved, nullptr, &revision2));
    expect_ok(g2, "set transform after copy");

    // copy B reflects the mutation; copy A is unchanged (deep copy)
    orca_scene_snapshot b = take_snapshot(plater);
    const orca_scene_object *object_b = find_object(b, object_id);
    CHECK(object_b != nullptr);
    if (object_a && object_b) {
        CHECK_NEAR(object_b->instances[0].transform.offset_x, offset_a + 7.0,
                   1e-9);
        CHECK_NEAR(object_a->instances[0].transform.offset_x, offset_a, 1e-9);
        CHECK_EQ(object_a->position_count, object_b->position_count);
        ++checks;
        if (object_a->position_count == object_b->position_count &&
            memcmp(object_a->positions, object_b->positions,
                   static_cast<size_t>(object_a->position_count) * 3 *
                       sizeof(float)) != 0) {
            fail(__FILE__, __LINE__, "mesh bytes differ between revisions");
        }
        CHECK_EQ(object_a->mesh_revision, object_b->mesh_revision);
    }

    orca_scene_snapshot_dispose(&a);
    orca_scene_snapshot_dispose(&a); // idempotent
    orca_scene_snapshot_dispose(&b);
    orca_plater_free(plater);
}

static void test_engine_serialization(const std::string &dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube4.stl");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "add cube");

    orca_scene_snapshot snap = take_snapshot(plater);
    const orca_instance_id instance = snap.objects[0].instances[0].id;
    orca_instance_transform base = snap.objects[0].instances[0].transform;
    orca_scene_snapshot_dispose(&snap);

    // Two mutating threads + a reading main thread. The Bridge must
    // process-serialize engine entry; upstream globals are not thread safe.
    constexpr int kIterations = 100;
    std::atomic<int> failures{0};
    auto mutator = [&](int id) {
        for (int i = 0; i < kIterations; ++i) {
            orca_instance_transform t = base;
            t.offset_x += (id + 1) * 0.001 * i;
            orca_revision rev = 0;
            orca_result r = orca_plater_instance_set(
                plater, object_id, instance, &t, nullptr, &rev);
            if (r.code != ORCA_STATUS_OK) ++failures;
            orca_result_dispose(&r);
        }
    };
    std::thread first(mutator, 0);
    std::thread second(mutator, 1);
    for (int i = 0; i < 25; ++i) {
        orca_scene_snapshot s = take_snapshot(plater);
        orca_scene_snapshot_dispose(&s);
    }
    first.join();
    second.join();
    CHECK_EQ(failures.load(), 0);
    // exactly one revision bump per successful mutation
    CHECK_EQ(snapshot_revision(plater), revision + 2 * kIterations);
    orca_plater_free(plater);
}

static std::string prepare_preset_data_dir(const std::string &dir) {
    const char *profiles = getenv("ORCAPAD_TEST_PROFILES_DIR");
    if (!profiles || !profiles[0]) {
        fprintf(stderr, "FATAL: ORCAPAD_TEST_PROFILES_DIR not set\n");
        exit(2);
    }
    const std::string data_dir = dir + "/orcapad-data";
    const std::string user_dir = data_dir + "/user";
    const std::string default_dir = data_dir + "/user/default";
    const char *levels[] = {
        data_dir.c_str(),
        user_dir.c_str(),
        default_dir.c_str(),
    };
    for (const char *level : levels) {
        struct stat st;
        if (stat(level, &st) == 0) continue; // already exists
        if (mkdir(level, 0755) != 0) {
            fprintf(stderr, "FATAL: cannot mkdir %s (errno=%d)\n", level,
                    errno);
            exit(2);
        }
    }
    const std::string link = data_dir + "/system";
    unlink(link.c_str());
    if (symlink(profiles, link.c_str()) != 0) {
        fprintf(stderr, "FATAL: cannot symlink profiles at %s (errno=%d)\n",
                link.c_str(), errno);
        exit(2);
    }
    return data_dir;
}

static void test_presets(const std::string &data_dir) {
    // null output pointer is a typed argument rejection
    GUARD(g0, orca_presets_new(data_dir.c_str(), nullptr));
    expect_code(g0, ORCA_STATUS_INVALID_ARGUMENT, "presets_new(null out)");

    // the process data directory is initialize-once: the FIRST successful
    // creation adopts it, and any different path is a typed configuration
    // failure ("differs from the initialized runtime").
    orca_presets *presets = nullptr;
    GUARD(g1, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g1, "presets_new");
    CHECK(presets != nullptr);

    orca_presets *other = nullptr;
    GUARD(g2, orca_presets_new("/nonexistent-orcapad-dir", &other));
    expect_code(g2, ORCA_STATUS_INVALID_CONFIGURATION,
                "presets_new(different data dir)");
    expect_owned_diagnostic(g2, "presets_new(different data dir)");
    CHECK(other == nullptr);
    orca_presets_free(other); // defensive null on failure

    // null handles and invalid kinds
    int32_t count = 0;
    GUARD(g3, orca_presets_list_count(nullptr, 0, &count));
    expect_code(g3, ORCA_STATUS_INVALID_HANDLE, "list_count(null presets)");
    GUARD(g4, orca_presets_list_count(presets, 7, &count));
    expect_code(g4, ORCA_STATUS_INVALID_ARGUMENT, "list_count(bad kind)");
    GUARD(g5, orca_presets_list_count(presets, 0, nullptr));
    expect_code(g5, ORCA_STATUS_INVALID_ARGUMENT, "list_count(null out)");

    // all three kinds expose system presets, stably
    for (int kind = 0; kind < 3; ++kind) {
        int32_t first = 0;
        GUARD(gk, orca_presets_list_count(presets, kind, &first));
        expect_ok(gk, "list_count");
        CHECK(first > 0);
        int32_t second = 0;
        GUARD(gk2, orca_presets_list_count(presets, kind, &second));
        expect_ok(gk2, "list_count repeat");
        CHECK_EQ(first, second);
    }

    // names are owned, non-empty, identical across calls; range is enforced
    int32_t machine_count = 0;
    GUARD(g6, orca_presets_list_count(presets, 0, &machine_count));
    expect_ok(g6, "machine count");
    orca_owned_string name_a;
    GUARD(g7, orca_presets_list_name(presets, 0, 0, &name_a));
    expect_ok(g7, "machine name[0]");
    CHECK(name_a.data != nullptr && name_a.length > 0);
    orca_owned_string name_b;
    GUARD(g8, orca_presets_list_name(presets, 0, 0, &name_b));
    expect_ok(g8, "machine name[0] repeat");
    CHECK(strcmp(name_a.data ? name_a.data : "",
                 name_b.data ? name_b.data : "") == 0);
    orca_owned_string_dispose(&name_a);
    orca_owned_string_dispose(&name_b);
    orca_owned_string out_of_range;
    GUARD(g9, orca_presets_list_name(presets, 0, machine_count,
                                     &out_of_range));
    expect_code(g9, ORCA_STATUS_NOT_FOUND, "name[out of range]");
    orca_owned_string_dispose(&out_of_range);

    // current selections for all three kinds
    orca_owned_string machine_default;
    GUARD(g10, orca_presets_current(presets, 0, &machine_default));
    expect_ok(g10, "current machine");
    orca_owned_string filament_default;
    GUARD(g11, orca_presets_current(presets, 1, &filament_default));
    expect_ok(g11, "current filament");
    orca_owned_string process_default;
    GUARD(g12, orca_presets_current(presets, 2, &process_default));
    expect_ok(g12, "current process");
    CHECK(machine_default.data && filament_default.data && process_default.data);

    // transactional select: bogus machine is rejected, selections unchanged
    GUARD(g13, orca_presets_select(presets, "__no_such_machine__",
                                   filament_default.data,
                                   process_default.data));
    expect_code(g13, ORCA_STATUS_NOT_FOUND, "select bogus machine");
    expect_owned_diagnostic(g13, "select bogus machine");
    orca_owned_string machine_after;
    GUARD(g14, orca_presets_current(presets, 0, &machine_after));
    expect_ok(g14, "current machine after failed select");
    CHECK(strcmp(machine_after.data ? machine_after.data : "",
                 machine_default.data ? machine_default.data : "") == 0);
    orca_owned_string_dispose(&machine_after);

    // empty names are invalid arguments
    GUARD(g15, orca_presets_select(presets, "", filament_default.data,
                                   process_default.data));
    expect_code(g15, ORCA_STATUS_INVALID_ARGUMENT, "select empty machine");

    // first system presets of each kind form a selectable combination
    // (the SettingsView flow: visibility forced on, compatibility Always)
    orca_owned_string machine_first;
    GUARD(g16, orca_presets_list_name(presets, 0, 0, &machine_first));
    expect_ok(g16, "machine names[0]");
    orca_owned_string filament_first;
    GUARD(g17, orca_presets_list_name(presets, 1, 0, &filament_first));
    expect_ok(g17, "filament names[0]");
    orca_owned_string process_first;
    GUARD(g18, orca_presets_list_name(presets, 2, 0, &process_first));
    expect_ok(g18, "process names[0]");
    GUARD(g19, orca_presets_select(presets, machine_first.data,
                                   filament_first.data, process_first.data));
    expect_ok(g19, "select first system presets");
    orca_owned_string machine_selected;
    GUARD(g20, orca_presets_current(presets, 0, &machine_selected));
    expect_ok(g20, "current machine after select");
    CHECK(strcmp(machine_selected.data ? machine_selected.data : "",
                 machine_first.data ? machine_first.data : "") == 0);

    orca_owned_string_dispose(&machine_selected);
    orca_owned_string_dispose(&machine_first);
    orca_owned_string_dispose(&filament_first);
    orca_owned_string_dispose(&process_first);
    orca_owned_string_dispose(&machine_default);
    orca_owned_string_dispose(&filament_default);
    orca_owned_string_dispose(&process_default);
    orca_presets_free(presets);
}

struct ProgressRecord {
    std::atomic<int> calls{0};
    std::atomic<int> max_percent{0};
    std::atomic<int> min_percent{1000};
};

static void progress_trampoline(int32_t percent, const char *message,
                                void *context) {
    // Callbacks arrive serialized on the slicing thread.
    ProgressRecord *record = static_cast<ProgressRecord *>(context);
    record->calls += 1;
    const int current = percent;
    if (current > record->max_percent.load())
        record->max_percent.store(current);
    if (current < record->min_percent.load())
        record->min_percent.store(current);
    (void)message;
}

static void check_slice_outputs(const char *gcode_path,
                                const ResultGuard &guard,
                                orca_slice_report &report,
                                ProgressRecord &progress, const char *what) {
    expect_ok(guard, what);
    if (!guard.ok()) return;
    CHECK(report.time_estimate_s > 0.0);
    CHECK(report.gcode_bytes > 0);
    struct stat status;
    CHECK(stat(gcode_path, &status) == 0);
    CHECK_EQ(status.st_size, report.gcode_bytes);
    CHECK(progress.calls.load() > 0);
    CHECK(progress.max_percent.load() >= 99);
    CHECK(progress.min_percent.load() >= 0); // warning statuses never leak
    CHECK(report.warning_count == 0 || report.warnings != nullptr);
    for (uint32_t i = 0; i < report.warning_count; ++i) {
        const orca_slice_warning &w = report.warnings[i];
        CHECK(w.level >= ORCA_SLICE_WARNING_TIP && w.level <= ORCA_SLICE_WARNING_CRITICAL);
        CHECK(w.source >= ORCA_SLICE_SOURCE_VALIDATE && w.source <= ORCA_SLICE_SOURCE_CONFLICT);
        CHECK(w.code.data && w.message.data && w.detail.data);
        CHECK(w.code.length > 0 || w.message.length > 0);
    }
    orca_slice_report_dispose(&report);
    CHECK(report.warnings == nullptr && report.warning_count == 0);
    orca_slice_report_dispose(&report); // idempotent
}

static void test_preset_metadata(const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");

    // Select a concrete system machine first: a fresh bundle selects a
    // non-system default printer, against which no process is compatible.
    {
        orca_owned_string machine_first;
        GUARD(gs1, orca_presets_list_name(presets, 0, 0, &machine_first));
        expect_ok(gs1, "machine names[0]");
        orca_owned_string filament_first;
        GUARD(gs2, orca_presets_list_name(presets, 1, 0, &filament_first));
        expect_ok(gs2, "filament names[0]");
        orca_owned_string process_first;
        GUARD(gs3, orca_presets_list_name(presets, 2, 0, &process_first));
        expect_ok(gs3, "process names[0]");
        GUARD(gs4, orca_presets_select(presets, machine_first.data,
                                       filament_first.data,
                                       process_first.data));
        expect_ok(gs4, "select first system presets");
        orca_owned_string_dispose(&machine_first);
        orca_owned_string_dispose(&filament_first);
        orca_owned_string_dispose(&process_first);
    }

    // null handle / null out / bad kind / out of range are typed rejections
    orca_preset_entry entry;
    GUARD(g1, orca_presets_list_entry(nullptr, 0, 0, &entry));
    expect_code(g1, ORCA_STATUS_INVALID_HANDLE, "entry(null presets)");
    GUARD(g2, orca_presets_list_entry(presets, 0, 0, nullptr));
    expect_code(g2, ORCA_STATUS_INVALID_ARGUMENT, "entry(null out)");
    GUARD(g3, orca_presets_list_entry(presets, 9, 0, &entry));
    expect_code(g3, ORCA_STATUS_INVALID_ARGUMENT, "entry(bad kind)");
    GUARD(g4, orca_presets_list_entry(presets, 0, 1 << 20, &entry));
    expect_code(g4, ORCA_STATUS_NOT_FOUND, "entry(out of range)");
    orca_preset_entry_dispose(nullptr); // null-safe

    // entries share the exact stable order of orca_presets_list_name
    for (int kind = 0; kind < 3; ++kind) {
        int32_t count = 0;
        GUARD(gc, orca_presets_list_count(presets, kind, &count));
        expect_ok(gc, "count");
        int entries_with_vendor = 0;
        int compatible_processes = 0;
        for (int32_t index = 0; index < count; ++index) {
            orca_preset_entry e;
            e.name = orca_owned_string{};
            e.vendor = orca_owned_string{};
            e.compatible = 0xFF;
            GUARD(ge, orca_presets_list_entry(presets, kind, index, &e));
            expect_ok(ge, "entry");
            CHECK(e.name.data != nullptr && e.name.length > 0);
            CHECK(e.compatible == 0 || e.compatible == 1);
            if (e.vendor.length > 0) ++entries_with_vendor;
            if (e.compatible == 1) ++compatible_processes;
            orca_preset_entry_dispose(&e);
            orca_preset_entry_dispose(&e); // idempotent
        }
        CHECK(entries_with_vendor > 0); // manufacturers are exposed
        if (kind == 2) // processes: engine marks some compatible with the
            CHECK(compatible_processes > 0); // selected machine
    }

    // entry[0] must equal name[0] for every kind
    for (int kind = 0; kind < 3; ++kind) {
        orca_owned_string name;
        GUARD(gn, orca_presets_list_name(presets, kind, 0, &name));
        expect_ok(gn, "name[0]");
        orca_preset_entry e;
        GUARD(ge, orca_presets_list_entry(presets, kind, 0, &e));
        expect_ok(ge, "entry[0]");
        CHECK(strcmp(name.data ? name.data : "",
                     e.name.data ? e.name.data : "") == 0);
        orca_owned_string_dispose(&name);
        orca_preset_entry_dispose(&e);
    }
    orca_presets_free(presets);
}

static void test_print_volume(const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");

    double minX = 0, minY = 0, maxX = 0, maxY = 0;
    GUARD(g1, orca_presets_print_volume(nullptr, &minX, &minY, &maxX, &maxY));
    expect_code(g1, ORCA_STATUS_INVALID_HANDLE, "volume(null presets)");
    GUARD(g2, orca_presets_print_volume(presets, nullptr, &minY, &maxX, &maxY));
    expect_code(g2, ORCA_STATUS_INVALID_ARGUMENT, "volume(null out)");

    GUARD(g3, orca_presets_print_volume(presets, &minX, &minY, &maxX, &maxY));
    expect_ok(g3, "print volume");
    CHECK(maxX > minX);
    CHECK(maxY > minY);
    CHECK(minX > -5000.0 && maxX < 5000.0); // sane machine dimensions
    CHECK(minY > -5000.0 && maxY < 5000.0);
    orca_presets_free(presets);
}

static void test_resolved_config(const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");

    orca_owned_string json;
    GUARD(g1, orca_presets_resolved_config(nullptr, &json));
    expect_code(g1, ORCA_STATUS_INVALID_HANDLE, "resolved(null presets)");
    GUARD(g2, orca_presets_resolved_config(presets, nullptr));
    expect_code(g2, ORCA_STATUS_INVALID_ARGUMENT, "resolved(null out)");

    GUARD(g3, orca_presets_resolved_config(presets, &json));
    expect_ok(g3, "resolved config");
    CHECK(json.data != nullptr);
    CHECK(json.length > 1000); // the full ~2000-option configuration
    const char *body = json.data ? json.data : "";
    CHECK(body[0] == '{');
    CHECK(strstr(body, "\"printable_area\"") != nullptr);
    CHECK(strstr(body, "\"layer_height\"") != nullptr);
    orca_owned_string_dispose(&json);
    orca_presets_free(presets);
}

static void test_preset_overrides(const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");

    // select a concrete system triple (fresh bundles select a non-system
    // default printer, against which no process is compatible)
    {
        orca_owned_string machine_first, filament_first, process_first;
        GUARD(gs1, orca_presets_list_name(presets, 0, 0, &machine_first));
        expect_ok(gs1, "machine names[0]");
        GUARD(gs2, orca_presets_list_name(presets, 1, 0, &filament_first));
        expect_ok(gs2, "filament names[0]");
        GUARD(gs3, orca_presets_list_name(presets, 2, 0, &process_first));
        expect_ok(gs3, "process names[0]");
        GUARD(gs4, orca_presets_select(presets, machine_first.data,
                                       filament_first.data,
                                       process_first.data));
        expect_ok(gs4, "select first system presets");
        orca_owned_string_dispose(&machine_first);
        orca_owned_string_dispose(&filament_first);
        orca_owned_string_dispose(&process_first);
    }

    // typed rejections
    GUARD(g1, orca_presets_set_value(presets, 0, nullptr, "1"));
    expect_code(g1, ORCA_STATUS_INVALID_ARGUMENT, "set(null key)");
    GUARD(g2, orca_presets_set_value(presets, 7, "layer_height", "0.3"));
    expect_code(g2, ORCA_STATUS_INVALID_ARGUMENT, "set(bad kind)");
    GUARD(g3, orca_presets_set_value(presets, 2, "__no_such_key__", "1"));
    expect_code(g3, ORCA_STATUS_NOT_FOUND, "set(unknown key)");

    // system baseline: edited dump == system dump right after selection
    orca_owned_string system_dump;
    GUARD(g4, orca_presets_config_dump(presets, 2, 0, &system_dump));
    expect_ok(g4, "system dump");
    orca_owned_string edited_dump;
    GUARD(g5, orca_presets_config_dump(presets, 2, 1, &edited_dump));
    expect_ok(g5, "edited dump");
    CHECK(system_dump.length == edited_dump.length &&
          strcmp(system_dump.data ? system_dump.data : "",
                 edited_dump.data ? edited_dump.data : "") == 0);

    // override: edited dump changes, system dump does not
    GUARD(g6, orca_presets_set_value(presets, 2, "layer_height", "0.31"));
    expect_ok(g6, "set layer_height");
    orca_owned_string edited_after;
    GUARD(g7, orca_presets_config_dump(presets, 2, 1, &edited_after));
    expect_ok(g7, "edited dump after override");
    CHECK(strstr(edited_after.data ? edited_after.data : "",
                 "\"layer_height\":\"0.31\"") != nullptr);
    CHECK(strstr(system_dump.data ? system_dump.data : "",
                 "\"layer_height\":\"0.31\"") == nullptr);

    // overrides flow into the resolved config (slicing consumes them)
    orca_owned_string resolved;
    GUARD(g8, orca_presets_resolved_config(presets, &resolved));
    expect_ok(g8, "resolved after override");
    CHECK(strstr(resolved.data ? resolved.data : "",
                 "\"layer_height\":\"0.31\"") != nullptr);

    // per-key reset restores the system value
    GUARD(g9, orca_presets_reset_value(presets, 2, "layer_height"));
    expect_ok(g9, "reset layer_height");
    orca_owned_string edited_reset;
    GUARD(g10, orca_presets_config_dump(presets, 2, 1, &edited_reset));
    expect_ok(g10, "edited dump after reset");
    CHECK(strstr(edited_reset.data ? edited_reset.data : "",
                 "\"layer_height\":\"0.31\"") == nullptr);

    // whole-kind reset also restores the system dump exactly
    GUARD(g11, orca_presets_set_value(presets, 2, "layer_height", "0.42"));
    expect_ok(g11, "set layer_height again");
    GUARD(g12, orca_presets_reset_kind(presets, 2));
    expect_ok(g12, "reset process kind");
    orca_owned_string edited_final;
    GUARD(g13, orca_presets_config_dump(presets, 2, 1, &edited_final));
    expect_ok(g13, "edited dump after kind reset");
    CHECK(strcmp(system_dump.data ? system_dump.data : "",
                 edited_final.data ? edited_final.data : "") == 0);

    orca_owned_string_dispose(&system_dump);
    orca_owned_string_dispose(&edited_dump);
    orca_owned_string_dispose(&edited_after);
    orca_owned_string_dispose(&resolved);
    orca_owned_string_dispose(&edited_reset);
    orca_owned_string_dispose(&edited_final);
    orca_presets_free(presets);
}

static bool resolved_contains(orca_presets *presets, const char *needle) {
    orca_owned_string json;
    GUARD(g, orca_presets_resolved_config(presets, &json));
    expect_ok(g, "resolved config");
    const bool found = strstr(json.data ? json.data : "", needle) != nullptr;
    orca_owned_string_dispose(&json);
    return found;
}

static orca_bed_type_state bed_state(orca_presets *presets, const char *what) {
    orca_bed_type_state state{};
    GUARD(g, orca_presets_bed_type(presets, &state));
    expect_ok(g, what);
    return state;
}

// Desktop Sidebar::update_presets parity: curr_bed_type follows the machine
// default on machine change, user choice persists otherwise, and slicing
// (full_config) sees it — bed temperatures are keyed by it (GCode.cpp).
static void test_bed_type(const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");

    orca_bed_type_state state{};
    GUARD(g1, orca_presets_bed_type(nullptr, &state));
    expect_code(g1, ORCA_STATUS_INVALID_HANDLE, "bed_type(null)");
    GUARD(g2, orca_presets_bed_type(presets, nullptr));
    expect_code(g2, ORCA_STATUS_INVALID_ARGUMENT, "bed_type(null out)");
    GUARD(g3, orca_presets_set_bed_type(nullptr, 1));
    expect_code(g3, ORCA_STATUS_INVALID_HANDLE, "set_bed_type(null)");

    state = bed_state(presets, "initial bed type");
    CHECK_EQ(state.count, 7);
    CHECK(state.current >= 1 && state.current < state.count);
    CHECK_EQ(state.current, state.machine_default);

    orca_owned_string filament, process;
    GUARD(gf, orca_presets_list_name(presets, 1, 0, &filament));
    expect_ok(gf, "filament names[0]");
    GUARD(gp, orca_presets_list_name(presets, 2, 0, &process));
    expect_ok(gp, "process names[0]");

    // single-bed machine (no default_bed_type): engine default btPEI (3)
    GUARD(g4, orca_presets_select(presets, "Anycubic Vyper 0.4 nozzle",
                                  filament.data, process.data));
    expect_ok(g4, "select Vyper");
    state = bed_state(presets, "Vyper bed type");
    CHECK_EQ(state.machine_default, 3);
    CHECK_EQ(state.current, 3);
    CHECK_EQ((int)state.selectable, 0);
    CHECK_EQ(state.supported_mask, 0x7Eu);
    CHECK(resolved_contains(presets, "\"curr_bed_type\":\"High Temp Plate\""));
    GUARD(g5, orca_presets_set_bed_type(presets, 1));
    expect_code(g5, ORCA_STATUS_INVALID_CONFIGURATION, "set on non-selectable");
    GUARD(g6, orca_presets_set_bed_type(presets, 3));
    expect_ok(g6, "set default on non-selectable");
    GUARD(g7, orca_presets_set_bed_type(presets, 0));
    expect_code(g7, ORCA_STATUS_INVALID_ARGUMENT, "set btDefault");
    GUARD(g8, orca_presets_set_bed_type(presets, 7));
    expect_code(g8, ORCA_STATUS_INVALID_ARGUMENT, "set btCount");

    // multi-bed machine with numeric default_bed_type "4" (Textured PEI)
    GUARD(g9, orca_presets_select(presets, "WonderMaker ZR 0.4 nozzle",
                                  filament.data, process.data));
    expect_ok(g9, "select WonderMaker");
    state = bed_state(presets, "WonderMaker bed type");
    CHECK_EQ(state.machine_default, 4);
    CHECK_EQ(state.current, 4);
    CHECK_EQ((int)state.selectable, 1);
    GUARD(g10, orca_presets_set_bed_type(presets, 1));
    expect_ok(g10, "set Cool Plate");
    CHECK_EQ(bed_state(presets, "after set").current, 1);
    CHECK(resolved_contains(presets, "\"curr_bed_type\":\"Cool Plate\""));

    // same machine re-selected: the user choice persists
    GUARD(g11, orca_presets_select(presets, "WonderMaker ZR 0.4 nozzle",
                                   filament.data, process.data));
    expect_ok(g11, "reselect WonderMaker");
    CHECK_EQ(bed_state(presets, "after reselect").current, 1);

    // machine change: reset to the new machine's default
    GUARD(g12, orca_presets_select(presets, "Anycubic Vyper 0.4 nozzle",
                                   filament.data, process.data));
    expect_ok(g12, "back to Vyper");
    CHECK_EQ(bed_state(presets, "after machine change").current, 3);

    orca_owned_string_dispose(&filament);
    orca_owned_string_dispose(&process);
    orca_presets_free(presets);
}

static void test_slice_defaults(const std::string &dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube5.stl");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "add cube");

    // a second instance for multi-instance coverage
    orca_instance_id second = 0;
    orca_revision revision2 = 0;
    GUARD(g2, orca_plater_instance_add(plater, object_id, &second, &revision2));
    expect_ok(g2, "add second instance");

    const std::string gcode = dir + "/defaults.gcode";
    ProgressRecord progress;
    orca_slice_report report;
    GUARD(g3, orca_plater_slice_to_gcode(
                  plater, gcode.c_str(), progress_trampoline, &progress,
                  nullptr, &report));
    check_slice_outputs(gcode.c_str(), g3, report, progress,
                        "slice defaults");

    // interop lock: the preset-free overlay must land in the exported config
    // block (empty nozzle_type segfaults desktop AND OrcaPad's own loader)
    FILE *config_scan = fopen(gcode.c_str(), "r");
    CHECK(config_scan != nullptr);
    if (config_scan) {
        char line[512];
        bool brass_seen = false;
        while (fgets(line, sizeof line, config_scan))
            if (strstr(line, "; nozzle_type = brass")) {
                brass_seen = true;
                break;
            }
        fclose(config_scan);
        CHECK(brass_seen);
    }

    // slicing is not a document mutation: revision unchanged
    CHECK_EQ(snapshot_revision(plater), revision2);

    // invalid outputs/paths are typed rejections
    GUARD(g4, orca_plater_slice_to_gcode(plater, "", progress_trampoline,
                                         &progress, nullptr, &report));
    expect_code(g4, ORCA_STATUS_INVALID_ARGUMENT, "slice empty path");
    GUARD(g5, orca_plater_slice_to_gcode(plater, gcode.c_str(),
                                         progress_trampoline, &progress,
                                         nullptr, nullptr));
    expect_code(g5, ORCA_STATUS_INVALID_ARGUMENT, "slice null out");
    GUARD(g6, orca_plater_slice_to_gcode(nullptr, gcode.c_str(),
                                         progress_trampoline, &progress,
                                         nullptr, &report));
    expect_code(g6, ORCA_STATUS_INVALID_HANDLE, "slice null plater");

    orca_plater_free(plater);
}

static void test_slice_with_presets(const std::string &dir,
                                    const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(gp, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(gp, "presets_new");

    // null presets handle is a typed rejection
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    const std::string gcode = dir + "/presets.gcode";
    orca_slice_report report;
    GUARD(g1, orca_plater_slice_to_gcode_with_presets(
                  plater, nullptr, gcode.c_str(), nullptr, nullptr,
                  nullptr, &report));
    expect_code(g1, ORCA_STATUS_INVALID_HANDLE, "slice null presets");

    // A real compatible system triple: the fresh bundle's "- default -"
    // printer fails Print::validate exactly as it would on desktop (so do
    // some vendor profiles, e.g. Anycubic Vyper — no G92 E0 layer reset).
    GUARD(gsel, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                    "Bambu PLA Basic @BBL X1C",
                                    "0.20mm Standard @BBL X1C"));
    expect_ok(gsel, "select X1C triple");

    const std::string cube = write_cube_stl(dir, "orcapad-cube6.stl");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g2, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g2, "add cube");

    ProgressRecord progress;
    GUARD(g3, orca_plater_slice_to_gcode_with_presets(
                  plater, presets, gcode.c_str(), progress_trampoline,
                  &progress, nullptr, &report));
    check_slice_outputs(gcode.c_str(), g3, report, progress,
                        "slice with presets");
    CHECK_EQ(snapshot_revision(plater), revision); // slices never mutate

    // preset-backed output must NOT be the defaults overlay: the gcode
    // carries the selected machine's printable area from full_config()
    // (basic parity probe — exact values come from device verification)
    FILE *file = fopen(gcode.c_str(), "r");
    CHECK(file != nullptr);
    if (file) {
        char line[512];
        bool saw_printable_area = false;
        while (fgets(line, sizeof line, file)) {
            if (strstr(line, "printable_area")) {
                saw_printable_area = true;
                break;
            }
        }
        fclose(file);
        CHECK(saw_printable_area);
    }

    // Print::validate warnings are surfaced in the report (Orca: Lightning
    // base pattern with normal supports falls back to Rectilinear)
    GUARD(gw1, orca_presets_set_value(presets, 2, "enable_support", "1"));
    expect_ok(gw1, "enable support");
    GUARD(gw2, orca_presets_set_value(presets, 2, "support_type", "normal(auto)"));
    expect_ok(gw2, "normal supports");
    GUARD(gw3, orca_presets_set_value(presets, 2, "support_base_pattern", "lightning"));
    expect_ok(gw3, "lightning base");
    GUARD(gw4, orca_plater_slice_to_gcode_with_presets(
                  plater, presets, gcode.c_str(), nullptr, nullptr, nullptr, &report));
    expect_ok(gw4, "slice with validate warning");
    bool saw_validate_warning = false;
    for (uint32_t i = 0; i < report.warning_count; ++i) {
        const orca_slice_warning &w = report.warnings[i];
        if (w.source == ORCA_SLICE_SOURCE_VALIDATE &&
            strcmp(w.code.data, "support_base_pattern") == 0 &&
            strstr(w.message.data, "Lightning") != nullptr)
            saw_validate_warning = true;
    }
    CHECK(saw_validate_warning);
    orca_slice_report_dispose(&report);
    GUARD(gw5, orca_presets_reset_kind(presets, 2));
    expect_ok(gw5, "reset process");

    // Print::validate errors refuse the slice with the engine's message:
    // the "- default -" machine (relative E, no G92 E0 layer reset)
    orca_presets *raw = nullptr;
    GUARD(gr, orca_presets_new(data_dir.c_str(), &raw));
    expect_ok(gr, "presets_new raw");
    GUARD(gv, orca_plater_slice_to_gcode_with_presets(
                  plater, raw, gcode.c_str(), nullptr, nullptr, nullptr, &report));
    expect_code(gv, ORCA_STATUS_INVALID_CONFIGURATION, "validate rejects default printer");
    expect_owned_diagnostic(gv, "validate rejects default printer");
    orca_presets_free(raw);

    orca_plater_free(plater);
    orca_presets_free(presets);
}

static std::string current_preset(orca_presets *presets, int32_t kind) {
    orca_owned_string name;
    GUARD(g, orca_presets_current(presets, kind, &name));
    expect_ok(g, "current preset");
    std::string value = name.data ? name.data : "";
    orca_owned_string_dispose(&name);
    return value;
}

static std::string config_dump(orca_presets *presets, int32_t kind, uint8_t edited) {
    orca_owned_string json;
    GUARD(g, orca_presets_config_dump(presets, kind, edited, &json));
    expect_ok(g, "config dump");
    std::string value = json.data ? json.data : "";
    orca_owned_string_dispose(&json);
    return value;
}

// Desktop Save project → Open project round trip: geometry, instances,
// transforms, selected presets, overrides and plate type all survive.
// Arrange + orient: many instances of one cube pack onto the bed in a grid
// and stay there; orient leaves instances resting on the bed.
static void test_arrange_orient(const std::string &dir, const std::string &data_dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube10.stl");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 0.0, 0.0, &object_id, &revision));
    expect_ok(g1, "import cube");
    for (int i = 0; i < 8; ++i) {
        orca_instance_id instance = 0;
        GUARD(ga, orca_plater_instance_add(plater, object_id, &instance, &revision));
        expect_ok(ga, "stack instances");
    }

    orca_presets *presets = nullptr;
    GUARD(gp, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(gp, "presets_new");
    GUARD(gsel, orca_presets_select(presets, "Anycubic Vyper 0.4 nozzle",
                                    "Anycubic Generic PLA",
                                    "0.20mm Standard @Anycubic Vyper"));
    expect_ok(gsel, "select Vyper (244x244 bed)");

    uint32_t unprintable = 99;
    GUARD(e1, orca_plater_arrange(plater, presets, 0, &unprintable, &revision));
    expect_ok(e1, "arrange");
    CHECK_EQ(unprintable, 0u);
    CHECK_EQ(revision, (orca_revision)10); // import + 8 adds + arrange

    // all 9 instances are separated (no two share a position) and on the bed
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 1);
        if (snap.object_count == 1) {
            const int n = snap.objects[0].instance_count;
            CHECK_EQ(n, 9);
            for (int i = 0; i < n; ++i) {
                CHECK_NEAR(snap.objects[0].instances[i].transform.offset_z, 10.0, 1e-6);
                for (int j = i + 1; j < n; ++j) {
                    const double dx = snap.objects[0].instances[i].transform.offset_x -
                                      snap.objects[0].instances[j].transform.offset_x;
                    const double dy = snap.objects[0].instances[i].transform.offset_y -
                                      snap.objects[0].instances[j].transform.offset_y;
                    CHECK(std::hypot(dx, dy) > 19.9); // 20mm cubes cannot overlap
                }
            }
        }
        orca_scene_snapshot_dispose(&snap);
    }

    // orient the whole document: everything stays on the bed
    GUARD(g2, orca_plater_orient(plater, presets, 0, 0, &revision));
    expect_ok(g2, "orient all");
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        for (int i = 0; i < snap.objects[0].instance_count; ++i)
            CHECK_NEAR(snap.objects[0].instances[i].transform.offset_z, 10.0, 1e-6);
        orca_scene_snapshot_dispose(&snap);
    }

    // lay flat on a face normal: after +90° about X, the original BOTTOM
    // face points +Y; laying that face down restores the upright cube.
    orca_object_id flat_object = 0;
    GUARD(f0, import_one(plater, (dir + "/orcapad-cube10.stl").c_str(), 60.0, 60.0, &flat_object, &revision));
    expect_ok(f0, "import flat cube");
    orca_instance_id flat_instance = 0;
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        for (int32_t i = 0; i < snap.object_count && !flat_instance; ++i)
            if (snap.objects[i].id == flat_object && snap.objects[i].instance_count > 0)
                flat_instance = snap.objects[i].instances[0].id;
        orca_scene_snapshot_dispose(&snap);
    }
    CHECK(flat_instance != 0);
    GUARD(f1, orca_plater_instance_rotate(plater, flat_object, flat_instance, 0, M_PI / 2, &revision));
    expect_ok(f1, "rotate X 90°");
    GUARD(f2, orca_plater_instance_lay_flat(plater, flat_object, flat_instance, 0.0, 1.0, 0.0, &revision));
    expect_ok(f2, "lay flat on -Y face");
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        const orca_scene_object *flat_obj = nullptr;
        for (int32_t i = 0; i < snap.object_count; ++i)
            if (snap.objects[i].id == flat_object) flat_obj = &snap.objects[i];
        CHECK(flat_obj != nullptr);
        if (!flat_obj) { orca_scene_snapshot_dispose(&snap); orca_plater_free(plater); orca_presets_free(presets); return; }
        const auto &tr = flat_obj->instances[0].transform;
        CHECK_NEAR(tr.rotation_x, 0.0, 1e-6);
        CHECK_NEAR(tr.rotation_y, 0.0, 1e-6);
        CHECK_NEAR(tr.rotation_z, 0.0, 1e-6);
        CHECK_NEAR(tr.offset_z, 10.0, 1e-6);
        orca_scene_snapshot_dispose(&snap);
    }
    GUARD(f3, orca_plater_instance_lay_flat(plater, flat_object, flat_instance, 0.0, 0.0, 0.0, &revision));
    expect_code(f3, ORCA_STATUS_INVALID_ARGUMENT, "lay flat degenerate normal");

    // typed rejections
    GUARD(e2, orca_plater_orient(plater, presets, 12345, 1, &revision));
    expect_code(e2, ORCA_STATUS_NOT_FOUND, "orient missing object");
    GUARD(e3, orca_plater_arrange(nullptr, presets, 0, &unprintable, &revision));
    expect_code(e3, ORCA_STATUS_INVALID_HANDLE, "arrange null plater");

    orca_presets_free(presets);
    orca_plater_free(plater);
}

static void test_project_roundtrip(const std::string &dir, const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(gp, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(gp, "presets_new");
    GUARD(gs, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                  "Bambu PLA Basic @BBL X1C", "0.20mm Standard @BBL X1C"));
    expect_ok(gs, "select X1C");
    GUARD(go, orca_presets_set_value(presets, 2, "layer_height", "0.24"));
    expect_ok(go, "override layer_height");
    GUARD(gb, orca_presets_set_bed_type(presets, 4));
    expect_ok(gb, "textured PEI");

    const std::string cube = write_cube_stl(dir, "orcapad-cube9.stl");
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 128.0, 128.0, &object_id, &revision));
    expect_ok(g1, "import cube");
    orca_instance_id second = 0;
    GUARD(g2, orca_plater_instance_add(plater, object_id, &second, &revision));
    expect_ok(g2, "second instance");
    GUARD(g3, orca_plater_instance_rotate(plater, object_id, second, 2, 0.5235987755982988, &revision));
    expect_ok(g3, "rotate second");

    const std::string project = dir + "/roundtrip.3mf";
    GUARD(e1, orca_project_save(nullptr, presets, project.c_str(), 0, nullptr));
    expect_code(e1, ORCA_STATUS_INVALID_HANDLE, "save(null plater)");
    GUARD(e2, orca_project_save(plater, presets, (dir + "/x.stl").c_str(), 0, nullptr));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "save(non-3mf)");
    // a synthetic 64² top-down gradient as the client-rendered plate image
    std::vector<uint8_t> image(64 * 64 * 4);
    for (size_t i = 0; i < image.size(); i += 4) {
        image[i] = uint8_t(i / 4 % 64 * 4); image[i + 1] = 128;
        image[i + 2] = uint8_t(i / 4 / 64 * 4); image[i + 3] = 255;
    }
    GUARD(e5, orca_project_save(plater, presets, project.c_str(), 8, image.data()));
    expect_code(e5, ORCA_STATUS_INVALID_ARGUMENT, "save(tiny thumbnail)");
    GUARD(g4, orca_project_save(plater, presets, project.c_str(), 64, image.data()));
    expect_ok(g4, "save project");
    CHECK_EQ(snapshot_revision(plater), revision); // saving is not a mutation
    struct stat status;
    CHECK(stat(project.c_str(), &status) == 0 && status.st_size > 0);
    {
        mz_zip_archive zip;
        memset(&zip, 0, sizeof zip);
        CHECK(mz_zip_reader_init_file(&zip, project.c_str(), 0));
        CHECK(mz_zip_reader_locate_file(&zip, "Metadata/plate_1.png", nullptr, 0) >= 0);
        mz_zip_reader_end(&zip);
    }

    orca_scene_snapshot before = take_snapshot(plater);

    // reopen into a FRESH document + session
    orca_presets *presets2 = nullptr;
    GUARD(gp2, orca_presets_new(data_dir.c_str(), &presets2));
    expect_ok(gp2, "presets_new 2");
    orca_plater *plater2 = nullptr;
    GUARD(g5, orca_plater_new(&plater2));
    expect_ok(g5, "plater_new 2");
    orca_scene_snapshot empty2 = take_snapshot(plater2);
    const orca_document_id old_document = empty2.document_id;
    orca_scene_snapshot_dispose(&empty2);

    orca_project_info info;
    GUARD(e3, orca_project_open(plater2, presets2, (dir + "/missing.3mf").c_str(), &info));
    expect_code(e3, ORCA_STATUS_IO_FAILURE, "open(missing)");
    GUARD(e4, orca_project_open(plater2, presets2, cube.c_str(), &info));
    CHECK(!e4.ok()); // an STL is not a project
    CHECK_EQ(snapshot_revision(plater2), (orca_revision)0); // untouched on failure

    GUARD(g6, orca_project_open(plater2, presets2, project.c_str(), &info));
    expect_ok(g6, "open project");
    CHECK_EQ(info.object_count, 1u);
    CHECK_EQ(info.plate_count, 1u);
    CHECK_EQ((int)info.config_applied, 1);
    CHECK_EQ((int)info.source, (int)ORCA_PROJECT_FROM_ORCA);
    CHECK_EQ(info.revision, (orca_revision)1);

    orca_scene_snapshot after = take_snapshot(plater2);
    CHECK(after.document_id != old_document); // open = new document
    CHECK_EQ(after.object_count, 1);
    if (after.object_count == 1 && before.object_count == 1) {
        CHECK_EQ(after.objects[0].instance_count, 2);
        for (int32_t i = 0; i < after.objects[0].instance_count && i < 2; ++i) {
            const auto &a = before.objects[0].instances[i].transform;
            const auto &b = after.objects[0].instances[i].transform;
            CHECK_NEAR(a.offset_x, b.offset_x, 1e-4);
            CHECK_NEAR(a.offset_y, b.offset_y, 1e-4);
            CHECK_NEAR(a.offset_z, b.offset_z, 1e-4);
            CHECK_NEAR(a.rotation_z, b.rotation_z, 1e-6);
        }
        CHECK_EQ(after.objects[0].index_count, before.objects[0].index_count);
    }
    orca_scene_snapshot_dispose(&before);
    orca_scene_snapshot_dispose(&after);

    CHECK(current_preset(presets2, 0) == "Bambu Lab X1 Carbon 0.4 nozzle");
    CHECK(current_preset(presets2, 2) == "0.20mm Standard @BBL X1C");
    CHECK(config_dump(presets2, 2, 1).find("\"layer_height\":\"0.24\"") != std::string::npos);
    CHECK(config_dump(presets2, 2, 0).find("\"layer_height\":\"0.24\"") == std::string::npos);
    orca_bed_type_state bed{};
    GUARD(g7, orca_presets_bed_type(presets2, &bed));
    expect_ok(g7, "bed type after open");
    CHECK_EQ(bed.current, 4);

    // listed presets report a valid origin; the opened selection is listed
    int32_t count = 0;
    GUARD(g8, orca_presets_list_count(presets2, 1, &count));
    expect_ok(g8, "filament count");
    bool selected_listed = false;
    const std::string filament = current_preset(presets2, 1);
    for (int32_t i = 0; i < count; ++i) {
        orca_preset_entry entry;
        GUARD(ge, orca_presets_list_entry(presets2, 1, i, &entry));
        expect_ok(ge, "entry");
        CHECK(entry.origin <= ORCA_PRESET_ORIGIN_EXTERNAL);
        if (entry.name.data && filament == entry.name.data) selected_listed = true;
        orca_preset_entry_dispose(&entry);
    }
    CHECK(selected_listed);

    orca_plater_free(plater2);
    orca_presets_free(presets2);
    orca_plater_free(plater);
    orca_presets_free(presets);
}

static bool listed_with_origin(orca_presets *presets, int32_t kind,
                               const std::string &name, uint8_t origin) {
    int32_t count = 0;
    GUARD(g, orca_presets_list_count(presets, kind, &count));
    expect_ok(g, "list count");
    for (int32_t i = 0; i < count; ++i) {
        orca_preset_entry entry;
        GUARD(ge, orca_presets_list_entry(presets, kind, i, &entry));
        expect_ok(ge, "list entry");
        const bool match = entry.name.data && name == entry.name.data;
        const uint8_t found_origin = entry.origin;
        orca_preset_entry_dispose(&entry);
        if (match) return found_origin == origin;
    }
    return false;
}

// Desktop C5b: Save preset (SavePresetDialog rules) → persisted user
// preset reloadable by a fresh session → Delete preset.
static void test_user_presets(const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");
    GUARD(g1, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                  "Bambu PLA Basic @BBL X1C", "0.20mm Standard @BBL X1C"));
    expect_ok(g1, "select X1C");
    GUARD(g2, orca_presets_set_value(presets, 2, "layer_height", "0.27"));
    expect_ok(g2, "override");

    // desktop name rules
    const char *bad_names[] = {"", "a/b", " lead", "trail ", "x (modified)", "Default Printer"};
    for (const char *bad : bad_names) {
        GUARD(gb, orca_presets_save_user(presets, 2, bad, 0));
        expect_code(gb, ORCA_STATUS_INVALID_ARGUMENT, bad);
    }
    GUARD(gs, orca_presets_save_user(presets, 2, "0.20mm Standard @BBL X1C", 0));
    expect_code(gs, ORCA_STATUS_INVALID_CONFIGURATION, "overwrite system");
    GUARD(gk, orca_presets_save_user(presets, 9, "x", 0));
    expect_code(gk, ORCA_STATUS_INVALID_ARGUMENT, "bad kind");

    GUARD(g3, orca_presets_save_user(presets, 2, "OrcaPad Test Process", 0));
    expect_ok(g3, "save process");
    CHECK(current_preset(presets, 2) == "OrcaPad Test Process");
    CHECK(listed_with_origin(presets, 2, "OrcaPad Test Process", ORCA_PRESET_ORIGIN_USER));
    // saved values are now the preset's own: no pending modifications
    CHECK(config_dump(presets, 2, 1) == config_dump(presets, 2, 0));
    CHECK(config_dump(presets, 2, 0).find("\"layer_height\":\"0.27\"") != std::string::npos);
    struct stat status;
    CHECK(stat((data_dir + "/user/default/process/OrcaPad Test Process.json").c_str(), &status) == 0);

    // overwrite the same user preset
    GUARD(g4, orca_presets_set_value(presets, 2, "layer_height", "0.26"));
    expect_ok(g4, "override again");
    GUARD(g5, orca_presets_save_user(presets, 2, "OrcaPad Test Process", 0));
    expect_ok(g5, "overwrite user preset");
    CHECK(config_dump(presets, 2, 0).find("\"layer_height\":\"0.26\"") != std::string::npos);

    // filament save scopes a system-derived filament to the current printer
    GUARD(g6, orca_presets_save_user(presets, 1, "OrcaPad Test PLA", 0));
    expect_ok(g6, "save filament");
    CHECK(current_preset(presets, 1) == "OrcaPad Test PLA");
    CHECK(config_dump(presets, 1, 0).find("Bambu Lab X1 Carbon") != std::string::npos);

    // a fresh session reloads the persisted user presets from disk
    orca_presets *fresh = nullptr;
    GUARD(g7, orca_presets_new(data_dir.c_str(), &fresh));
    expect_ok(g7, "presets_new fresh");
    CHECK(listed_with_origin(fresh, 2, "OrcaPad Test Process", ORCA_PRESET_ORIGIN_USER));
    GUARD(g8, orca_presets_select(fresh, "Bambu Lab X1 Carbon 0.4 nozzle",
                                  "OrcaPad Test PLA", "OrcaPad Test Process"));
    expect_ok(g8, "select user presets in fresh session");
    CHECK(config_dump(fresh, 2, 0).find("\"layer_height\":\"0.26\"") != std::string::npos);
    orca_presets_free(fresh);

    // delete
    GUARD(d1, orca_presets_delete_user(presets, 2, "0.20mm Standard @BBL X1C"));
    expect_code(d1, ORCA_STATUS_INVALID_CONFIGURATION, "delete system");
    GUARD(d2, orca_presets_delete_user(presets, 2, "__missing__"));
    expect_code(d2, ORCA_STATUS_NOT_FOUND, "delete missing");
    GUARD(d3, orca_presets_delete_user(presets, 2, "OrcaPad Test Process"));
    expect_ok(d3, "delete selected user process");
    CHECK(current_preset(presets, 2) != "OrcaPad Test Process");
    CHECK(!listed_with_origin(presets, 2, "OrcaPad Test Process", ORCA_PRESET_ORIGIN_USER));
    CHECK(stat((data_dir + "/user/default/process/OrcaPad Test Process.json").c_str(), &status) != 0);
    GUARD(d4, orca_presets_delete_user(presets, 1, "OrcaPad Test PLA"));
    expect_ok(d4, "delete user filament");

    // the session still resolves a full config afterwards
    orca_owned_string resolved;
    GUARD(g9, orca_presets_resolved_config(presets, &resolved));
    expect_ok(g9, "resolved after delete");
    orca_owned_string_dispose(&resolved);
    orca_presets_free(presets);
}

// Physical printers: engine-backed storage, persisted to the data dir,
// reloaded by fresh sessions.
static void test_physical_printers(const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");
    GUARD(gsel, orca_presets_select(presets, "Anycubic Vyper 0.4 nozzle",
                                    "Anycubic Generic PLA",
                                    "0.20mm Standard @Anycubic Vyper"));
    expect_ok(gsel, "select Vyper");

    int32_t count = -1;
    GUARD(g1, orca_physical_printer_count(presets, &count));
    expect_ok(g1, "count");
    CHECK_EQ(count, 0);

    GUARD(e1, orca_physical_printer_upsert(presets, "Vyper", "not_a_host",
                                           "http://192.168.1.5", "", "key", "Anycubic Vyper 0.4 nozzle"));
    expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "bad host type");
    GUARD(e2, orca_physical_printer_upsert(presets, "Vyper", "octoprint",
                                           "ftp://x", "", "key", "Anycubic Vyper 0.4 nozzle"));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "non-http url");
    GUARD(e3, orca_physical_printer_upsert(presets, "Vyper", "octoprint",
                                           "http://192.168.1.5", "", "key", "__missing__"));
    expect_code(e3, ORCA_STATUS_NOT_FOUND, "missing preset");
    GUARD(e5, orca_physical_printer_upsert(presets, "Vyper", "moonraker",
                                           "http://192.168.1.5:7125", "mainsail.local", "",
                                           "Anycubic Vyper 0.4 nozzle"));
    expect_code(e5, ORCA_STATUS_INVALID_ARGUMENT, "non-http web UI");
    GUARD(e6, orca_physical_printer_upsert(presets, "Vyper", "moonraker",
                                           "http://192.168.1.5", nullptr, "",
                                           "Anycubic Vyper 0.4 nozzle"));
    expect_code(e6, ORCA_STATUS_INVALID_ARGUMENT, "null web UI");

    GUARD(g2, orca_physical_printer_upsert(presets, "Vyper", "octoprint",
                                           "http://192.168.1.5", "", "secret", "Anycubic Vyper 0.4 nozzle"));
    expect_ok(g2, "upsert");
    GUARD(g3, orca_physical_printer_count(presets, &count));
    expect_ok(g3, "count after upsert");
    CHECK_EQ(count, 1);
    orca_physical_printer entry;
    GUARD(g4, orca_physical_printer_list(presets, 0, &entry));
    expect_ok(g4, "list");
    CHECK(strcmp(entry.name.data, "Vyper") == 0);
    CHECK(strcmp(entry.host_type.data, "octoprint") == 0);
    CHECK(strcmp(entry.url.data, "http://192.168.1.5") == 0);
    CHECK(strcmp(entry.webui.data, "") == 0);
    CHECK(strcmp(entry.api_key.data, "secret") == 0);
    CHECK(strcmp(entry.preset_names.data, "Anycubic Vyper 0.4 nozzle") == 0);
    orca_physical_printer_dispose(&entry);

    // update in place
    GUARD(g5, orca_physical_printer_upsert(presets, "Vyper", "moonraker",
                                           "http://192.168.1.9:7125", "http://192.168.1.9", "k2",
                                           "Anycubic Vyper 0.4 nozzle"));
    expect_ok(g5, "upsert update");
    GUARD(g6, orca_physical_printer_list(presets, 0, &entry));
    expect_ok(g6, "list after update");
    CHECK(strcmp(entry.host_type.data, "moonraker") == 0);
    CHECK(strcmp(entry.url.data, "http://192.168.1.9:7125") == 0);
    CHECK(strcmp(entry.webui.data, "http://192.168.1.9") == 0);
    orca_physical_printer_dispose(&entry);
    orca_presets_free(presets);

    // persisted: a fresh session reloads it
    orca_presets *fresh = nullptr;
    GUARD(g7, orca_presets_new(data_dir.c_str(), &fresh));
    expect_ok(g7, "presets_new fresh");
    GUARD(g8, orca_physical_printer_count(fresh, &count));
    expect_ok(g8, "count fresh");
    CHECK_EQ(count, 1);
    GUARD(g9, orca_physical_printer_list(fresh, 0, &entry));
    expect_ok(g9, "list fresh");
    CHECK(strcmp(entry.host_type.data, "moonraker") == 0);
    CHECK(strcmp(entry.webui.data, "http://192.168.1.9") == 0);
    orca_physical_printer_dispose(&entry);
    GUARD(g10, orca_physical_printer_delete(fresh, "Vyper"));
    expect_ok(g10, "delete");
    GUARD(g11, orca_physical_printer_count(fresh, &count));
    expect_ok(g11, "count after delete");
    CHECK_EQ(count, 0);
    GUARD(e4, orca_physical_printer_delete(fresh, "Vyper"));
    expect_code(e4, ORCA_STATUS_NOT_FOUND, "delete missing");
    orca_presets_free(fresh);
}

struct CancelOnProgress {
    orca_slice_job *job;
    std::atomic<int> calls{0};
};

static void cancel_trampoline(int32_t percent, const char *, void *context) {
    auto *record = static_cast<CancelOnProgress *>(context);
    // cancel from inside the slicing thread once real work started
    if (percent >= 5 && record->calls.fetch_add(1) == 0)
        orca_slice_job_cancel(record->job);
}

static void test_slice_cancel(const std::string &dir) {
    GUARD(g0, orca_slice_job_new(nullptr));
    expect_code(g0, ORCA_STATUS_INVALID_ARGUMENT, "job_new(null)");
    orca_slice_job_cancel(nullptr); // null-safe
    orca_slice_job_free(nullptr);   // null-safe

    const std::string cube = write_cube_stl(dir, "orcapad-cube8.stl");
    orca_plater *plater = nullptr;
    GUARD(g1, orca_plater_new(&plater));
    expect_ok(g1, "plater_new");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g2, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g2, "add cube");
    const std::string gcode = dir + "/cancel.gcode";

    // cancelled before start: immediate typed cancellation
    orca_slice_job *job = nullptr;
    GUARD(g3, orca_slice_job_new(&job));
    expect_ok(g3, "job_new");
    orca_slice_job_cancel(job);
    orca_slice_report report;
    GUARD(g4, orca_plater_slice_to_gcode(plater, gcode.c_str(), nullptr, nullptr,
                                         job, &report));
    expect_code(g4, ORCA_STATUS_CANCELLED, "slice pre-cancelled");
    CHECK(report.warnings == nullptr && report.gcode_bytes == 0);
    orca_slice_job_free(job);

    // cancelled mid-slice from the progress callback
    orca_slice_job *job2 = nullptr;
    GUARD(g5, orca_slice_job_new(&job2));
    expect_ok(g5, "job_new 2");
    CancelOnProgress record{job2};
    GUARD(g6, orca_plater_slice_to_gcode(plater, gcode.c_str(), cancel_trampoline,
                                         &record, job2, &report));
    expect_code(g6, ORCA_STATUS_CANCELLED, "slice cancelled mid-run");
    orca_slice_job_free(job2);

    // a fresh job slices normally afterwards (no sticky engine state)
    orca_slice_job *job3 = nullptr;
    GUARD(g7, orca_slice_job_new(&job3));
    expect_ok(g7, "job_new 3");
    ProgressRecord progress;
    GUARD(g8, orca_plater_slice_to_gcode(plater, gcode.c_str(), progress_trampoline,
                                         &progress, job3, &report));
    check_slice_outputs(gcode.c_str(), g8, report, progress, "slice after cancel");
    orca_slice_job_free(job3);

    // G-code thumbnails from the job's plate image (default config:
    // 48x48/PNG,300x300/PNG on the non-BBL defaults path)
    orca_slice_job *job4 = nullptr;
    GUARD(g9, orca_slice_job_new(&job4));
    expect_ok(g9, "job_new 4");
    std::vector<uint8_t> image(128 * 128 * 4, 200);
    GUARD(et, orca_slice_job_set_thumbnail(job4, 4, image.data()));
    expect_code(et, ORCA_STATUS_INVALID_ARGUMENT, "thumbnail too small");
    GUARD(g10, orca_slice_job_set_thumbnail(job4, 128, image.data()));
    expect_ok(g10, "set thumbnail");
    ProgressRecord progress4;
    GUARD(g11, orca_plater_slice_to_gcode(plater, gcode.c_str(), progress_trampoline,
                                          &progress4, job4, &report));
    check_slice_outputs(gcode.c_str(), g11, report, progress4, "slice with thumbnail");
    orca_slice_job_free(job4);
    {
        FILE *file = fopen(gcode.c_str(), "r");
        CHECK(file != nullptr);
        bool small = false, large = false;
        char line[512];
        while (file && fgets(line, sizeof line, file)) {
            if (strstr(line, "; thumbnail begin 48x48")) small = true;
            if (strstr(line, "; thumbnail begin 300x300")) large = true;
            if (small && large) break;
        }
        if (file) fclose(file);
        CHECK(small);
        CHECK(large);
    }
    CHECK_EQ(snapshot_revision(plater), revision);
    orca_plater_free(plater);
}

static void test_standalone_slice(const std::string &dir) {
    const std::string cube = write_cube_stl(dir, "orcapad-cube7.stl");
    const std::string gcode = dir + "/standalone.gcode";
    ProgressRecord progress;
    orca_slice_report report;
    GUARD(g1, orca_slice_to_gcode(cube.c_str(), gcode.c_str(),
                                  progress_trampoline, &progress,
                                  nullptr, &report));
    check_slice_outputs(gcode.c_str(), g1, report, progress,
                        "standalone slice");

    GUARD(g2, orca_slice_to_gcode((dir + "/missing.stl").c_str(),
                                  gcode.c_str(), nullptr, nullptr,
                                  nullptr, &report));
    expect_code(g2, ORCA_STATUS_IO_FAILURE, "standalone slice missing input");
}

static void test_gcode_toolpath(const std::string &dir) {
    // reuse the defaults slice output from test_slice_defaults
    const std::string gcode = dir + "/defaults.gcode";
    struct stat status;
    if (stat(gcode.c_str(), &status) != 0) {
        ++checks;
        fail(__FILE__, __LINE__, "defaults.gcode missing (slice test must run first)");
        return;
    }

    // typed rejections
    GUARD(g0, orca_gcode_load(nullptr, nullptr));
    expect_code(g0, ORCA_STATUS_INVALID_ARGUMENT, "gcode_load(null out)");
    GUARD(g1, orca_gcode_load((dir + "/missing.gcode").c_str(), nullptr));
    expect_code(g1, ORCA_STATUS_INVALID_ARGUMENT, "gcode_load(null out 2)");

    orca_gcode *parsed = nullptr;
    GUARD(g2, orca_gcode_load((dir + "/missing.gcode").c_str(), &parsed));
    expect_code(g2, ORCA_STATUS_IO_FAILURE, "gcode_load(missing file)");

    // a file with no parseable moves is a typed model failure
    const std::string empty_gcode = dir + "/empty-file.gcode";
    FILE *file = fopen(empty_gcode.c_str(), "wb");
    if (file) {
        fprintf(file, "; only a comment, nothing printable\n");
        fclose(file);
    }
    orca_gcode *garbage_handle = nullptr;
    GUARD(g3, orca_gcode_load(empty_gcode.c_str(), &garbage_handle));
    ++checks;
    if (g3.ok()) {
        // a bare comment can still emit noop vertices; extraction must
        // then fail loudly on the missing printable moves
        orca_toolpath garbage_tp;
        GUARD(g3b, orca_gcode_toolpath(garbage_handle, &garbage_tp));
        ++checks;
        if (g3b.ok()) {
            orca_toolpath_dispose(&garbage_tp);
            fail(__FILE__, __LINE__, "comment-only gcode must not yield a toolpath");
        } else {
            expect_owned_diagnostic(g3b, "toolpath(comment-only gcode)");
        }
        orca_gcode_free(garbage_handle);
    } else {
        expect_owned_diagnostic(g3, "gcode_load(comment-only gcode)");
    }

    GUARD(g4, orca_gcode_load(gcode.c_str(), &parsed));
    expect_ok(g4, "gcode_load");
    CHECK(parsed != nullptr);

    orca_toolpath toolpath;
    GUARD(g5, orca_gcode_toolpath(nullptr, &toolpath));
    expect_code(g5, ORCA_STATUS_INVALID_HANDLE, "toolpath(null handle)");
    GUARD(g6, orca_gcode_toolpath(parsed, nullptr));
    expect_code(g6, ORCA_STATUS_INVALID_ARGUMENT, "toolpath(null out)");

    GUARD(g7, orca_gcode_toolpath(parsed, &toolpath));
    expect_ok(g7, "toolpath");
    CHECK(toolpath.segment_count > 100);
    CHECK(toolpath.layer_count >= 1);
    CHECK(toolpath.layers != nullptr);
    CHECK(toolpath.segments != nullptr);
    CHECK(toolpath.estimated_time_seconds > 0.0f);
    CHECK(toolpath.printable_height > 0.0f);

    // layers partition the segments exactly
    uint64_t total = 0;
    bool extrusion_seen = false;
    bool travel_seen = false;
    bool roles_seen = false;
    for (uint32_t i = 0; i < toolpath.layer_count; ++i) {
        const orca_tp_layer &layer = toolpath.layers[i];
        CHECK(layer.segment_count > 0);
        total += layer.segment_count;
    }
    CHECK_EQ(total, toolpath.segment_count);
    for (uint32_t i = 0; i < toolpath.segment_count; ++i) {
        const orca_tp_segment &segment = toolpath.segments[i];
        if (segment.move_type == 10) extrusion_seen = true;
        if (segment.move_type == 8) travel_seen = true;
        if (segment.move_type == 10 && segment.role >= 1 && segment.role <= 19)
            roles_seen = true;
    }
    CHECK(extrusion_seen);
    CHECK(travel_seen);
    CHECK(roles_seen); // feature classification survived the parse

    // per-segment time/fan/temperature are sane and layer times aggregate
    // exactly the segment times
    double segment_time = 0.0, layer_time = 0.0;
    bool fan_ok = true, temperature_ok = true, time_ok = true;
    for (uint32_t i = 0; i < toolpath.segment_count; ++i) {
        const orca_tp_segment &segment = toolpath.segments[i];
        segment_time += segment.time_seconds;
        if (!(segment.time_seconds >= 0.0f)) time_ok = false;
        // GCodeProcessor maps M106 S0..255 via (100/255)*S in float, so full
        // speed lands at 100.000008 — allow that rounding, nothing more.
        if (!(segment.fan_speed >= 0.0f && segment.fan_speed <= 100.0f + 1e-3f)) fan_ok = false;
        if (!(segment.temperature >= 0.0f && segment.temperature < 600.0f)) temperature_ok = false;
    }
    for (uint32_t i = 0; i < toolpath.layer_count; ++i)
        layer_time += toolpath.layers[i].time_seconds;
    CHECK(time_ok);
    CHECK(fan_ok);
    CHECK(temperature_ok);
    CHECK_NEAR(segment_time, layer_time, 0.01 * (1.0 + layer_time));
    CHECK(segment_time > 0.0);

    orca_gcode_free(parsed); // toolpath must stay valid after handle free
    CHECK(toolpath.segments[0].end[0] == toolpath.segments[0].end[0]);
    orca_toolpath_dispose(&toolpath);
    orca_toolpath_dispose(&toolpath); // idempotent
    orca_toolpath_dispose(nullptr);
    orca_gcode_free(nullptr);
}

int main() {
    const std::string dir = test_dir();
    // One data directory per PROCESS (the Bridge contract is initialize-once).
    const std::string data_dir = prepare_preset_data_dir(dir);
    fprintf(stderr, "==> contract tests in %s\n", dir.c_str());

    test_md5_shim();
    test_abi_version();
    test_document_lifecycle(dir);
    test_history(dir);
    test_volumes(dir);
    test_mirror_clipboard(dir);
    test_group_transforms(dir);
    test_object_settings(dir);
    test_add_failures(dir);
    test_stable_ids_and_revisions(dir);
    test_not_found_and_validation(dir);
    test_snapshot_ownership(dir);
    test_full_transforms(dir);
    test_multi_object_import(dir);
    test_engine_serialization(dir);
    test_presets(data_dir);
    test_preset_metadata(data_dir);
    test_print_volume(data_dir);
    test_resolved_config(data_dir);
    test_preset_overrides(data_dir);
    test_bed_type(data_dir);
    test_slice_defaults(dir);
    test_slice_with_presets(dir, data_dir);
    test_standalone_slice(dir);
    test_slice_cancel(dir);
    test_project_roundtrip(dir, data_dir);
    test_user_presets(data_dir);
    test_physical_printers(data_dir);
    test_arrange_orient(dir, data_dir);
    test_gcode_toolpath(dir);

    fprintf(stderr, "\n═══ contract tests: %d checks, %d failures ═══\n",
            checks, failures);
    if (failures > 0) {
        fprintf(stderr, "RESULT: FAIL\n");
        return 1;
    }
    fprintf(stderr, "RESULT: PASS\n");
    return 0;
}
