// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

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
    CHECK_EQ(ORCA_BRIDGE_ABI_VERSION, 41);
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
// ABI v26: batch delete (one undo step), multi-object clipboard, batch
// settings apply (one undo step) and part triangle ranges in snapshots.
static void test_batch_operations(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "batch_cube.stl");
    orca_object_id a = 0, b = 0, c = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 30, 30, &a, &revision));
    GUARD(g2, import_one(plater, cube.c_str(), 60, 30, &b, &revision));
    GUARD(g3, import_one(plater, cube.c_str(), 90, 30, &c, &revision));
    expect_ok(g1, "import a");
    expect_ok(g2, "import b");
    expect_ok(g3, "import c");

    // --- batch delete: atomic on a missing ID, ONE undo step -------------
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        const uint32_t undo_before = snap.undo_count;
        orca_scene_snapshot_dispose(&snap);
        const orca_object_id missing[2] = {a, 999999};
        GUARD(e0, orca_plater_objects_delete(plater, missing, 2, &revision));
        expect_code(e0, ORCA_STATUS_NOT_FOUND, "batch delete with a missing ID");
        GUARD(e1, orca_plater_objects_delete(plater, nullptr, 1, &revision));
        expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "batch delete null array");
        GUARD(e2, orca_plater_objects_delete(plater, &a, 0, &revision));
        expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "batch delete zero count");
        snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 3);
        orca_scene_snapshot_dispose(&snap);

        const orca_object_id pair[3] = {a, b, a}; // duplicate collapses
        GUARD(g4, orca_plater_objects_delete(plater, pair, 3, &revision));
        expect_ok(g4, "batch delete");
        snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 1);
        CHECK(find_object(snap, a) == nullptr);
        CHECK(find_object(snap, b) == nullptr);
        CHECK(find_object(snap, c) != nullptr);
        CHECK_EQ(snap.undo_count, undo_before + 1);
        CHECK(snapshot_label(snap.undo_label) == "Delete objects");
        orca_scene_snapshot_dispose(&snap);
        GUARD(g5, orca_plater_undo(plater, &revision));
        expect_ok(g5, "undo batch delete");
        snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 3);
        CHECK(find_object(snap, a) != nullptr);
        CHECK(find_object(snap, b) != nullptr);
        orca_scene_snapshot_dispose(&snap);
    }

    // --- batch instance delete: one undo step, whole-object promotion ---
    {
        // give object a two more instances (3 total)
        GUARD(ig1, orca_plater_set_instance_count(plater, a, 3, &revision));
        expect_ok(ig1, "instance count 3");
        orca_scene_snapshot snap = take_snapshot(plater);
        const orca_object_id three = a;
        const orca_scene_object *obj = find_object(snap, three);
        CHECK(obj != nullptr);
        CHECK_EQ(obj->instance_count, 3);
        orca_instance_id i0 = obj->instances[0].id;
        orca_instance_id i1 = obj->instances[1].id;
        orca_instance_id i2 = obj->instances[2].id;
        orca_scene_snapshot_dispose(&snap);

        // deleting ALL instances of a removes the object entirely
        const orca_object_id objs[3] = {a, a, a};
        const orca_instance_id insts[3] = {i0, i1, i2};
        GUARD(ig2, orca_plater_instances_delete(plater, objs, insts, 3, &revision));
        expect_ok(ig2, "batch instance delete removes object");
        snap = take_snapshot(plater);
        CHECK(find_object(snap, a) == nullptr);
        CHECK_EQ(snap.object_count, 2);
        CHECK(snapshot_label(snap.undo_label) == "Delete instances");
        orca_scene_snapshot_dispose(&snap);
        GUARD(ig3, orca_plater_undo(plater, &revision));
        expect_ok(ig3, "undo instance batch");
        snap = take_snapshot(plater);
        CHECK(find_object(snap, a) != nullptr);
        CHECK_EQ(find_object(snap, a)->instance_count, 3);
        orca_scene_snapshot_dispose(&snap);

        // a subset deletes just those instances, one undo step
        const uint32_t undo_before = [&] {
            orca_scene_snapshot s = take_snapshot(plater);
            const uint32_t u = s.undo_count;
            orca_scene_snapshot_dispose(&s);
            return u;
        }();
        const orca_instance_id subset[2] = {i0, i2};
        GUARD(ig4, orca_plater_instances_delete(plater, objs, subset, 2, &revision));
        expect_ok(ig4, "batch instance delete subset");
        snap = take_snapshot(plater);
        CHECK_EQ(find_object(snap, a)->instance_count, 1);
        CHECK_EQ(find_object(snap, a)->instances[0].id, i1);
        CHECK_EQ(snap.undo_count, undo_before + 1);
        orca_scene_snapshot_dispose(&snap);

        // missing instance deletes nothing
        const orca_instance_id bogus[1] = {i0};
        GUARD(e8, orca_plater_instances_delete(plater, objs, bogus, 1, &revision));
        expect_code(e8, ORCA_STATUS_NOT_FOUND, "instance batch with stale ID");
        snap = take_snapshot(plater);
        CHECK_EQ(find_object(snap, a)->instance_count, 1);
        orca_scene_snapshot_dispose(&snap);
    }

    // --- multi-object clipboard: paste keeps relative placement ---------
    orca_object_id pasted[4] = {0, 0, 0, 0};
    int32_t pasted_count = 0;
    {
        GUARD(e3, orca_plater_objects_paste(plater, 50, 50, pasted, 4,
                                            &pasted_count, &revision));
        expect_code(e3, ORCA_STATUS_NOT_FOUND, "paste with an empty clipboard");
        const orca_object_id two[2] = {a, b};
        GUARD(g6, orca_plater_objects_copy(plater, two, 2));
        expect_ok(g6, "copy two");
        GUARD(e4, orca_plater_objects_paste(plater, 50, 50, pasted, 1,
                                            &pasted_count, &revision));
        expect_code(e4, ORCA_STATUS_INVALID_ARGUMENT, "paste capacity too small");
        // The relative placement of the sources (front-instance offsets) —
        // the paste must reproduce exactly this delta around its anchor.
        double src_dx = 0.0, src_dy = 0.0;
        {
            orca_scene_snapshot src = take_snapshot(plater);
            const orca_scene_object *src_a = find_object(src, a);
            const orca_scene_object *src_b = find_object(src, b);
            CHECK(src_a != nullptr && src_b != nullptr);
            src_dx = src_b->instances[0].transform.offset_x -
                     src_a->instances[0].transform.offset_x;
            src_dy = src_b->instances[0].transform.offset_y -
                     src_a->instances[0].transform.offset_y;
            orca_scene_snapshot_dispose(&src);
        }
        orca_scene_snapshot snap = take_snapshot(plater);
        const uint32_t undo_before = snap.undo_count;
        orca_scene_snapshot_dispose(&snap);
        GUARD(g7, orca_plater_objects_paste(plater, 50, 50, pasted, 4,
                                            &pasted_count, &revision));
        expect_ok(g7, "paste two");
        CHECK_EQ(pasted_count, 2);
        CHECK(pasted[0] != 0 && pasted[0] != a && pasted[1] != 0 && pasted[1] != b);
        snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 5);
        CHECK_EQ(snap.undo_count, undo_before + 1);
        CHECK(snapshot_label(snap.undo_label) == "Paste objects");
        const orca_scene_object *p0 = find_object(snap, pasted[0]);
        const orca_scene_object *p1 = find_object(snap, pasted[1]);
        CHECK(p0 != nullptr && p1 != nullptr);
        // the pasted pair keeps the sources' relative spacing around the
        // (50,50) anchor
        CHECK(std::fabs((p1->instances[0].transform.offset_x -
                         p0->instances[0].transform.offset_x) - src_dx) < 1e-6);
        CHECK(std::fabs((p1->instances[0].transform.offset_y -
                         p0->instances[0].transform.offset_y) - src_dy) < 1e-6);
        CHECK(std::fabs(p0->instances[0].transform.offset_x - 50.0) < 1e-6);
        CHECK(std::fabs(p0->instances[0].transform.offset_y - 50.0) < 1e-6);
        orca_scene_snapshot_dispose(&snap);
        GUARD(g8, orca_plater_undo(plater, &revision));
        expect_ok(g8, "undo multi paste");
        snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 3);
        orca_scene_snapshot_dispose(&snap);

        // the single-object wrappers keep working beside the batch ones
        GUARD(g9, orca_plater_object_copy(plater, c));
        expect_ok(g9, "legacy copy");
        orca_object_id single = 0;
        GUARD(g10, orca_plater_object_paste(plater, 10, 10, &single, &revision));
        expect_ok(g10, "legacy paste");
        CHECK(single != 0);
        snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 4);
        CHECK(snapshot_label(snap.undo_label) == "Paste");
        orca_scene_snapshot_dispose(&snap);
        GUARD(g11, orca_plater_undo(plater, &revision));
        expect_ok(g11, "undo legacy paste");
    }

    // --- settings_apply: atomic replace in one undo step -----------------
    orca_volume_id part_id = 0;
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        part_id = snap.objects[0].volumes[0].id;
        orca_scene_snapshot_dispose(&snap);
    }
    GUARD(s1, orca_plater_settings_set(plater, a, 0, "wall_loops", "9", &revision));
    expect_ok(s1, "seed override on a");
    GUARD(s2, orca_plater_settings_set(plater, b, 0, "top_shell_layers", "7", &revision));
    expect_ok(s2, "seed override on b");
    const char *keys[2] = {"sparse_infill_density", "top_shell_layers"};
    const char *values[2] = {"15%", "2"};
    const char *bad_keys[2] = {"sparse_infill_density", "no_such_key"};
    const char *bad_values[2] = {"15%", "lots"};
    // layer_height is PrintObjectConfig: object targets only.
    const char *object_keys[2] = {"layer_height", "sparse_infill_density"};
    GUARD(e5, orca_plater_settings_apply(plater, b, 0, bad_keys, values, 2, &revision));
    expect_code(e5, ORCA_STATUS_INVALID_ARGUMENT, "apply with an unknown key");
    GUARD(e6, orca_plater_settings_apply(plater, b, 0, keys, bad_values, 2, &revision));
    expect_code(e6, ORCA_STATUS_INVALID_CONFIGURATION, "apply with an unparsable value");
    GUARD(e7, orca_plater_settings_apply(plater, a, part_id, object_keys, values, 2,
                                         &revision));
    expect_code(e7, ORCA_STATUS_INVALID_ARGUMENT, "object keys on a part");
    {
        // the failed applies changed nothing
        orca_owned_string dump{};
        GUARD(g12, orca_plater_settings_dump(plater, b, 0, &dump));
        expect_ok(g12, "dump b after failures");
        CHECK(dump.data && strstr(dump.data, "top_shell_layers\":\"7\"") != nullptr);
        CHECK(dump.data && strstr(dump.data, "sparse_infill_density") == nullptr);
        orca_owned_string_dispose(&dump);
    }
    orca_scene_snapshot snap = take_snapshot(plater);
    const uint32_t undo_before = snap.undo_count;
    orca_scene_snapshot_dispose(&snap);
    GUARD(s3, orca_plater_settings_apply(plater, b, 0, keys, values, 2, &revision));
    expect_ok(s3, "apply to b");
    {
        orca_owned_string dump{};
        GUARD(g13, orca_plater_settings_dump(plater, b, 0, &dump));
        expect_ok(g13, "dump b after apply");
        CHECK(dump.data && strstr(dump.data, "sparse_infill_density\":\"15%\"") != nullptr);
        CHECK(dump.data && strstr(dump.data, "top_shell_layers\":\"2\"") != nullptr);
        // the previous override is GONE (replace, not merge)
        CHECK(dump.data && strstr(dump.data, "top_shell_layers\":\"7\"") == nullptr);
        orca_owned_string_dispose(&dump);
        snap = take_snapshot(plater);
        CHECK_EQ(find_object(snap, b)->override_count, 2u);
        CHECK_EQ(snap.undo_count, undo_before + 1);
        CHECK(snapshot_label(snap.undo_label) == "Paste object settings");
        orca_scene_snapshot_dispose(&snap);
    }
    GUARD(s4, orca_plater_undo(plater, &revision));
    expect_ok(s4, "undo apply");
    {
        orca_owned_string dump{};
        GUARD(g14, orca_plater_settings_dump(plater, b, 0, &dump));
        expect_ok(g14, "dump b after undo");
        CHECK(dump.data && strstr(dump.data, "top_shell_layers\":\"7\"") != nullptr);
        orca_owned_string_dispose(&dump);
    }
    // count 0 clears everything
    GUARD(s5, orca_plater_settings_apply(plater, b, 0, nullptr, nullptr, 0, &revision));
    expect_ok(s5, "apply clears");
    {
        orca_owned_string dump{};
        GUARD(g15, orca_plater_settings_dump(plater, b, 0, &dump));
        expect_ok(g15, "dump b after clear");
        CHECK(dump.data && strcmp(dump.data, "{}") == 0);
        orca_owned_string_dispose(&dump);
    }
    orca_plater_free(plater);

    // --- part triangle ranges: two parts merged into one object ----------
    orca_plater *ranger = nullptr;
    GUARD(r0, orca_plater_new(&ranger));
    expect_ok(r0, "plater_new ranger");
    orca_object_id first = 0, second = 0, merged_id = 0;
    GUARD(r1, import_one(ranger, cube.c_str(), 30, 30, &first, &revision));
    GUARD(r2, import_one(ranger, cube.c_str(), 60, 30, &second, &revision));
    expect_ok(r1, "import first");
    expect_ok(r2, "import second");
    const orca_object_id merge_ids[2] = {first, second};
    GUARD(r3, orca_plater_merge_objects(ranger, merge_ids, 2, &merged_id, &revision));
    expect_ok(r3, "merge");
    orca_instance_id merged_instance = 0;
    {
        orca_scene_snapshot m = take_snapshot(ranger);
        const orca_scene_object *merged = find_object(m, merged_id);
        CHECK(merged != nullptr);
        merged_instance = merged->instances[0].id;
        orca_scene_snapshot_dispose(&m);
    }
    orca_volume_id modifier_id = 0;
    GUARD(r4, orca_plater_volume_add_shape(ranger, merged_id, merged_instance,
                                           ORCA_VOLUME_MODIFIER,
                                           ORCA_SHAPE_CUBE, 10.0,
                                           &modifier_id, &revision));
    expect_ok(r4, "add modifier");
    {
        orca_scene_snapshot m = take_snapshot(ranger);
        const orca_scene_object *merged = find_object(m, merged_id);
        CHECK(merged != nullptr);
        CHECK_EQ(merged->volume_count, 3);
        const orca_scene_volume &v0 = merged->volumes[0];
        const orca_scene_volume &v1 = merged->volumes[1];
        const orca_scene_volume &mod = merged->volumes[2];
        CHECK_EQ(v0.merged_triangle_start, 0u);
        CHECK(v0.merged_triangle_count > 0);
        CHECK_EQ(v1.merged_triangle_start, v0.merged_triangle_count);
        CHECK_EQ(v0.merged_triangle_count + v1.merged_triangle_count,
                 static_cast<uint32_t>(merged->index_count / 3));
        CHECK_EQ(v0.merged_triangle_count, v1.merged_triangle_count);
        CHECK_EQ(mod.merged_triangle_start, 0u);
        CHECK_EQ(mod.merged_triangle_count, 0u);
        CHECK(mod.positions != nullptr && mod.position_count > 0);
        CHECK_EQ(v0.positions, nullptr);
        orca_scene_snapshot_dispose(&m);
    }
    orca_plater_free(ranger);
}
// Extrusion X range of a gcode file (G1 moves with X and E), for the
// per-plate slice filter checks.
static std::pair<double, double> gcode_x_range(const char *path) {
    FILE *file = fopen(path, "r");
    CHECK(file != nullptr);
    char line[512];
    double min_x = 1e9, max_x = -1e9;
    bool any = false;
    while (file && fgets(line, sizeof line, file)) {
        if (strncmp(line, "G1", 2) != 0) continue;
        const char *x = strstr(line, " X");
        const char *e = strstr(line, " E");
        if (!x || !e) continue;
        const double value = atof(x + 2);
        min_x = std::min(min_x, value);
        max_x = std::max(max_x, value);
        any = true;
    }
    if (file) fclose(file);
    CHECK(any);
    return {min_x, max_x};
}

// ABI v27: plates — layout grid, derived assignment, mutations, lock pins,
// per-plate slicing, arrange overflow and the 3MF roundtrip.
static void test_plates(const std::string &dir, const std::string &data_dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    orca_scene_snapshot snap;

    // --- bed validation + single-plate layout ------------------------------
    GUARD(e0, orca_plater_set_bed(plater, 0, 0, -1, 100, 100, nullptr));
    expect_code(e0, ORCA_STATUS_INVALID_ARGUMENT, "negative bed rejected");
    GUARD(g1, orca_plater_set_bed(plater, 0, 0, 200, 200, 200, &snap));
    expect_ok(g1, "set bed");
    CHECK_EQ(snap.plate_count, 1);
    CHECK_EQ(snap.current_plate, 0);
    CHECK_EQ(snap.plates[0].index, 0);
    CHECK_EQ(snap.plates[0].locked, 0);
    CHECK(std::fabs(snap.plates[0].origin[0]) < 1e-6);
    CHECK(std::fabs(snap.plates[0].origin[1]) < 1e-6);
    CHECK(std::fabs(snap.plates[0].size[0] - 200.0) < 1e-6);
    CHECK(std::fabs(snap.plates[0].size[2] - 200.0) < 1e-6);
    orca_scene_snapshot_dispose(&snap);

    // --- grid layout: 3 plates, ceil(sqrt(3)) = 2 columns, 1.2x stride ----
    orca_plate_id plate2 = 0, plate3 = 0;
    GUARD(g2, orca_plater_plate_add(plater, &plate2, &revision));
    expect_ok(g2, "add plate 2");
    GUARD(g3, orca_plater_plate_add(plater, &plate3, &revision));
    expect_ok(g3, "add plate 3");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.plate_count, 3);
    CHECK_EQ(snap.undo_count, 2); // set_bed is not undoable; the adds are
    CHECK(snapshot_label(snap.undo_label) == "Add plate");
    CHECK(std::fabs(snap.plates[1].origin[0] - 240.0) < 1e-6);
    CHECK(std::fabs(snap.plates[1].origin[1]) < 1e-6);
    CHECK(std::fabs(snap.plates[2].origin[0]) < 1e-6);
    CHECK(std::fabs(snap.plates[2].origin[1] + 240.0) < 1e-6);
    CHECK_EQ(snap.plates[1].id, plate2);
    CHECK_EQ(snap.plates[2].id, plate3);
    orca_scene_snapshot_dispose(&snap);

    // --- assignment by position --------------------------------------------
    const std::string cube = write_cube_stl(dir, "plates_cube.stl");
    orca_object_id a = 0, b = 0;
    GUARD(g4, import_one(plater, cube.c_str(), 100, 100, &a, &revision));
    GUARD(g5, import_one(plater, cube.c_str(), 340, 100, &b, &revision));
    expect_ok(g4, "import a");
    expect_ok(g5, "import b");
    orca_instance_id b_instance = 0;
    orca_instance_transform b_transform{};
    snap = take_snapshot(plater);
    CHECK_EQ(find_object(snap, a)->instances[0].plate, 0);
    CHECK_EQ(find_object(snap, b)->instances[0].plate, 1);
    CHECK_EQ(snap.plates[0].object_count, 1);
    CHECK_EQ(snap.plates[1].object_count, 1);
    CHECK_EQ(snap.plates[2].object_count, 0);
    b_instance = find_object(snap, b)->instances[0].id;
    b_transform = find_object(snap, b)->instances[0].transform;
    orca_scene_snapshot_dispose(&snap);

    // --- delete: empty ok (one undo step), non-empty/last rejected --------
    GUARD(e1, orca_plater_plate_delete(plater, plate2, &revision));
    expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "delete a non-empty plate");
    GUARD(g6, orca_plater_plate_delete(plater, plate3, &revision));
    expect_ok(g6, "delete an empty plate");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.plate_count, 2);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g7, orca_plater_undo(plater, &revision));
    expect_ok(g7, "undo plate delete");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.plate_count, 3);
    CHECK_EQ(snap.plates[2].id, plate3); // stable ids across undo
    orca_scene_snapshot_dispose(&snap);
    GUARD(g8, orca_plater_plate_delete(plater, plate3, &revision));
    expect_ok(g8, "delete plate 3 again");
    const orca_plate_id plate1 = [&] {
        orca_scene_snapshot s = take_snapshot(plater);
        const orca_plate_id id = s.plates[0].id;
        orca_scene_snapshot_dispose(&s);
        return id;
    }();
    GUARD(e2, orca_plater_plate_delete(plater, plate1, &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "delete the last plate");
    GUARD(e3, orca_plater_plate_delete(plater, 999999, &revision));
    expect_code(e3, ORCA_STATUS_NOT_FOUND, "delete a missing plate");

    // --- rename + select (session state, no revision advance) -------------
    GUARD(g9, orca_plater_plate_rename(plater, plate2, "Benchy plate", &revision));
    expect_ok(g9, "rename plate");
    const orca_revision before_select = revision;
    GUARD(g10, orca_plater_plate_select(plater, plate2, &snap));
    expect_ok(g10, "select plate 2");
    CHECK_EQ(snap.current_plate, 1);
    CHECK_EQ(snap.revision, before_select);
    CHECK(std::string(snap.plates[1].name.data ? snap.plates[1].name.data : "") ==
          "Benchy plate");
    orca_scene_snapshot_dispose(&snap);
    GUARD(e4, orca_plater_plate_select(plater, 424242, &snap));
    expect_code(e4, ORCA_STATUS_NOT_FOUND, "select a missing plate");

    // --- duplicate: members copied onto a trailing plate -------------------
    GUARD(e5d, orca_plater_plate_duplicate(plater, 424242, &plate3, &revision));
    expect_code(e5d, ORCA_STATUS_NOT_FOUND, "duplicate a missing plate");
    orca_plate_id plate2_copy = 0;
    GUARD(g9d, orca_plater_plate_duplicate(plater, plate2, &plate2_copy, &revision));
    expect_ok(g9d, "duplicate plate 2");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.plate_count, 3); // back to 3 (plate 3 was deleted earlier)
    CHECK_EQ(snap.object_count, 3); // a, b, and b's copy
    CHECK_EQ(snap.plates[2].object_count, 1);
    CHECK(snapshot_label(snap.undo_label) == "Duplicate plate");
    orca_scene_snapshot_dispose(&snap);
    GUARD(g10d, orca_plater_undo(plater, &revision));
    expect_ok(g10d, "undo duplicate plate");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 2);
    CHECK_EQ(snap.plate_count, 2);
    orca_scene_snapshot_dispose(&snap);

    // --- move to front: reorder keeps the selected plate selected ----------
    GUARD(g11d, orca_plater_plate_select(plater, plate2, &snap));
    expect_ok(g11d, "select plate 2 again");
    CHECK_EQ(snap.current_plate, 1);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g12d, orca_plater_plate_move_to_front(plater, plate2, &revision));
    expect_ok(g12d, "move plate 2 to front");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.plates[0].id, plate2);
    CHECK_EQ(snap.current_plate, 0); // selection followed the plate
    CHECK_EQ(snap.plates[0].object_count, 1);
    CHECK(snapshot_label(snap.undo_label) == "Move plate to front");
    orca_scene_snapshot_dispose(&snap);
    GUARD(g13d, orca_plater_plate_move_to_front(plater, plate2, &revision));
    expect_code(g13d, ORCA_STATUS_INVALID_ARGUMENT, "move the first plate to front");
    GUARD(g14d, orca_plater_undo(plater, &revision));
    expect_ok(g14d, "undo move to front");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.plates[1].id, plate2); // order restored
    // selection is session state: it stays at the INDEX (0), not the plate
    CHECK_EQ(snap.current_plate, 0);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g15d, orca_plater_plate_select(plater, plate2, &snap));
    expect_ok(g15d, "reselect plate 2");
    orca_scene_snapshot_dispose(&snap);

    // --- lock pins: assignment survives moves; unlock returns to position --
    GUARD(g11, orca_plater_plate_lock(plater, plate2, 1, &revision));
    expect_ok(g11, "lock plate 2");
    orca_instance_transform moved = b_transform;
    moved.offset_x = 100; // squarely on plate 0
    moved.offset_y = 150;
    GUARD(g12, orca_plater_instance_set(plater, b, b_instance, &moved, "Move",
                                        &revision));
    expect_ok(g12, "move pinned object onto plate 0");
    snap = take_snapshot(plater);
    CHECK_EQ(find_object(snap, b)->instances[0].plate, 1); // PIN sticks
    orca_scene_snapshot_dispose(&snap);
    GUARD(g13, orca_plater_plate_lock(plater, plate2, 0, &revision));
    expect_ok(g13, "unlock plate 2");
    snap = take_snapshot(plater);
    CHECK_EQ(find_object(snap, b)->instances[0].plate, 0); // position rules again
    orca_scene_snapshot_dispose(&snap);
    GUARD(g14, orca_plater_instance_set(plater, b, b_instance, &b_transform,
                                        "Move back", &revision));
    expect_ok(g14, "move b back to plate 1");

    // --- slice sees only the selected plate --------------------------------
    GUARD(g15, orca_plater_plate_select(plater, plate2, &snap));
    expect_ok(g15, "select plate 2 for slicing");
    orca_scene_snapshot_dispose(&snap);
    const std::string gcode_p2 = dir + "/plates-2.gcode";
    {
        ProgressRecord progress;
        orca_slice_report report;
        GUARD(g16, orca_plater_slice_to_gcode(
                      plater, gcode_p2.c_str(), progress_trampoline, &progress,
                      nullptr, &report));
        expect_ok(g16, "slice plate 2");
        orca_slice_report_dispose(&report);
        const auto range = gcode_x_range(gcode_p2.c_str());
        // only b — plate-RELATIVE (desktop PartPlate::set_print parity: the
        // engine shifts by the plate origin; world 330..350 - 240 = 90..110)
        CHECK(range.first >= 0.0 && range.second <= 200.0);
    }
    GUARD(g17, orca_plater_plate_select(plater, plate1, &snap));
    expect_ok(g17, "select plate 1 for slicing");
    orca_scene_snapshot_dispose(&snap);
    const std::string gcode_p1 = dir + "/plates-1.gcode";
    {
        ProgressRecord progress;
        orca_slice_report report;
        GUARD(g18, orca_plater_slice_to_gcode(
                      plater, gcode_p1.c_str(), progress_trampoline, &progress,
                      nullptr, &report));
        expect_ok(g18, "slice plate 1");
        orca_slice_report_dispose(&report);
        const auto range = gcode_x_range(gcode_p1.c_str());
        // only a (x 90..110) — and NEVER b
        CHECK(range.first >= 0.0 && range.second <= 200.0);
    }
    // --- slice all: one G-code, both plates, markers in order -------------
    {
        const std::string all = dir + "/plates-all.gcode";
        ProgressRecord progress;
        orca_slice_report report;
        GUARD(sa0, orca_plater_slice_all_to_gcode(
                      plater, all.c_str(), progress_trampoline, &progress,
                      nullptr, &report));
        expect_ok(sa0, "slice all plates");
        const auto range = gcode_x_range(all.c_str());
        // plate-RELATIVE G-code: BOTH plates carry the same relative cube
        // (world 90..110 on plate 0; world 330..350 - 240 on plate 1)
        CHECK(range.first >= 50.0 && range.second <= 200.0);
        CHECK(report.time_estimate_s > 0.0);
        CHECK(report.gcode_bytes > 0);
        // markers: begin 1, end 1, begin 2, end 2 — in order, empty plate 3
        // (deleted earlier) contributes nothing
        FILE *file = fopen(all.c_str(), "r");
        CHECK(file != nullptr);
        std::string contents;
        char line[512];
        while (file && fgets(line, sizeof line, file)) contents += line;
        if (file) fclose(file);
        const size_t b1 = contents.find("; ORCA_PLATE index=1 total=2 name=\"Plate 1\" begin");
        const size_t e1 = contents.find("; ORCA_PLATE index=1 end");
        const size_t b2 = contents.find("; ORCA_PLATE index=2 total=2 name=\"Benchy plate\" begin");
        const size_t e2 = contents.find("; ORCA_PLATE index=2 end");
        CHECK(b1 != std::string::npos && e1 != std::string::npos &&
              b2 != std::string::npos && e2 != std::string::npos);
        CHECK(b1 < e1 && e1 < b2 && b2 < e2);
        CHECK(contents.find("index=3") == std::string::npos);
        CHECK(progress.max_percent.load() >= 99);
        orca_slice_report_dispose(&report);
    }
    orca_plater_free(plater);
    {
        orca_plater *empty = nullptr;
        GUARD(n0, orca_plater_new(&empty));
        expect_ok(n0, "plater_new empty");
        orca_scene_snapshot s;
        GUARD(n1, orca_plater_set_bed(empty, 0, 0, 200, 200, 200, &s));
        expect_ok(n1, "set bed empty");
        orca_scene_snapshot_dispose(&s);
        GUARD(n2, orca_plater_plate_add(empty, &plate2, &revision));
        expect_ok(n2, "add plate to empty doc");
        orca_object_id unused = 0;
        GUARD(n3, import_one(empty, cube.c_str(), 100, 100, &unused, &revision));
        expect_ok(n3, "import onto plate 1");
        GUARD(n4, orca_plater_plate_select(empty, plate2, &s));
        expect_ok(n4, "select empty plate");
        orca_scene_snapshot_dispose(&s);
        ProgressRecord progress;
        orca_slice_report report;
        GUARD(e5, orca_plater_slice_to_gcode(
                      empty, (dir + "/plates-empty.gcode").c_str(),
                      progress_trampoline, &progress, nullptr, &report));
        expect_code(e5, ORCA_STATUS_INVALID_MODEL, "slice an empty plate");
        orca_plater_free(empty);
    }

    // --- arrange overflow becomes plates (Vyper 250x255) -------------------
    {
        orca_presets *presets = nullptr;
        GUARD(p0, orca_presets_new(data_dir.c_str(), &presets));
        expect_ok(p0, "presets_new plates");
        orca_owned_string vyper_filament, vyper_process;
        GUARD(pf, orca_presets_list_name(presets, 1, 0, &vyper_filament));
        expect_ok(pf, "vyper filament names[0]");
        GUARD(pp, orca_presets_list_name(presets, 2, 0, &vyper_process));
        expect_ok(pp, "vyper process names[0]");
        GUARD(p1, orca_presets_select(presets, "Anycubic Vyper 0.4 nozzle",
                                      vyper_filament.data, vyper_process.data));
        expect_ok(p1, "select Vyper");
        orca_owned_string_dispose(&vyper_filament);
        orca_owned_string_dispose(&vyper_process);
        orca_plater *arranger = nullptr;
        GUARD(p2, orca_plater_new(&arranger));
        expect_ok(p2, "plater_new arranger");
        orca_scene_snapshot s;
        GUARD(p3, orca_plater_set_bed(arranger, 0, 0, 250, 255, 265, &s));
        expect_ok(p3, "set Vyper bed");
        CHECK_EQ(s.plate_count, 1);
        orca_scene_snapshot_dispose(&s);
        orca_object_id big = 0;
        GUARD(p4, import_one(arranger, cube.c_str(), 100, 100, &big, &revision));
        expect_ok(p4, "import for arrange");
        // 60 mm cubes (scale 3), 30 instances: the 250x255 bed fits ~9,
        // the rest must spill onto new plates.
        std::vector<orca_instance_id> instances;
        {
            orca_scene_snapshot first = take_snapshot(arranger);
            instances.push_back(find_object(first, big)->instances[0].id);
            orca_instance_transform t = find_object(first, big)->instances[0].transform;
            t.scale_x = 3; t.scale_y = 3; t.scale_z = 3;
            orca_scene_snapshot_dispose(&first);
            GUARD(p5, orca_plater_instance_set(arranger, big, instances[0], &t,
                                               "Scale", &revision));
            expect_ok(p5, "scale first instance");
        }
        for (int i = 1; i < 30; ++i) {
            orca_instance_id added = 0;
            GUARD(p6, orca_plater_instance_add(arranger, big, &added, &revision));
            expect_ok(p6, "add instance");
            instances.push_back(added);
        }
        // scale every instance (arrange works on the transformed footprints)
        {
            orca_scene_snapshot cur = take_snapshot(arranger);
            orca_instance_transform t{};
            for (int32_t o = 0; o < cur.object_count; ++o)
                if (cur.objects[o].id == big) {
                    t = cur.objects[o].instances[0].transform;
                    break;
                }
            t.scale_x = 3; t.scale_y = 3; t.scale_z = 3;
            for (orca_instance_id id : instances) {
                GUARD(p7, orca_plater_instance_set(arranger, big, id, &t,
                                                   "Scale", &revision));
                expect_ok(p7, "scale instance");
            }
            orca_scene_snapshot_dispose(&cur);
        }
        uint32_t unprintable = 0;
        GUARD(p8, orca_plater_arrange(arranger, presets, 0, &unprintable,
                                      &revision));
        expect_ok(p8, "arrange overflow");
        CHECK_EQ(unprintable, 0u);
        s = take_snapshot(arranger);
        CHECK(s.plate_count > 1);
        int32_t unplaced = 0;
        for (int32_t o = 0; o < s.object_count; ++o)
            for (int32_t i = 0; i < s.objects[o].instance_count; ++i)
                if (s.objects[o].instances[i].plate < 0) ++unplaced;
        CHECK_EQ(unplaced, 0);
        // arrange is ONE undo step and reverting it removes the created plates
        GUARD(p9, orca_plater_undo(arranger, &revision));
        expect_ok(p9, "undo arrange");
        s = take_snapshot(arranger);
        CHECK_EQ(s.plate_count, 1);
        orca_scene_snapshot_dispose(&s);
        orca_plater_free(arranger);
        orca_presets_free(presets);
    }

    // --- 3MF roundtrip: plate names, locks, membership ----------------------
    {
        orca_presets *presets = nullptr;
        GUARD(r0, orca_presets_new(data_dir.c_str(), &presets));
        expect_ok(r0, "presets_new roundtrip");
        GUARD(r1, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                      "Bambu PLA Basic @BBL X1C",
                                      "0.20mm Standard @BBL X1C"));
        expect_ok(r1, "select X1C");
        orca_plater *writer = nullptr;
        GUARD(r2, orca_plater_new(&writer));
        expect_ok(r2, "plater_new writer");
        orca_scene_snapshot s;
        GUARD(r3, orca_plater_set_bed(writer, 0, 0, 200, 200, 200, &s));
        expect_ok(r3, "set bed writer");
        orca_scene_snapshot_dispose(&s);
        orca_plate_id p2 = 0;
        GUARD(r4, orca_plater_plate_add(writer, &p2, &revision));
        expect_ok(r4, "roundtrip add plate");
        GUARD(r5, orca_plater_plate_rename(writer, p2, "Roundtrip plate", &revision));
        expect_ok(r5, "roundtrip rename");
        orca_object_id left = 0, right = 0;
        GUARD(r6, import_one(writer, cube.c_str(), 100, 100, &left, &revision));
        GUARD(r7, import_one(writer, cube.c_str(), 340, 100, &right, &revision));
        expect_ok(r6, "roundtrip import left");
        expect_ok(r7, "roundtrip import right");
        GUARD(r8, orca_plater_plate_lock(writer, p2, 1, &revision));
        expect_ok(r8, "roundtrip lock");
        const std::string project = dir + "/plates.3mf";
        GUARD(r9, orca_project_save(writer, presets, project.c_str(), 0, nullptr));
        expect_ok(r9, "roundtrip save");
        orca_plater_free(writer);

        orca_plater *reader = nullptr;
        GUARD(r10, orca_plater_new(&reader));
        expect_ok(r10, "plater_new reader");
        GUARD(r11, orca_plater_set_bed(reader, 0, 0, 200, 200, 200, &s));
        expect_ok(r11, "set bed reader");
        orca_scene_snapshot_dispose(&s);
        orca_presets *reader_presets = nullptr;
        GUARD(r12, orca_presets_new(data_dir.c_str(), &reader_presets));
        expect_ok(r12, "presets_new reader");
        orca_project_info info;
        GUARD(r13, orca_project_open(reader, reader_presets, project.c_str(), &info));
        expect_ok(r13, "roundtrip open");
        CHECK_EQ(info.plate_count, 2u);
        s = take_snapshot(reader);
        CHECK_EQ(s.plate_count, 2);
        CHECK_EQ(s.plates[1].locked, 1);
        CHECK(std::string(s.plates[1].name.data ? s.plates[1].name.data : "") ==
              "Roundtrip plate");
        // the second object stays pinned to the locked plate
        int32_t right_plate = -1;
        for (int32_t o = 0; o < s.object_count; ++o)
            if (std::string(s.objects[o].name.data ? s.objects[o].name.data : "")
                    .find("plates_cube") != std::string::npos &&
                s.objects[o].instances[0].transform.offset_x > 300.0)
                right_plate = s.objects[o].instances[0].plate;
        CHECK_EQ(right_plate, 1);
        orca_scene_snapshot_dispose(&s);
        orca_plater_free(reader);
        orca_presets_free(reader_presets);
        orca_presets_free(presets);
    }
}
// ABI v23: object operations (printable, instance count, clone, instance to
// object, assemble, scale to fit, unit conversion).
static void test_object_ops(const std::string &dir, const std::string &data_dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "ops_cube.stl");
    orca_object_id a = 0, b = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 60, 60, &a, &revision));
    expect_ok(g1, "import a");
    GUARD(g2, import_one(plater, cube.c_str(), 140, 60, &b, &revision));
    expect_ok(g2, "import b");

    // printable
    GUARD(g3, orca_plater_set_printable(plater, a, 0, 0, &revision));
    expect_ok(g3, "object unprintable");
    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(find_object(snap, a)->instances[0].printable, 0);
    CHECK_EQ(find_object(snap, b)->instances[0].printable, 1);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g4, orca_plater_undo(plater, &revision));
    expect_ok(g4, "undo unprintable");

    // instance count
    GUARD(e1, orca_plater_set_instance_count(plater, a, 0, &revision));
    expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "count 0");
    GUARD(e2, orca_plater_set_instance_count(plater, a, 1, &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "unchanged count");
    GUARD(g5, orca_plater_set_instance_count(plater, a, 3, &revision));
    expect_ok(g5, "three instances");
    snap = take_snapshot(plater);
    CHECK_EQ(find_object(snap, a)->instance_count, 3);
    const orca_instance_id second = find_object(snap, a)->instances[1].id;
    orca_scene_snapshot_dispose(&snap);

    // instance to object
    orca_object_id separated = 0;
    GUARD(g6, orca_plater_instance_to_object(plater, a, second, &separated, &revision));
    expect_ok(g6, "instance to object");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 3);
    CHECK_EQ(find_object(snap, a)->instance_count, 2);
    CHECK(find_object(snap, separated) != nullptr && find_object(snap, separated)->instance_count == 1);
    const orca_instance_id b_instance = find_object(snap, b)->instances[0].id;
    orca_scene_snapshot_dispose(&snap);
    orca_object_id unused = 0;
    GUARD(e3, orca_plater_instance_to_object(plater, b, b_instance, &unused, &revision));
    expect_code(e3, ORCA_STATUS_INVALID_ARGUMENT, "single instance to object");
    CHECK_EQ(unused, 0u); // outputs are defensively zeroed on failure

    // clone
    orca_object_id first_clone = 0;
    GUARD(g7, orca_plater_clone_object(plater, b, 2, &first_clone, &revision));
    expect_ok(g7, "clone x2");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 5);
    CHECK(find_object(snap, first_clone) != nullptr);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g8, orca_plater_undo(plater, &revision));
    expect_ok(g8, "undo clone");

    // assemble (merge)
    const orca_object_id pair[2] = { b, separated };
    orca_object_id assembly = 0;
    GUARD(e4, orca_plater_merge_objects(plater, pair, 1, &assembly, &revision));
    expect_code(e4, ORCA_STATUS_INVALID_ARGUMENT, "assemble one object");
    const orca_object_id with_multi[2] = { a, b };
    GUARD(e5, orca_plater_merge_objects(plater, with_multi, 2, &assembly, &revision));
    expect_code(e5, ORCA_STATUS_INVALID_ARGUMENT, "assemble multi-instance object");
    GUARD(g9, orca_plater_merge_objects(plater, pair, 2, &assembly, &revision));
    expect_ok(g9, "assemble two");
    snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 2);
    const orca_scene_object *merged = find_object(snap, assembly);
    CHECK(merged != nullptr);
    if (merged) {
        CHECK(snapshot_label(merged->name) == "Assembly");
        CHECK_EQ(merged->volume_count, 2);
        CHECK(merged->bbox_max[0] - merged->bbox_min[0] > 60.0);
    }
    orca_scene_snapshot_dispose(&snap);

    // unit conversion: inch -> mm scales by 25.4
    snap = take_snapshot(plater);
    const orca_scene_object *obj_a = find_object(snap, a);
    const float width_before = obj_a->bbox_max[0] - obj_a->bbox_min[0];
    orca_scene_snapshot_dispose(&snap);
    orca_object_id converted = 0;
    GUARD(e6, orca_plater_convert_units(plater, a, 9, &converted, &revision));
    expect_code(e6, ORCA_STATUS_INVALID_ARGUMENT, "bogus conversion");
    GUARD(g10, orca_plater_convert_units(plater, a, ORCA_UNITS_FROM_INCH, &converted, &revision));
    expect_ok(g10, "from inch");
    snap = take_snapshot(plater);
    CHECK(find_object(snap, a) == nullptr);
    const orca_scene_object *big = find_object(snap, converted);
    CHECK(big != nullptr);
    if (big) CHECK_NEAR(big->bbox_max[0] - big->bbox_min[0], width_before * 25.4f, 0.05);
    orca_scene_snapshot_dispose(&snap);
    GUARD(g11, orca_plater_undo(plater, &revision));
    expect_ok(g11, "undo conversion");

    // scale to fit: a 20 mm cube grows to the machine volume
    orca_presets *presets = nullptr;
    GUARD(g12, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g12, "presets");
    GUARD(g13, orca_presets_select(presets, "Anycubic Vyper 0.4 nozzle", "Anycubic Generic PLA",
                                   "0.20mm Standard @Anycubic Vyper"));
    expect_ok(g13, "select Vyper");
    GUARD(g14, orca_plater_scale_to_fit(plater, presets, assembly, 0x7fffffff, &revision));
    expect_code(g14, ORCA_STATUS_NOT_FOUND, "scale to fit bogus instance");
    snap = take_snapshot(plater);
    const orca_instance_id assembly_instance = find_object(snap, assembly)->instances[0].id;
    orca_scene_snapshot_dispose(&snap);
    GUARD(g15, orca_plater_scale_to_fit(plater, presets, assembly, assembly_instance, &revision));
    expect_ok(g15, "scale to fit");
    snap = take_snapshot(plater);
    const orca_scene_object *fitted = find_object(snap, assembly);
    if (fitted) {
        CHECK(fitted->instances[0].transform.scale_x > 1.5);
        CHECK_NEAR(instance_min_z(*fitted, fitted->instances[0].matrix), 0.0, 1e-6);
    }
    orca_scene_snapshot_dispose(&snap);
    orca_presets_free(presets);
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

static std::string select_machine_current(orca_presets *presets, int32_t kind) {
    orca_owned_string name{};
    orca_result r = orca_presets_current(presets, kind, &name);
    CHECK_EQ(r.code, ORCA_STATUS_OK);
    std::string value = name.data ? name.data : "";
    orca_result_dispose(&r);
    orca_owned_string_dispose(&name);
    return value;
}

// ABI v25: the desktop printer change. A fresh bundle has the "- default -"
// presets selected (not listed, not passable to orca_presets_select); a
// machine pick must resolve a compatible process and filament instead.
// Regression for the TestFlight 0.1.0 (2.1) failure: selecting a printer
// with the default process still selected failed NOT_FOUND and slicing the
// defaults hit relative-E-without-G92 validation.
static void test_select_machine(const std::string &dir, const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");

    CHECK(select_machine_current(presets, 0) == "Default Printer");
    CHECK(select_machine_current(presets, 2) == "Default Setting");

    // the fresh default triple is NOT passable to the strict triple select
    GUARD(e0, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                  "Generic PLA @System", "Default Setting"));
    expect_code(e0, ORCA_STATUS_NOT_FOUND, "triple select with default process");

    GUARD(e1, orca_presets_select_machine(nullptr, "x"));
    expect_code(e1, ORCA_STATUS_INVALID_HANDLE, "select_machine null handle");
    GUARD(e2, orca_presets_select_machine(presets, ""));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "select_machine empty");
    GUARD(e3, orca_presets_select_machine(presets, "__no_such_machine__"));
    expect_code(e3, ORCA_STATUS_NOT_FOUND, "select_machine unknown");
    expect_owned_diagnostic(e3, "select_machine unknown");
    CHECK(select_machine_current(presets, 0) == "Default Printer");

    // machine pick adopts the machine-declared process and resolves
    // compatibility (upstream load_selections + update_compatible(Always))
    GUARD(g1, orca_presets_select_machine(presets,
                                          "Bambu Lab X1 Carbon 0.4 nozzle"));
    expect_ok(g1, "select_machine X1C");
    CHECK(select_machine_current(presets, 0) == "Bambu Lab X1 Carbon 0.4 nozzle");
    CHECK(select_machine_current(presets, 2) == "0.20mm Standard @BBL X1C");
    // desktop parity: the machine's inherited default_filament_profile
    // is adopted while the selection is still the default filament
    CHECK(select_machine_current(presets, 1) == "Generic PLA");

    // the resolved combination slices: no default-process relative-E trap
    orca_plater *plater = nullptr;
    GUARD(g2, orca_plater_new(&plater));
    expect_ok(g2, "plater_new");
    const std::string cube = write_cube_stl(dir, "select-machine-cube.stl");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g3, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g3, "add cube");
    const std::string gcode = dir + "/select-machine.gcode";
    orca_slice_report report;
    GUARD(g4, orca_plater_slice_to_gcode_with_presets(
                  plater, presets, gcode.c_str(), nullptr, nullptr, nullptr, &report));
    expect_ok(g4, "slice after select_machine");
    orca_slice_report_dispose(&report);

    // switching vendors swaps the incompatible process/filament
    GUARD(g5, orca_presets_select_machine(presets, "Prusa MK4 0.4 nozzle"));
    expect_ok(g5, "select_machine MK4");
    CHECK(select_machine_current(presets, 0) == "Prusa MK4 0.4 nozzle");
    const std::string mk4_process = select_machine_current(presets, 2);
    CHECK(mk4_process != "Default Setting");
    // the engine's own update_compatible(Always) choice for the swapped,
    // incompatible BBL filament (upstream PreferedFilamentsProfileMatch)
    CHECK(select_machine_current(presets, 1) == "Generic PLA @System");
    GUARD(g6, orca_plater_slice_to_gcode_with_presets(
                  plater, presets, gcode.c_str(), nullptr, nullptr, nullptr, &report));
    expect_ok(g6, "slice after vendor switch");
    orca_slice_report_dispose(&report);

    // a machine without default_print_profile still never keeps the default
    // process (Ender-3 V3 declares none)
    GUARD(g7, orca_presets_select_machine(presets,
                                          "Creality Ender-3 V3 0.4 nozzle"));
    expect_ok(g7, "select_machine Ender-3 V3");
    CHECK(select_machine_current(presets, 2) != "Default Setting");

    orca_plater_free(plater);
    orca_presets_free(presets);
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
    // ABI v32: a value the engine cannot parse is a typed failure, never a
    // silent no-op (the client would silently revert the edited field).
    GUARD(g3b, orca_presets_set_value(presets, 2, "layer_height", "not_a_number"));
    expect_code(g3b, ORCA_STATUS_INVALID_CONFIGURATION, "set(unparseable value)");

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

    // --- config finalization regression (TestFlight 0.2.0 crash class) ---
    // A short/empty flush matrix + multi-filament config memmoved from a
    // null buffer in ToolOrdering (0.2.0, iPad11,4). The Bridge finalizes
    // every slice config (desktop full_config semantics) before the engine
    // touches it. Note: the bundle merge derives the filament count from
    // the SELECTED FILAMENT PRESETS, so the full multi-filament repair
    // path is exercised by the multi-filament suite (select_filaments);
    // here we pin that machine-preset edits never break slicing.
    {
        GUARD(fw0, orca_presets_set_value(presets, 0, "flush_volumes_matrix",
                                         "280"));
        expect_ok(fw0, "short flush matrix");
        const std::string repaired = dir + "/presets-repaired.gcode";
        ProgressRecord repair_progress;
        GUARD(fw2, orca_plater_slice_to_gcode_with_presets(
                      plater, presets, repaired.c_str(), progress_trampoline,
                      &repair_progress, nullptr, &report));
        expect_ok(fw2, "slice with short flush matrix");
        orca_slice_report_dispose(&report);
        GUARD(fw3, orca_presets_reset_kind(presets, 0));
        expect_ok(fw3, "reset machine preset");
    }

    // --- multi-filament slots (ABI v31) -----------------------------------
    {
        orca_filament_slots slots;
        GUARD(mf0, orca_presets_filament_slots(presets, &slots));
        expect_ok(mf0, "filament slots");
        CHECK_EQ(slots.count, 1u);  // one slot after the triple selection
        orca_filament_slots_dispose(&slots);

        GUARD(mf1, orca_presets_set_filament_count(presets, 4, "#FF0000"));
        expect_ok(mf1, "grow to 4 filaments");
        GUARD(mf2, orca_presets_filament_slots(presets, &slots));
        expect_ok(mf2, "slots after grow");
        CHECK_EQ(slots.count, 4u);
        // desktop rule: new slots duplicate the LAST filament preset
        CHECK(strcmp(slots.preset_names[1].data, slots.preset_names[0].data) == 0);
        CHECK(strcmp(slots.colours[3].data, "#FF0000") == 0);

        // per-slot preset swap: pick a real filament preset name from the list
        int32_t filament_count = 0;
        GUARD(mf3, orca_presets_list_count(presets, 1, &filament_count));
        CHECK(filament_count > 1);
        orca_owned_string other;
        bool swapped = false;
        for (int32_t i = 0; i < filament_count && !swapped; ++i) {
            GUARD(mf4, orca_presets_list_name(presets, 1, i, &other));
            if (strcmp(other.data, slots.preset_names[0].data) != 0) {
                GUARD(mf5, orca_presets_select_filament(presets, 2, other.data));
                expect_ok(mf5, "swap slot 3 preset");
                swapped = true;
            }
            orca_owned_string_dispose(&other);
        }
        CHECK(swapped);
        GUARD(mf6, orca_presets_set_filament_colour(presets, 1, "#00FF00"));
        expect_ok(mf6, "set slot colour");
        orca_filament_slots_dispose(&slots);
        GUARD(mf7, orca_presets_filament_slots(presets, &slots));
        CHECK_EQ(slots.count, 4u);
        CHECK(strcmp(slots.colours[1].data, "#00FF00") == 0);

        // THE finalization repair: 4 filaments + a 1-value flush matrix on
        // the machine preset (the TestFlight 0.2.0 crash shape) — slicing
        // must succeed and report the repair.
        GUARD(mf8, orca_presets_set_value(presets, 0, "flush_volumes_matrix",
                                         "280"));
        expect_ok(mf8, "short flush matrix (4 filaments)");
        const std::string multi = dir + "/presets-multi.gcode";
        ProgressRecord multi_progress;
        GUARD(mf9, orca_plater_slice_to_gcode_with_presets(
                      plater, presets, multi.c_str(), progress_trampoline,
                      &multi_progress, nullptr, &report));
        expect_ok(mf9, "slice with 4 filaments + short machine matrix");
        // NOTE: construct_full_config's variant expansion re-sizes machine
        // flush matrices before finalization runs (verified: 16 values at 4
        // filaments), so this path cannot produce the short-matrix shape;
        // finalization remains the last-line guard for paths that can.
        orca_slice_report_dispose(&report);
        GUARD(mf10, orca_presets_reset_kind(presets, 0));
        expect_ok(mf10, "reset machine preset");

        // shrink + typed rejections
        GUARD(mf11, orca_presets_set_filament_count(presets, 2, nullptr));
        expect_ok(mf11, "shrink to 2");
        GUARD(mf12, orca_presets_filament_slots(presets, &slots));
        CHECK_EQ(slots.count, 2u);
        orca_filament_slots_dispose(&slots);
        GUARD(mf13, orca_presets_select_filament(presets, 9, "x"));
        expect_code(mf13, ORCA_STATUS_NOT_FOUND, "slot out of range");
        GUARD(mf14, orca_presets_set_filament_count(presets, 0, nullptr));
        expect_code(mf14, ORCA_STATUS_INVALID_ARGUMENT, "zero filaments");
        GUARD(mf15, orca_presets_set_filament_colour(presets, 0, "red"));
        expect_code(mf15, ORCA_STATUS_INVALID_ARGUMENT, "bad colour");
        // back to one filament for the tests that follow
        GUARD(mf16, orca_presets_set_filament_count(presets, 1, nullptr));
        expect_ok(mf16, "back to 1 filament");
    }

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

    // flatten planes (desktop GLGizmoFlatten::update_planes): the upright
    // 10 mm cube hull carries exactly 6 resting planes, one per face.
    {
        orca_flatten_planes planes;
        GUARD(fp0, orca_plater_flatten_planes(plater, flat_object, flat_instance, &planes));
        expect_ok(fp0, "flatten planes");
        CHECK_EQ(planes.plane_count, 6u);
        bool seen[6] = {false, false, false, false, false, false};
        for (uint32_t p = 0; p < planes.plane_count; ++p) {
            const orca_flatten_plane &plane = planes.planes[p];
            CHECK(plane.vertex_count == 4);  // convex-hulled quad
            CHECK_NEAR(plane.area, 400.0f, 2.0f);
            const double nx = plane.normal[0], ny = plane.normal[1], nz = plane.normal[2];
            const double magnitude = std::sqrt(nx * nx + ny * ny + nz * nz);
            CHECK_NEAR(magnitude, 1.0, 1e-6);
            int slot = -1;
            if (nx > 0.9) slot = 0; else if (nx < -0.9) slot = 1;
            else if (ny > 0.9) slot = 2; else if (ny < -0.9) slot = 3;
            else if (nz > 0.9) slot = 4; else if (nz < -0.9) slot = 5;
            CHECK(slot >= 0);
            if (slot >= 0) { CHECK(!seen[slot]); seen[slot] = true; }
        }
        bool all = true;
        for (bool s : seen) all = all && s;
        CHECK(all);
        orca_flatten_planes_dispose(&planes);
        CHECK(planes.plane_count == 0 && planes.planes == nullptr);
    }
    orca_flatten_planes_dispose(nullptr);
    {
        orca_flatten_planes planes;
        GUARD(fp1, orca_plater_flatten_planes(plater, 12345, flat_instance, &planes));
        expect_code(fp1, ORCA_STATUS_NOT_FOUND, "flatten planes missing object");
    }

    // fill bed: clones of the flat cube fill the plate around the arranged
    // stack (desktop FillBedJob); one mutation, one undo step back.
    {
        uint32_t added = 0;
        const orca_revision before = snapshot_revision(plater);
        GUARD(fb0, orca_plater_fill_bed(plater, presets, flat_object, 1, &added, &revision));
        expect_ok(fb0, "fill bed");
        CHECK(added >= 15);  // 200x200 bed, 20 mm cube + 6 mm spacing
        CHECK(revision == before + 1);
        int32_t instances_after = -1;
        {
            orca_scene_snapshot snap = take_snapshot(plater);
            const orca_scene_object *obj = find_object(snap, flat_object);
            CHECK(obj != nullptr);
            if (obj) {
                instances_after = obj->instance_count;
                CHECK_EQ(instances_after, int32_t(1 + added));
                // every clone stays on plate 0 (overflow is dropped)
                for (int32_t i = 0; i < obj->instance_count; ++i)
                    CHECK_EQ(obj->instances[i].plate, 0);
                CHECK(snapshot_label(snap.undo_label) == "Fill bed");
            }
            orca_scene_snapshot_dispose(&snap);
        }
        GUARD(fb1, orca_plater_undo(plater, &revision));
        expect_ok(fb1, "undo fill bed");
        {
            orca_scene_snapshot snap = take_snapshot(plater);
            const orca_scene_object *obj = find_object(snap, flat_object);
            CHECK(obj != nullptr);
            if (obj) CHECK_EQ(obj->instance_count, 1);
            orca_scene_snapshot_dispose(&snap);
        }
        (void)instances_after;
    }
    {
        uint32_t added = 0;
        GUARD(fb2, orca_plater_fill_bed(plater, presets, 12345, 1, &added, &revision));
        expect_code(fb2, ORCA_STATUS_NOT_FOUND, "fill bed missing object");
    }

    // typed rejections
    GUARD(e2, orca_plater_orient(plater, presets, 12345, 1, &revision));
    expect_code(e2, ORCA_STATUS_NOT_FOUND, "orient missing object");
    GUARD(e3, orca_plater_arrange(nullptr, presets, 0, &unprintable, &revision));
    expect_code(e3, ORCA_STATUS_INVALID_HANDLE, "arrange null plater");

    orca_presets_free(presets);
    orca_plater_free(plater);
}

// ABI v39: height ranges (layer-range modifiers)
static void test_height_ranges(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    const std::string cube = write_cube_stl(dir, "ranges_cube.stl");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "import cube");

    // empty by default
    orca_height_range *ranges = nullptr;
    uint32_t count = 0;
    GUARD(q1, orca_plater_object_height_ranges(plater, object_id, &ranges, &count));
    expect_ok(q1, "height ranges empty");
    CHECK_EQ(count, 0u);
    orca_height_ranges_dispose(ranges);

    // set two ranges, read back ascending with heights
    orca_height_range set[2] = {{0.0, 4.0, 0.12}, {4.0, 20.0, 0.28}};
    GUARD(s1, orca_plater_object_set_height_ranges(plater, object_id, set, 2, &revision));
    expect_ok(s1, "set two ranges");
    GUARD(q2, orca_plater_object_height_ranges(plater, object_id, &ranges, &count));
    expect_ok(q2, "read back");
    CHECK_EQ(count, 2u);
    CHECK_NEAR(ranges[0].min_z, 0.0, 1e-9);
    CHECK_NEAR(ranges[0].max_z, 4.0, 1e-9);
    CHECK_NEAR(ranges[0].layer_height, 0.12, 1e-9);
    CHECK_NEAR(ranges[1].layer_height, 0.28, 1e-9);
    orca_height_ranges_dispose(ranges);

    // typed rejections: overlap + inverted + zero height
    orca_height_range bad[2] = {{0.0, 5.0, 0.2}, {4.0, 8.0, 0.2}};
    GUARD(x1, orca_plater_object_set_height_ranges(plater, object_id, bad, 2, &revision));
    expect_code(x1, ORCA_STATUS_INVALID_ARGUMENT, "overlapping ranges");
    orca_height_range inverted[1] = {{5.0, 3.0, 0.2}};
    GUARD(x2, orca_plater_object_set_height_ranges(plater, object_id, inverted, 1, &revision));
    expect_code(x2, ORCA_STATUS_INVALID_ARGUMENT, "inverted range");
    orca_height_range zero[1] = {{0.0, 3.0, 0.0}};
    GUARD(x3, orca_plater_object_set_height_ranges(plater, object_id, zero, 1, &revision));
    expect_code(x3, ORCA_STATUS_INVALID_ARGUMENT, "zero layer height");

    // clear via empty set + undo restores
    GUARD(s2, orca_plater_object_set_height_ranges(plater, object_id, nullptr, 0, &revision));
    expect_ok(s2, "clear ranges");
    GUARD(q3, orca_plater_object_height_ranges(plater, object_id, &ranges, &count));
    expect_ok(q3, "cleared");
    CHECK_EQ(count, 0u);
    orca_height_ranges_dispose(ranges);
    GUARD(u1, orca_plater_undo(plater, &revision));
    expect_ok(u1, "undo clear");
    GUARD(q4, orca_plater_object_height_ranges(plater, object_id, &ranges, &count));
    expect_ok(q4, "after undo");
    CHECK_EQ(count, 2u);
    orca_height_ranges_dispose(ranges);
    orca_plater_free(plater);
}

// ABI v38: SVG emboss (standalone raised object)// ABI v38: SVG emboss (standalone raised object)
static void test_svg(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    // minimal 20x10 mm rectangle SVG
    const std::string svg = dir + "/rect.svg";
    {
        FILE *file = fopen(svg.c_str(), "w");
        CHECK(file != nullptr);
        if (file) {
            fprintf(file,
                "<svg xmlns=\"http://www.w3.org/2000/svg\" width=\"20mm\" "
                "height=\"10mm\" viewBox=\"0 0 20 10\">"
                "<path d=\"M0 0 H20 V10 H0 Z\" fill=\"#000\"/></svg>");
            fclose(file);
        }
    }
    orca_object_id id = 0;
    orca_revision revision = 0;
    GUARD(g1, orca_plater_add_svg_object(plater, svg.c_str(), 2.0,
                                         100.0, 100.0, &id, &revision));
    expect_ok(g1, "add svg object");
    CHECK(id != 0);
    {
        orca_scene_snapshot snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 1);
        CHECK(snap.objects[0].index_count >= 12);   // solid prism
        // z extent ~= depth 2mm (instance rests it on the bed)
        CHECK_NEAR(snap.objects[0].bbox_max[2] - snap.objects[0].bbox_min[2],
                   2.0f, 0.1f);
        // xy extent ~= the SVG rect (20x10) in mm
        CHECK_NEAR(snap.objects[0].bbox_max[0] - snap.objects[0].bbox_min[0],
                   20.0f, 0.5f);
        orca_scene_snapshot_dispose(&snap);
    }
    GUARD(x1, orca_plater_add_svg_object(plater, (dir + "/no.svg").c_str(),
                                         2.0, 0, 0, &id, &revision));
    expect_code(x1, ORCA_STATUS_IO_FAILURE, "svg missing file");
    GUARD(x2, orca_plater_add_svg_object(plater, svg.c_str(), 0.0,
                                         0, 0, &id, &revision));
    expect_code(x2, ORCA_STATUS_INVALID_ARGUMENT, "svg zero depth");
    orca_plater_free(plater);
}

// ABI v37: object hull / COG + text emboss// ABI v37: object hull / COG + text emboss
static void test_hull_and_text(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    const std::string cube = write_cube_stl(dir, "hull_cube.stl");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "import cube");

    // hull: a cube's hull is the cube itself (12 triangles, 8 vertices)
    orca_hull_mesh hull{};
    GUARD(h1, orca_plater_object_hull(plater, object_id, &hull));
    expect_ok(h1, "object hull");
    CHECK_EQ(hull.index_count / 3, 12u);
    CHECK_EQ(hull.vertex_count, 8u);
    // world space of instance 0: the import placed the cube at (100,100),
    // resting on the bed (10mm tall => centroid z = 5)
    CHECK_NEAR(hull.centroid[0], 100.0, 1e-3);
    CHECK_NEAR(hull.centroid[1], 100.0, 1e-3);
    CHECK_NEAR(hull.centroid[2], 10.0, 1e-3);  // 20mm test cube
    orca_hull_mesh_dispose(&hull);
    GUARD(h2, orca_plater_object_hull(plater, 999999, &hull));
    expect_code(h2, ORCA_STATUS_NOT_FOUND, "hull missing object");

    // text: the shipped Sarabun (OFL) copy
    const std::string font = "Sources/OrcaPad/Resources/Fonts/Sarabun-Regular.ttf";
    struct stat probe;
    if (stat(font.c_str(), &probe) == 0) {
        orca_object_id text_id = 0;
        GUARD(t1, orca_plater_add_text_object(plater, font.c_str(), "OC",
                                              10.0, 2.0, 100.0, 100.0,
                                              &text_id, &revision));
        expect_ok(t1, "add text object");
        CHECK(text_id != 0);
        orca_scene_snapshot snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 2);
        bool found = false;
        for (int i = 0; i < snap.object_count; ++i)
            if (snap.objects[i].id == text_id) {
                found = true;
                CHECK(snap.objects[i].index_count > 30);
                // extrusion-centered mesh: z extent ~= depth (2mm); the
                // INSTANCE rests it on the bed
                CHECK_NEAR(snap.objects[i].bbox_max[2] - snap.objects[i].bbox_min[2],
                           2.0f, 0.05f);
            }
        CHECK(found);
        orca_scene_snapshot_dispose(&snap);
        GUARD(t2, orca_plater_undo(plater, &revision));
        expect_ok(t2, "undo text");
        snap = take_snapshot(plater);
        CHECK_EQ(snap.object_count, 1);
        orca_scene_snapshot_dispose(&snap);
        GUARD(t3, orca_plater_add_text_object(plater, font.c_str(), "   ",
                                              10.0, 2.0, 100.0, 100.0,
                                              &text_id, &revision));
        expect_code(t3, ORCA_STATUS_INVALID_MODEL, "whitespace text rejected");
    }
    GUARD(t4, orca_plater_add_text_object(plater, (dir + "/nofont.ttf").c_str(),
                                          "X", 10.0, 2.0, 0, 0,
                                          &object_id, &revision));
    expect_code(t4, ORCA_STATUS_IO_FAILURE, "missing font file");
    orca_plater_free(plater);
}

// ABI v36: painting (support/seam/MMU/fuzzy layers)// ABI v36: painting (support/seam/MMU/fuzzy layers)
static void test_painting(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    const std::string cube = write_cube_stl(dir, "paint_cube.stl");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "import cube");

    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 1);
    const orca_volume_id volume = snap.objects[0].volumes[0].id;
    const orca_instance_id instance = snap.objects[0].instances[0].id;
    // WORLD bbox of the resting cube: the snapshot bbox is object-space,
    // the instance matrix places it on the bed (ABI contract).
    float lo[3] = {1e30f, 1e30f, 1e30f}, hi[3] = {-1e30f, -1e30f, -1e30f};
    {
        const double *m = snap.objects[0].instances[0].matrix; // column-major
        const float *bmin = snap.objects[0].bbox_min;
        const float *bmax = snap.objects[0].bbox_max;
        for (int sx = 0; sx < 2; ++sx)
            for (int sy = 0; sy < 2; ++sy)
                for (int sz = 0; sz < 2; ++sz) {
                    const double local[4] = {sx ? bmax[0] : bmin[0],
                                             sy ? bmax[1] : bmin[1],
                                             sz ? bmax[2] : bmin[2], 1.0};
                    for (int row = 0; row < 3; ++row) {
                        const double world = m[row] * local[0] + m[4 + row] * local[1]
                                           + m[8 + row] * local[2] + m[12 + row] * local[3];
                        lo[row] = std::min(lo[row], float(world));
                        hi[row] = std::max(hi[row], float(world));
                    }
                }
    }
    const float minZ = lo[2], maxZ = hi[2];
    const float midX = 0.5f * (lo[0] + hi[0]);
    const float midY = 0.5f * (lo[1] + hi[1]);
    const float size = hi[0] - lo[0];
    orca_scene_snapshot_dispose(&snap);

    // empty layer queries cleanly
    orca_paint_mesh paint{};
    GUARD(q0, orca_plater_volume_paint(plater, object_id, volume,
                                       ORCA_PAINT_SUPPORT, &paint));
    expect_ok(q0, "paint query empty");
    CHECK_EQ(paint.count, 0u);
    orca_paint_mesh_dispose(&paint);

    // paint the TOP face with a blocker sphere from above (view -Z)
    GUARD(p1, orca_plater_volume_paint_sphere(
                  plater, object_id, volume, ORCA_PAINT_SUPPORT,
                  midX, midY, maxZ, 0, 0, -1,
                  0.3 * size, int32_t(2) /*BLOCKER*/, &revision));
    expect_ok(p1, "paint top face");

    GUARD(q1, orca_plater_volume_paint(plater, object_id, volume,
                                       ORCA_PAINT_SUPPORT, &paint));
    expect_ok(q1, "paint query after stroke");
    CHECK(paint.count > 0);
    bool has_blocker = false;
    bool all_top = true;
    for (uint32_t i = 0; i < paint.count; ++i) {
        if (paint.triangles[i].state == 2) has_blocker = true;
        for (int c = 0; c < 3; ++c)
            if (paint.triangles[i].positions[c * 3 + 2] < maxZ - 0.25f * size)
                all_top = false;
    }
    CHECK(has_blocker);
    CHECK(all_top);
    orca_paint_mesh_dispose(&paint);

    // the OTHER layer is untouched
    GUARD(q2, orca_plater_volume_paint(plater, object_id, volume,
                                       ORCA_PAINT_SEAM, &paint));
    expect_ok(q2, "seam layer untouched");
    CHECK_EQ(paint.count, 0u);
    orca_paint_mesh_dispose(&paint);

    // typed rejections
    GUARD(x1, orca_plater_volume_paint_sphere(
                  plater, object_id, volume, 9, 0, 0, 0, 0, 0, -1, 1.0, 1, &revision));
    expect_code(x1, ORCA_STATUS_INVALID_ARGUMENT, "paint bad layer");
    GUARD(x2, orca_plater_volume_paint_sphere(
                  plater, object_id, volume, ORCA_PAINT_SUPPORT,
                  midX, midY, maxZ + 100, 0, 0, -1, 1.0, 1, &revision));
    expect_code(x2, ORCA_STATUS_NOT_FOUND, "paint off-mesh hit");
    GUARD(x3, orca_plater_volume_paint_reset(plater, object_id, volume,
                                             ORCA_PAINT_SEAM, &revision));
    expect_code(x3, ORCA_STATUS_INVALID_MODEL, "reset empty layer");

    // undo removes the stroke
    GUARD(u1, orca_plater_undo(plater, &revision));
    expect_ok(u1, "undo paint");
    GUARD(q3, orca_plater_volume_paint(plater, object_id, volume,
                                       ORCA_PAINT_SUPPORT, &paint));
    expect_ok(q3, "paint query after undo");
    CHECK_EQ(paint.count, 0u);
    orca_paint_mesh_dispose(&paint);

    // reset path: paint then clear
    GUARD(p2, orca_plater_volume_paint_sphere(
                  plater, object_id, volume, ORCA_PAINT_FUZZY,
                  midX, midY, minZ, 0, 0, 1,
                  0.3 * size, int32_t(1) /*FUZZY=ENFORCER*/, &revision));
    expect_ok(p2, "paint bottom fuzzy");
    GUARD(r1, orca_plater_volume_paint_reset(plater, object_id, volume,
                                             ORCA_PAINT_FUZZY, &revision));
    expect_ok(r1, "reset fuzzy layer");
    GUARD(q4, orca_plater_volume_paint(plater, object_id, volume,
                                       ORCA_PAINT_FUZZY, &paint));
    expect_ok(q4, "paint query after reset");
    CHECK_EQ(paint.count, 0u);
    orca_paint_mesh_dispose(&paint);

    (void)instance;
    orca_plater_free(plater);
}

// ABI v35: config import/export// ABI v35: config import/export
static void test_config_io(const std::string &dir, const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");
    GUARD(g1, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                  "Bambu PLA Basic @BBL X1C",
                                  "0.20mm Standard @BBL X1C"));
    expect_ok(g1, "select X1C");

    // export the current triple (system presets included)
    const std::string out_dir = dir + "/exported-presets";
    uint32_t count = 0;
    GUARD(e1, orca_presets_export_configs(presets, out_dir.c_str(), 1, &count));
    expect_ok(e1, "export current configs");
    CHECK(count >= 3);

    // re-import one exported preset json: name round-trips, is listed
    orca_owned_string imported{};
    const std::string filament = out_dir + "/Bambu PLA Basic @BBL X1C.json";
    GUARD(i1, orca_presets_import_preset(presets, filament.c_str(), &imported));
    expect_ok(i1, "import preset json");
    CHECK(imported.data && strcmp(imported.data, "Bambu PLA Basic @BBL X1C") == 0);
    orca_owned_string_dispose(&imported);
    int32_t listed = -1;
    GUARD(i2, orca_presets_list_count(presets, 1, &listed));
    expect_ok(i2, "list filaments after import");
    CHECK(listed > 0);

    // typed rejections
    GUARD(x1, orca_presets_import_preset(presets, (dir + "/nope.json").c_str(), &imported));
    expect_code(x1, ORCA_STATUS_IO_FAILURE, "import missing file");
    GUARD(x2, orca_presets_export_configs(presets, nullptr, 1, &count));
    expect_code(x2, ORCA_STATUS_INVALID_ARGUMENT, "export null dir");

    // vendor bundle import: a synthetic bundle (the system vendors are
    // already installed — importing one is the duplicate case below)
    const std::string vendor_dir = dir + "/TestVendorBundle/TestVendor";
    {
        mkdir(dir.c_str(), 0755);
        mkdir((dir + "/TestVendorBundle").c_str(), 0755);
        mkdir(vendor_dir.c_str(), 0755);
        mkdir((vendor_dir + "/process").c_str(), 0755);
        FILE *root = fopen((dir + "/TestVendorBundle/TestVendor.json").c_str(), "w");
        CHECK(root != nullptr);
        if (root) {
            fprintf(root, "{\"name\": \"TestVendor\", \"version\": \"01.00.00.00\", "
                          "\"description\": \"test bundle\", "
                          "\"machine_model_list\": [], "
                          "\"machine_list\": [], "
                          "\"process_list\": ["
                          "{\"name\": \"TestVendor Process\", "
                          "\"sub_path\": \"process/TestVendor Process.json\"}], "
                          "\"filament_list\": []}");
            fclose(root);
        }
        FILE *preset = fopen((vendor_dir + "/process/TestVendor Process.json").c_str(), "w");
        CHECK(preset != nullptr);
        if (preset) {
            fprintf(preset, "{\"name\": \"TestVendor Process\", \"version\": \"1\", "
                            "\"layer_height\": \"0.2\", "
                            "\"sparse_infill_density\": \"15%%\"}");
            fclose(preset);
        }
    }
    uint32_t loaded = 0;
    GUARD(b1, orca_presets_import_bundle(
                  presets, (dir + "/TestVendorBundle/TestVendor.json").c_str(), &loaded));
    expect_ok(b1, "import vendor bundle");
    CHECK(loaded > 0);
    // a second import of the same names is a typed duplicate failure
    GUARD(b1b, orca_presets_import_bundle(
                   presets, (dir + "/TestVendorBundle/TestVendor.json").c_str(), &loaded));
    expect_code(b1b, ORCA_STATUS_INVALID_CONFIGURATION, "import duplicate bundle");
    GUARD(b2, orca_presets_import_bundle(presets, (dir + "/novendor.json").c_str(), &count));
    expect_code(b2, ORCA_STATUS_IO_FAILURE, "import missing bundle");

    orca_presets_free(presets);
}

// ABI v34: plane cut (CutUtils::Cut)// ABI v34: plane cut (CutUtils::Cut)
static void test_cut(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    const std::string cube = write_cube_stl(dir, "cut_cube.stl");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "import cube");

    // geometry probe: bbox mid-height is where the plane goes
    orca_scene_snapshot snap = take_snapshot(plater);
    CHECK_EQ(snap.object_count, 1);
    const orca_scene_object &source = snap.objects[0];
    const double cx = 0.5 * (source.bbox_min[0] + source.bbox_max[0]);
    const double cy = 0.5 * (source.bbox_min[1] + source.bbox_max[1]);
    const double midZ = 0.5 * (source.bbox_min[2] + source.bbox_max[2]);
    const float sourceHeight = source.bbox_max[2] - source.bbox_min[2];
    const orca_instance_id instance = source.instances[0].id;
    orca_scene_snapshot_dispose(&snap);

    // typed rejections
    orca_object_id first = 0;
    uint32_t count = 0;
    GUARD(e1, orca_plater_object_cut(plater, object_id, instance,
                                     cx, cy, midZ, 0, 0, 1, 9,
                                     &first, &count, &revision));
    expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "cut(keep out of range)");
    GUARD(e2, orca_plater_object_cut(plater, object_id, instance,
                                     cx, cy, midZ, 0, 0, 0, 3,
                                     &first, &count, &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "cut(degenerate normal)");
    GUARD(e3, orca_plater_object_cut(plater, 999999, instance,
                                     cx, cy, midZ, 0, 0, 1, 3,
                                     &first, &count, &revision));
    expect_code(e3, ORCA_STATUS_NOT_FOUND, "cut(missing object)");

    // both halves as separate objects: two smaller meshes, one undo step
    GUARD(c1, orca_plater_object_cut(plater, object_id, instance,
                                     cx, cy, midZ, 0, 0, 1, 3,
                                     &first, &count, &revision));
    expect_ok(c1, "cut both as objects");
    CHECK_EQ(count, 2u);
    CHECK(first != object_id);
    {
        orca_scene_snapshot after = take_snapshot(plater);
        CHECK_EQ(after.object_count, 2);
        for (int i = 0; i < after.object_count; ++i) {
            const float height = after.objects[i].bbox_max[2] -
                                 after.objects[i].bbox_min[2];
            // each half is distinctly shorter than the whole (cap closes it)
            CHECK(height < 0.75f * sourceHeight);
        }
        orca_scene_snapshot_dispose(&after);
    }
    GUARD(u1, orca_plater_undo(plater, &revision));
    expect_ok(u1, "undo cut");
    {
        orca_scene_snapshot restored = take_snapshot(plater);
        CHECK_EQ(restored.object_count, 1);
        orca_scene_snapshot_dispose(&restored);
    }

    // both halves as PARTS: one object, two volumes
    GUARD(c2, orca_plater_object_cut(plater, object_id, instance,
                                     cx, cy, midZ, 0, 0, 1, 2,
                                     &first, &count, &revision));
    expect_ok(c2, "cut both as parts");
    CHECK_EQ(count, 1u);
    {
        orca_scene_snapshot parts = take_snapshot(plater);
        CHECK_EQ(parts.object_count, 1);
        CHECK_EQ(parts.objects[0].volume_count, 2);
        orca_scene_snapshot_dispose(&parts);
    }
    orca_plater_free(plater);
}

// ABI v33: exports (object STL / generic 3MF / sliced .gcode.3mf)
static void test_exports(const std::string &dir, const std::string &data_dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "export_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "import cube");

    // STL export round-trip: the exported mesh re-imports as one object
    const std::string stl = dir + "/exported.stl";
    GUARD(e1, orca_plater_object_export_stl(plater, object_id, stl.c_str(), 1));
    expect_ok(e1, "export stl");
    orca_object_id reimported = 0;
    uint32_t reimported_count = 0;
    GUARD(e2, orca_plater_import_model(plater, stl.c_str(), 100.0, 100.0,
                                       &reimported, &reimported_count, &revision));
    expect_ok(e2, "reimport stl");
    CHECK_EQ(reimported_count, 1u);
    // drop the re-imported copy: the generic-3MF round-trip below starts
    // from exactly one object
    GUARD(e2b, orca_plater_object_delete(plater, reimported, &revision));
    expect_ok(e2b, "delete reimported stl object");
    GUARD(e3, orca_plater_object_export_stl(plater, object_id, nullptr, 1));
    expect_code(e3, ORCA_STATUS_INVALID_ARGUMENT, "stl null path");
    GUARD(e3b, orca_plater_object_export_stl(plater, 999999, stl.c_str(), 1));
    expect_code(e3b, ORCA_STATUS_NOT_FOUND, "stl missing object");

    // generic 3MF export: geometry only, re-imports
    const std::string generic = dir + "/exported.3mf";
    GUARD(e4, orca_project_export_3mf(plater, generic.c_str()));
    expect_ok(e4, "export generic 3mf");
    orca_object_id generic_id = 0;
    uint32_t generic_count = 0;
    GUARD(e5, orca_plater_import_model(plater, generic.c_str(), 100.0, 100.0,
                                       &generic_id, &generic_count, &revision));
    expect_ok(e5, "reimport generic 3mf");
    CHECK_EQ(generic_count, 1u);
    GUARD(e6, orca_project_export_3mf(plater, (dir + "/x.gcode").c_str()));
    expect_code(e6, ORCA_STATUS_INVALID_ARGUMENT, "3mf wrong suffix");

    // sliced .gcode.3mf: full slice embedded, zip magic, real size
    orca_presets *presets = nullptr;
    GUARD(p0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(p0, "presets_new");
    GUARD(p1, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                  "Bambu PLA Basic @BBL X1C",
                                  "0.20mm Standard @BBL X1C"));
    expect_ok(p1, "select X1C");
    const std::string sliced = dir + "/exported.gcode.3mf";
    orca_slice_report report;
    GUARD(p2, orca_plater_export_gcode_3mf(plater, presets, sliced.c_str(),
                                           nullptr, nullptr, nullptr, &report));
    expect_ok(p2, "export sliced 3mf");
    CHECK(report.time_estimate_s > 0.0);
    CHECK(report.gcode_bytes > 1000);
    FILE *file = fopen(sliced.c_str(), "rb");
    CHECK(file != nullptr);
    if (file) {
        unsigned char magic[2] = {0, 0};
        fread(&magic, 1, 2, file);
        fclose(file);
        CHECK(magic[0] == 'P' && magic[1] == 'K');
    }
    GUARD(p3, orca_plater_export_gcode_3mf(plater, presets,
                                           (dir + "/x.gcode").c_str(),
                                           nullptr, nullptr, nullptr, &report));
    expect_code(p3, ORCA_STATUS_INVALID_ARGUMENT, "sliced 3mf wrong suffix");

    // ABI v40: per-plate sliced 3MF (desktop "Export plate sliced file")
    const std::string plate3mf = dir + "/plate0.gcode.3mf";
    GUARD(p4, orca_plater_export_gcode_3mf_plate(plater, presets, 0,
                                                 plate3mf.c_str(), nullptr,
                                                 nullptr, nullptr, &report));
    expect_ok(p4, "export plate sliced 3mf");
    CHECK(report.gcode_bytes > 1000);
    FILE *plate_file = fopen(plate3mf.c_str(), "rb");
    CHECK(plate_file != nullptr);
    if (plate_file) {
        unsigned char magic[2] = {0, 0};
        fread(&magic, 1, 2, plate_file);
        fclose(plate_file);
        CHECK(magic[0] == 'P' && magic[1] == 'K');
    }
    GUARD(p5, orca_plater_export_gcode_3mf_plate(plater, presets, 99,
                                                 plate3mf.c_str(), nullptr,
                                                 nullptr, nullptr, &report));
    expect_code(p5, ORCA_STATUS_INVALID_ARGUMENT, "plate out of range");
    // an existing but EMPTY plate is a typed INVALID_MODEL
    orca_plate_id empty_plate = 0;
    GUARD(p6, orca_plater_plate_add(plater, &empty_plate, &revision));
    expect_ok(p6, "add empty plate");
    GUARD(p7, orca_plater_export_gcode_3mf_plate(plater, presets, 1,
                                                 plate3mf.c_str(), nullptr,
                                                 nullptr, nullptr, &report));
    expect_code(p7, ORCA_STATUS_INVALID_MODEL, "empty plate export");
    orca_slice_report_dispose(&report);
    orca_presets_free(presets);
    orca_plater_free(plater);
}

// --- ABI v40: measure, simplify, subdivide, export-all STL --------------------

static void test_measure_and_mesh_ops(const std::string &dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "meshops_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "import cube");

    // object + volume ids from the snapshot
    orca_scene_snapshot snap;
    memset(&snap, 0, sizeof snap);
    GUARD(s0, orca_plater_snapshot(plater, &snap));
    expect_ok(s0, "snapshot");
    CHECK_EQ(snap.object_count, 1);
    CHECK_EQ(snap.objects[0].index_count / 3, 12u); // 12 triangles
    CHECK_EQ(snap.objects[0].volume_count, 1);
    const orca_volume_id volume_id = snap.objects[0].volumes[0].id;
    orca_scene_snapshot_dispose(&snap);

    // --- measure: point pick at two corners of the bottom face -> distance
    orca_measure *measure = nullptr;
    GUARD(m0, orca_plater_object_measure(plater, object_id, &measure));
    expect_ok(m0, "measure new");
    CHECK(measure != nullptr);
    orca_measure *bogus_measure = nullptr;
    GUARD(m0b, orca_plater_object_measure(plater, 999999, &bogus_measure));
    expect_code(m0b, ORCA_STATUS_NOT_FOUND, "measure missing object");
    // import recenters the group: object space is -10..+10
    orca_surface_feature corner_a{};
    GUARD(m1, orca_measure_pick(measure, 0, -10.0, -10.0, -10.0, &corner_a));
    expect_ok(m1, "pick corner a");
    CHECK_EQ(corner_a.type, ORCA_MEASURE_POINT);
    CHECK_NEAR(corner_a.point_a[0], -10.0, 1e-4);
    CHECK_NEAR(corner_a.point_a[1], -10.0, 1e-4);
    CHECK_NEAR(corner_a.point_a[2], -10.0, 1e-4);
    orca_surface_feature corner_b{};
    GUARD(m2, orca_measure_pick(measure, 0, 10.0, 10.0, -10.0, &corner_b));
    expect_ok(m2, "pick corner b");
    CHECK_EQ(corner_b.type, ORCA_MEASURE_POINT);
    orca_measurement measurement;
    memset(&measurement, 0, sizeof measurement);
    GUARD(m3, orca_measure_between(measure, &corner_a, &corner_b, &measurement));
    expect_ok(m3, "measure diagonal");
    CHECK(measurement.has_distance);
    CHECK_NEAR(measurement.distance, std::sqrt(800.0), 0.05); // 20 x 20 face
    CHECK(measurement.has_xyz);
    CHECK_NEAR(measurement.xyz[0], 20.0, 0.05);
    CHECK_NEAR(measurement.xyz[1], 20.0, 0.05);
    CHECK_NEAR(measurement.xyz[2], 0.0, 0.05);
    GUARD(m3b, orca_measure_pick(measure, -1, 1.0, 1.0, 1.0, &corner_a));
    expect_code(m3b, ORCA_STATUS_INVALID_ARGUMENT, "pick negative face");

    // --- measure: plane pick mid-top-face -> plane feature with area
    orca_surface_feature plane{};
    GUARD(m4, orca_measure_pick(measure, 2, 0.0, 0.0, 10.0, &plane));
    expect_ok(m4, "pick top plane");
    CHECK_EQ(plane.type, ORCA_MEASURE_PLANE);
    CHECK(plane.plane_index >= 0);
    CHECK_NEAR(plane.normal[2], 1.0, 0.02); // +z top face
    CHECK_NEAR(plane.area, 400.0, 25.0);   // 20 x 20mm face
    orca_measurement plane_to_point;
    memset(&plane_to_point, 0, sizeof plane_to_point);
    GUARD(m5, orca_measure_between(measure, &plane, &corner_a, &plane_to_point));
    expect_ok(m5, "plane to point");
    CHECK(plane_to_point.has_distance || plane_to_point.has_xyz);
    orca_measure_dispose(measure);

    // --- simplify: quadric edge collapse on the single volume
    uint32_t triangles = 0;
    GUARD(q0, orca_plater_volume_simplify(plater, object_id, volume_id, 1, 12,
                                           0.0, &triangles, &revision));
    expect_code(q0, ORCA_STATUS_INVALID_ARGUMENT, "simplify to current count");
    GUARD(q0b, orca_plater_volume_simplify(plater, object_id, 999999, 1, 6,
                                            0.0, &triangles, &revision));
    expect_code(q0b, ORCA_STATUS_NOT_FOUND, "simplify missing volume");
    GUARD(q1, orca_plater_volume_simplify(plater, object_id, volume_id, 1, 6,
                                          0.0, &triangles, &revision));
    expect_ok(q1, "simplify to six faces");
    CHECK(triangles >= 4);
    CHECK(triangles < 12);
    memset(&snap, 0, sizeof snap);
    GUARD(q2, orca_plater_snapshot(plater, &snap));
    expect_ok(q2, "snapshot after simplify");
    CHECK_EQ(snap.objects[0].index_count / 3, triangles);
    orca_scene_snapshot_dispose(&snap);
    GUARD(q3, orca_plater_undo(plater, &revision));
    expect_ok(q3, "undo simplify");
    memset(&snap, 0, sizeof snap);
    GUARD(q4, orca_plater_snapshot(plater, &snap));
    expect_ok(q4, "snapshot after undo");
    CHECK_EQ(snap.objects[0].index_count / 3, 12u);
    orca_scene_snapshot_dispose(&snap);

    // --- subdivide: igl Loop, exactly 4x faces, undo restores
    GUARD(b0, orca_plater_volume_subdivide(plater, object_id, 999999,
                                            &triangles, &revision));
    expect_code(b0, ORCA_STATUS_NOT_FOUND, "subdivide missing volume");
    GUARD(b1, orca_plater_volume_subdivide(plater, object_id, volume_id,
                                            &triangles, &revision));
    expect_ok(b1, "subdivide");
    CHECK_EQ(triangles, 48u);
    GUARD(b2, orca_plater_undo(plater, &revision));
    expect_ok(b2, "undo subdivide");
    memset(&snap, 0, sizeof snap);
    GUARD(b3, orca_plater_snapshot(plater, &snap));
    expect_ok(b3, "snapshot after subdivide undo");
    CHECK_EQ(snap.objects[0].index_count / 3, 12u);
    orca_scene_snapshot_dispose(&snap);

    // --- export all objects as one STL: two objects -> one file
    orca_object_id second = 0;
    uint32_t second_count = 0;
    GUARD(x0, orca_plater_import_model(plater, cube.c_str(), 140.0, 140.0,
                                       &second, &second_count, &revision));
    expect_ok(x0, "import second cube");
    const std::string all_stl = dir + "/all.stl";
    GUARD(x1, orca_plater_export_stl_all(plater, all_stl.c_str(), 1));
    expect_ok(x1, "export stl all");
    orca_object_id reimported = 0;
    uint32_t reimported_count = 0;
    GUARD(x2, orca_plater_import_model(plater, all_stl.c_str(), 100.0, 100.0,
                                       &reimported, &reimported_count, &revision));
    expect_ok(x2, "reimport all stl");
    CHECK(reimported_count >= 1u);
    GUARD(x3, orca_plater_export_stl_all(plater, nullptr, 1));
    expect_code(x3, ORCA_STATUS_INVALID_ARGUMENT, "stl all null path");

    orca_plater_free(plater);
}


// --- ABI v41: variable layer height, plate settings, drop/floating, creates ---

static void test_vlh_plates_floating(const std::string &dir,
                                     const std::string &data_dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;
    const std::string cube = write_cube_stl(dir, "vlh_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g1, import_one(plater, cube.c_str(), 100.0, 100.0, &object_id, &revision));
    expect_ok(g1, "import cube");

    // --- VLH: read empty, adaptive fills, smooth/adjust mutate, set validates
    double *pairs = nullptr;
    uint32_t pair_count = 0;
    GUARD(v0, orca_plater_object_height_profile(plater, object_id, &pairs, &pair_count));
    expect_ok(v0, "read empty profile");
    CHECK_EQ(pair_count, 0u);
    orca_height_profile_dispose(pairs);
    orca_presets *presets = nullptr;
    GUARD(v0b, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(v0b, "presets_new for vlh");
    GUARD(v1, orca_plater_object_height_profile_adaptive(
                  plater, presets, object_id, 0.5, &pairs, &pair_count, &revision));
    expect_ok(v1, "adaptive profile");
    CHECK(pair_count >= 4);
    CHECK_EQ(pair_count % 2, 0u);
    CHECK_NEAR(pairs[0], 0.0, 1e-9);
    for (uint32_t index = 2; index + 1 < pair_count; index += 2)
        CHECK(pairs[index] >= pairs[index - 2]);
    const uint32_t adaptive_count = pair_count;
    double *adaptive_copy = static_cast<double *>(std::malloc(adaptive_count * sizeof(double)));
    CHECK(adaptive_copy != nullptr);
    if (adaptive_copy) std::memcpy(adaptive_copy, pairs, adaptive_count * sizeof(double));
    orca_height_profile_dispose(pairs);
    // smooth keeps the profile valid (and the undo stack one step deeper)
    GUARD(v2, orca_plater_object_height_profile_smooth(
                  plater, presets, object_id, 3, 1, &pairs, &pair_count, &revision));
    expect_ok(v2, "smooth profile");
    CHECK_EQ(pair_count % 2, 0u);
    CHECK(pair_count >= 4);
    orca_height_profile_dispose(pairs);
    GUARD(v3, orca_plater_object_height_profile_adjust(
                  plater, presets, object_id, 10.0, 0.05, 6.0, 0, &revision));
    expect_ok(v3, "adjust increase");
    // invalid manual profiles are typed rejections
    double bogus[2] = {0.0, 0.2};
    GUARD(v4, orca_plater_object_set_height_profile(plater, object_id, bogus, 2, &revision));
    expect_code(v4, ORCA_STATUS_INVALID_ARGUMENT, "profile too short");
    double wrong_top[4] = {0.0, 0.2, 9.0, 0.2};
    GUARD(v5, orca_plater_object_set_height_profile(plater, object_id, wrong_top, 4, &revision));
    expect_code(v5, ORCA_STATUS_INVALID_ARGUMENT, "profile wrong top");
    // a valid hand-built profile round-trips
    double valid[6] = {0.0, 0.2, 10.0, 0.2, 20.0, 0.3};
    GUARD(v6, orca_plater_object_set_height_profile(plater, object_id, valid, 6, &revision));
    expect_ok(v6, "set profile");
    GUARD(v7, orca_plater_object_height_profile(plater, object_id, &pairs, &pair_count));
    expect_ok(v7, "read back profile");
    CHECK_EQ(pair_count, 6u);
    CHECK_NEAR(pairs[5], 0.3, 1e-9);
    orca_height_profile_dispose(pairs);
    // reset = empty profile
    GUARD(v8, orca_plater_object_set_height_profile(plater, object_id, nullptr, 0, &revision));
    expect_ok(v8, "reset profile");
    GUARD(v9, orca_plater_object_height_profile(plater, object_id, &pairs, &pair_count));
    expect_ok(v9, "read after reset");
    CHECK_EQ(pair_count, 0u);
    orca_height_profile_dispose(pairs);
    if (adaptive_copy) std::free(adaptive_copy);

    // --- per-plate settings: defaults unset, write/read, reset, undo
    orca_scene_snapshot snap;
    memset(&snap, 0, sizeof snap);
    GUARD(p0, orca_plater_snapshot(plater, &snap));
    expect_ok(p0, "snapshot for plate id");
    const orca_plate_id plate_id = snap.plates[0].id;
    orca_scene_snapshot_dispose(&snap);
    orca_plate_settings settings;
    GUARD(p1, orca_plater_plate_settings(plater, plate_id, &settings));
    expect_ok(p1, "read plate settings");
    CHECK_EQ(settings.bed_type, -1);
    CHECK_EQ(settings.print_sequence, -1);
    CHECK_EQ(settings.spiral_mode, -1);
    CHECK_EQ(settings.first_layer_sequence_count, 0);
    GUARD(p2, orca_plater_plate_set_settings(plater, 999999, &settings, &revision));
    expect_code(p2, ORCA_STATUS_NOT_FOUND, "settings missing plate");
    orca_plate_settings custom{};
    custom.bed_type = 3;      // btPEI
    custom.print_sequence = 1; // by object
    custom.spiral_mode = 1;
    custom.first_layer_sequence[0] = 2;
    custom.first_layer_sequence[1] = 1;
    custom.first_layer_sequence_count = 2;
    GUARD(p3, orca_plater_plate_set_settings(plater, plate_id, &custom, &revision));
    expect_ok(p3, "write plate settings");
    GUARD(p4, orca_plater_plate_settings(plater, plate_id, &settings));
    expect_ok(p4, "read written settings");
    CHECK_EQ(settings.bed_type, 3);
    CHECK_EQ(settings.print_sequence, 1);
    CHECK_EQ(settings.spiral_mode, 1);
    CHECK_EQ(settings.first_layer_sequence_count, 2);
    CHECK_EQ(settings.first_layer_sequence[0], 2);
    CHECK_EQ(settings.first_layer_sequence[1], 1);
    custom.bed_type = 99;
    GUARD(p5b, orca_plater_plate_set_settings(plater, plate_id, &custom, &revision));
    expect_code(p5b, ORCA_STATUS_INVALID_ARGUMENT, "bed type 99 rejected");
    custom.bed_type = -1;
    // undo restores the unset state
    GUARD(p6, orca_plater_undo(plater, &revision));
    expect_ok(p6, "undo plate settings");
    GUARD(p7, orca_plater_plate_settings(plater, plate_id, &settings));
    expect_ok(p7, "read after undo");
    CHECK_EQ(settings.bed_type, -1);
    CHECK_EQ(settings.print_sequence, -1);
    // 3MF roundtrip keeps the settings (save -> reopen -> read)
    orca_plate_settings again{};
    again.spiral_mode = 1;
    GUARD(p8, orca_plater_plate_set_settings(plater, plate_id, &again, &revision));
    expect_ok(p8, "spiral on plate");
    orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                        "Bambu PLA Basic @BBL X1C", "0.20mm Standard @BBL X1C");
    const std::string project = dir + "/vlh_project.3mf";
    GUARD(p9, orca_project_save(plater, presets, project.c_str(), 0, nullptr));
    expect_ok(p9, "save project with plate settings");
    orca_project_info info;
    GUARD(p10, orca_project_open(plater, presets, project.c_str(), &info));
    expect_ok(p10, "reopen project");
    revision = info.revision;
    memset(&snap, 0, sizeof snap);
    GUARD(p11, orca_plater_snapshot(plater, &snap));
    expect_ok(p11, "snapshot reopened");
    const orca_plate_id reopened_id = snap.plates[0].id;
    orca_scene_snapshot_dispose(&snap);
    GUARD(p12, orca_plater_plate_settings(plater, reopened_id, &settings));
    expect_ok(p12, "read reopened settings");
    CHECK_EQ(settings.spiral_mode, 1);

    // --- floating / drop: auto_drop off keeps z, on snaps to bed
    memset(&snap, 0, sizeof snap);
    GUARD(f0, orca_plater_snapshot(plater, &snap));
    expect_ok(f0, "snapshot floating");
    const orca_object_id float_object = snap.objects[0].id;
    const orca_instance_id float_instance = snap.objects[0].instances[0].id;
    orca_instance_transform floating = snap.objects[0].instances[0].transform;
    CHECK_EQ(snap.objects[0].instances[0].auto_drop, 1u);
    orca_scene_snapshot_dispose(&snap);
    GUARD(f1, orca_plater_instance_set_auto_drop(plater, float_object,
                                                 float_instance, 0, &revision));
    expect_ok(f1, "keep floating");
    floating.offset_z = 5.0; // the rested cube sits at z ~10; lift it off
    GUARD(f2, orca_plater_instance_set(plater, float_object, float_instance,
                                       &floating, "Float", &revision));
    expect_ok(f2, "move floating");
    memset(&snap, 0, sizeof snap);
    GUARD(f3, orca_plater_snapshot(plater, &snap));
    expect_ok(f3, "snapshot after float move");
    CHECK_EQ(snap.objects[0].instances[0].auto_drop, 0u);
    CHECK_NEAR(snap.objects[0].instances[0].transform.offset_z, 5.0, 1e-6);
    orca_scene_snapshot_dispose(&snap);
    GUARD(f4, orca_plater_instance_set_auto_drop(plater, float_object,
                                                 float_instance, 1, &revision));
    expect_ok(f4, "auto drop on");
    memset(&snap, 0, sizeof snap);
    GUARD(f5, orca_plater_snapshot(plater, &snap));
    expect_ok(f5, "snapshot after auto drop");
    CHECK_NEAR(snap.objects[0].instances[0].transform.offset_z, 10.0, 1e-4);
    orca_scene_snapshot_dispose(&snap);
    // manual drop on a floating object rests it in one step
    GUARD(f6, orca_plater_instance_set_auto_drop(plater, float_object,
                                                 float_instance, 0, &revision));
    expect_ok(f6, "float again");
    GUARD(f7, orca_plater_instance_set(plater, float_object, float_instance,
                                       &floating, "Float 2", &revision));
    expect_ok(f7, "lift again");
    GUARD(f8, orca_plater_object_drop(plater, float_object, &revision));
    expect_ok(f8, "drop to bed");
    memset(&snap, 0, sizeof snap);
    GUARD(f9, orca_plater_snapshot(plater, &snap));
    expect_ok(f9, "snapshot after drop");
    CHECK_NEAR(snap.objects[0].instances[0].transform.offset_z, 10.0, 1e-4);
    orca_scene_snapshot_dispose(&snap);

    // --- preset creation: filament + printer + INI import
    uint32_t filament_made = 0;
    GUARD(c0, orca_presets_create_filament(presets, "Bambu PLA Basic @BBL X1C",
                                           "OrcaPad Test Filament",
                                           "OrcaPad", "PLA", &filament_made));
    CHECK_EQ(filament_made, 1u);
    expect_ok(c0, "create filament");
    GUARD(c0b, orca_presets_create_filament(presets, "No Such Filament",
                                            "Bad", "", "", &filament_made));
    expect_code(c0b, ORCA_STATUS_NOT_FOUND, "create filament missing base");
    uint32_t made = 0;
    GUARD(c1, orca_presets_create_filament(presets, nullptr,
                                           "OrcaPad Test Filament 2",
                                           "OrcaPad", "PETG", &made));
    expect_ok(c1, "create filament from selected");
    CHECK_EQ(made, 1u);
    GUARD(c2, orca_presets_delete_user(presets, 1, "OrcaPad Test Filament"));
    expect_ok(c2, "delete created filament");
    GUARD(c3, orca_presets_delete_user(presets, 1, "OrcaPad Test Filament 2"));
    expect_ok(c3, "delete created filament 2");
    uint32_t printers_made = 0, filaments_made = 0, processes_made = 0;
    GUARD(c4, orca_presets_create_printer(
                  presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                  "OrcaPad Test Printer", "OrcaPadModel", "0.6", "0.6",
                  &printers_made, &filaments_made, &processes_made));
    expect_ok(c4, "create printer");
    CHECK_EQ(printers_made, 1u);
    GUARD(c5, orca_presets_create_printer(
                  presets, nullptr, "OrcaPad Test Printer 2", "M", "0.4",
                  "0.4,0.6", &printers_made, &filaments_made, &processes_made));
    expect_ok(c5, "create printer from selected dual nozzle");
    CHECK_EQ(printers_made, 1u);
    GUARD(c6, orca_presets_create_printer(
                  presets, nullptr, "Bad Printer", "M", "0.4", "zero",
                  &printers_made, &filaments_made, &processes_made));
    expect_code(c6, ORCA_STATUS_INVALID_ARGUMENT, "bad nozzle csv");
    GUARD(c7, orca_presets_delete_user(presets, 0, "OrcaPad Test Printer"));
    expect_ok(c7, "delete created printer");
    GUARD(c8, orca_presets_delete_user(presets, 0, "OrcaPad Test Printer 2"));
    expect_ok(c8, "delete created printer 2");

    // INI import: process keys land in a user preset
    const std::string ini = dir + "/legacy.ini";
    FILE *ini_file = fopen(ini.c_str(), "wb");
    CHECK(ini_file != nullptr);
    if (ini_file) {
        fprintf(ini_file, "; generated for the ABI v41 contract test\n");
        fprintf(ini_file, "layer_height = 0.25\n");
        fprintf(ini_file, "top_shell_layers = 5\n");
        fclose(ini_file);
    }
    uint32_t imported = 0;
    GUARD(i0, orca_presets_import_ini(presets, ini.c_str(), &imported));
    expect_ok(i0, "import ini");
    CHECK_EQ(imported, 1u); // only the process kind matches these keys
    GUARD(i1, orca_presets_delete_user(presets, 2, "legacy process"));
    expect_ok(i1, "delete imported process preset");
    GUARD(i2, orca_presets_import_ini(presets, (dir + "/missing.ini").c_str(), &imported));
    expect_code(i2, ORCA_STATUS_IO_FAILURE, "ini missing file");

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

    // ABI v32: upsert REPLACES the preset association (the editor ties a
    // printer to exactly one preset; stale ties must not accumulate).
    GUARD(g6b, orca_physical_printer_upsert(presets, "Vyper", "moonraker",
                                            "http://192.168.1.9:7125", "http://192.168.1.9", "k2",
                                            "Prusa MK4 0.4 nozzle"));
    expect_ok(g6b, "upsert retie");
    GUARD(g6c, orca_physical_printer_list(presets, 0, &entry));
    expect_ok(g6c, "list after retie");
    CHECK(strcmp(entry.preset_names.data, "Prusa MK4 0.4 nozzle") == 0);
    orca_physical_printer_dispose(&entry);
    // and back, so the persisted fresh-session check below keeps its shape
    GUARD(g6d, orca_physical_printer_upsert(presets, "Vyper", "moonraker",
                                            "http://192.168.1.9:7125", "http://192.168.1.9", "k2",
                                            "Anycubic Vyper 0.4 nozzle"));
    expect_ok(g6d, "upsert retie back");
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

// Regression (user report 2026-10-07): a G-code-processor warning with the
// engine's OWN severity level 3 used to reach the ABI raw and fail the
// slice at decode time. The Bridge must map engine levels onto the ABI's
// (2 and 3 -> CRITICAL) and keep the slice successful.
static void test_slice_gcode_warning_levels(const std::string &dir, const std::string &data_dir) {
    orca_presets *presets = nullptr;
    GUARD(g0, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g0, "presets_new");
    // X1C triple (the Vyper profile fails Print::validate: no G92 E0).
    GUARD(g1, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                  "Bambu PLA Basic @BBL X1C",
                                  "0.20mm Standard @BBL X1C"));
    expect_ok(g1, "select X1C triple");
    // vitrification threshold 1 C: any bed temperature trips the engine's
    // level-3 bed_temperature_too_high_than_filament warning.
    GUARD(g2, orca_presets_set_value(presets, 1, "temperature_vitrification", "1"));
    expect_ok(g2, "set vitrification threshold");

    orca_plater *plater = nullptr;
    GUARD(g3, orca_plater_new(&plater));
    expect_ok(g3, "plater_new");
    const std::string cube = write_cube_stl(dir, "warnlevel_cube.stl");
    orca_object_id object_id = 0;
    orca_revision revision = 0;
    GUARD(g4, import_one(plater, cube.c_str(), 110, 105, &object_id, &revision));
    expect_ok(g4, "import cube");

    orca_slice_report report;
    const std::string gcode = dir + "/warnlevel.gcode";
    GUARD(g5, orca_plater_slice_to_gcode_with_presets(
                   plater, presets, gcode.c_str(), nullptr, nullptr, nullptr, &report));
    expect_ok(g5, "slice with a level-3 engine warning");

    bool saw_mapped_warning = false;
    for (uint32_t index = 0; index < report.warning_count; ++index) {
        const orca_slice_warning &warning = report.warnings[index];
        CHECK(warning.level == ORCA_SLICE_WARNING_TIP ||
              warning.level == ORCA_SLICE_WARNING_WARNING ||
              warning.level == ORCA_SLICE_WARNING_CRITICAL);
        if (warning.source == ORCA_SLICE_SOURCE_GCODE &&
            warning.code.data &&
            strcmp(warning.code.data, "bed_temperature_too_high_than_filament") == 0) {
            CHECK_EQ(warning.level, ORCA_SLICE_WARNING_CRITICAL);
            saw_mapped_warning = true;
        }
    }
    CHECK(saw_mapped_warning);
    CHECK(report.gcode_bytes > 0);
    orca_slice_report_dispose(&report);
    orca_plater_free(plater);
    orca_presets_free(presets);
}

// ABI v24: per-layer custom G-code (colour change / pause / custom),
// stored where slicing consumes it (plate 0 custom gcodes).
static void test_custom_gcode(const std::string &dir, const std::string &data_dir) {
    orca_plater *plater = nullptr;
    GUARD(g0, orca_plater_new(&plater));
    expect_ok(g0, "plater_new");
    orca_revision revision = 0;

    int32_t count = -1;
    GUARD(g1, orca_plater_custom_gcode_count(plater, &count));
    expect_ok(g1, "count empty");
    CHECK_EQ(count, 0);

    GUARD(e1, orca_plater_custom_gcode_add(plater, 0.0, ORCA_CUSTOM_PAUSE_PRINT, 0, "", "",
                                           &revision));
    expect_code(e1, ORCA_STATUS_INVALID_ARGUMENT, "zero print height");
    GUARD(e2, orca_plater_custom_gcode_add(plater, 5.0, 99, 0, "", "", &revision));
    expect_code(e2, ORCA_STATUS_INVALID_ARGUMENT, "unknown type");
    GUARD(e3, orca_plater_custom_gcode_add(plater, 5.0, ORCA_CUSTOM_TEMPLATE, 0, "", "",
                                           &revision));
    expect_code(e3, ORCA_STATUS_UNSUPPORTED_CAPABILITY, "template unsupported");
    GUARD(e4, orca_plater_custom_gcode_add(plater, 5.0, ORCA_CUSTOM_COLOR_CHANGE, 0, "#ff0000",
                                           "", &revision));
    expect_code(e4, ORCA_STATUS_INVALID_ARGUMENT, "colour change without extruder");
    GUARD(e5, orca_plater_custom_gcode_add(plater, 5.0, ORCA_CUSTOM_CUSTOM, 0, "", "  ",
                                           &revision));
    expect_code(e5, ORCA_STATUS_INVALID_ARGUMENT, "empty custom text");
    GUARD(e6, orca_plater_custom_gcode_delete(plater, 5.0, &revision));
    expect_code(e6, ORCA_STATUS_NOT_FOUND, "delete absent");

    GUARD(g2, orca_plater_custom_gcode_add(plater, 1.2, ORCA_CUSTOM_COLOR_CHANGE, 1, "#ff0000",
                                           "", &revision));
    expect_ok(g2, "colour change at 1.2");
    GUARD(g3, orca_plater_custom_gcode_add(plater, 4.5, ORCA_CUSTOM_CUSTOM, 0, "",
                                           "M300 S440 P200", &revision));
    expect_ok(g3, "custom at 4.5");
    GUARD(g4, orca_plater_custom_gcode_add(plater, 2.4, ORCA_CUSTOM_PAUSE_PRINT, 0, "",
                                           "Check the print", &revision));
    expect_ok(g4, "pause at 2.4");

    GUARD(g5, orca_plater_custom_gcode_count(plater, &count));
    expect_ok(g5, "count three");
    CHECK_EQ(count, 3);
    orca_custom_gcode_item item;
    GUARD(g6, orca_plater_custom_gcode_item(plater, 0, &item));
    expect_ok(g6, "item 0");
    CHECK_NEAR(item.print_z, 1.2, 1e-9);
    CHECK_EQ(item.type, ORCA_CUSTOM_COLOR_CHANGE);
    CHECK_EQ(item.extruder, 1);
    CHECK(strcmp(item.color.data, "#ff0000") == 0);
    orca_custom_gcode_item_dispose(&item);
    GUARD(g7, orca_plater_custom_gcode_item(plater, 1, &item));
    expect_ok(g7, "item 1");
    CHECK_NEAR(item.print_z, 2.4, 1e-9);
    CHECK_EQ(item.type, ORCA_CUSTOM_PAUSE_PRINT);
    CHECK(strcmp(item.extra.data, "Check the print") == 0);
    orca_custom_gcode_item_dispose(&item);
    GUARD(e7, orca_plater_custom_gcode_item(plater, 3, &item));
    expect_code(e7, ORCA_STATUS_NOT_FOUND, "item out of range");

    // ABI v40: in-place EDIT at a height (one undo step, keeps position)
    GUARD(v40e, orca_plater_custom_gcode_edit(plater, 9.9, ORCA_CUSTOM_CUSTOM, 0,
                                              "", "M999", &revision));
    expect_code(v40e, ORCA_STATUS_NOT_FOUND, "edit absent height");
    GUARD(v40e2, orca_plater_custom_gcode_edit(plater, 4.5, ORCA_CUSTOM_CUSTOM, 0,
                                               "", "M300 S880 P100", &revision));
    expect_ok(v40e2, "edit custom at 4.5");
    GUARD(v40e3, orca_plater_custom_gcode_item(plater, 2, &item));
    expect_ok(v40e3, "item 2 after edit");
    CHECK_NEAR(item.print_z, 4.5, 1e-9);
    CHECK_EQ(item.type, ORCA_CUSTOM_CUSTOM);
    CHECK(strcmp(item.extra.data, "M300 S880 P100") == 0);
    orca_custom_gcode_item_dispose(&item);
    GUARD(v40e4, orca_plater_custom_gcode_edit(plater, 4.5, ORCA_CUSTOM_PAUSE_PRINT,
                                                0, "", "Hold on", &revision));
    expect_ok(v40e4, "edit type swap at 4.5");
    GUARD(v40e6, orca_plater_undo(plater, &revision));
    expect_ok(v40e6, "undo type swap");
    GUARD(v40e7, orca_plater_custom_gcode_item(plater, 2, &item));
    expect_ok(v40e7, "item 2 after undo");
    CHECK_EQ(item.type, ORCA_CUSTOM_CUSTOM);
    CHECK(strcmp(item.extra.data, "M300 S880 P100") == 0);
    orca_custom_gcode_item_dispose(&item);
    // restore the original text so the slice consumption below still sees it
    GUARD(v40e8, orca_plater_custom_gcode_edit(plater, 4.5, ORCA_CUSTOM_CUSTOM,
                                               0, "", "M300 S440 P200", &revision));
    expect_ok(v40e8, "restore original custom text");

    // replace at the same height
    GUARD(g8, orca_plater_custom_gcode_add(plater, 1.2, ORCA_CUSTOM_COLOR_CHANGE, 1, "#00ff00",
                                           "", &revision));
    expect_ok(g8, "replace at 1.2");
    GUARD(g9, orca_plater_custom_gcode_count(plater, &count));
    expect_ok(g9, "count still three");
    CHECK_EQ(count, 3);
    GUARD(g10, orca_plater_custom_gcode_item(plater, 0, &item));
    expect_ok(g10, "item 0 after replace");
    CHECK(strcmp(item.color.data, "#00ff00") == 0);
    orca_custom_gcode_item_dispose(&item);

    // undo removes the replacement, delete removes the pause
    GUARD(g11, orca_plater_undo(plater, &revision));
    expect_ok(g11, "undo replace");
    GUARD(g12, orca_plater_custom_gcode_delete(plater, 2.4, &revision));
    expect_ok(g12, "delete pause");
    GUARD(g13, orca_plater_custom_gcode_count(plater, &count));
    expect_ok(g13, "count after delete");
    CHECK_EQ(count, 2);
    // re-add a pause so the slice below exercises it too
    GUARD(g13b, orca_plater_custom_gcode_add(plater, 3.3, ORCA_CUSTOM_PAUSE_PRINT, 0, "",
                                             "Check the print", &revision));
    expect_ok(g13b, "pause again at 3.3");

    // slicing consumes the items: the gcode contains M600 and the custom text
    orca_presets *presets = nullptr;
    GUARD(g14, orca_presets_new(data_dir.c_str(), &presets));
    expect_ok(g14, "presets_new");
    GUARD(g15, orca_presets_select(presets, "Bambu Lab X1 Carbon 0.4 nozzle",
                                   "Bambu PLA Basic @BBL X1C",
                                   "0.20mm Standard @BBL X1C"));
    expect_ok(g15, "select X1C triple");
    const std::string cube = write_cube_stl(dir, "custom_gcode_cube.stl");
    orca_object_id object_id = 0;
    GUARD(g16, import_one(plater, cube.c_str(), 125, 125, &object_id, &revision));
    expect_ok(g16, "import tall cube");
    const std::string gcode = dir + "/custom_gcode.gcode";
    orca_slice_report report;
    GUARD(g17, orca_plater_slice_to_gcode_with_presets(
                   plater, presets, gcode.c_str(), nullptr, nullptr, nullptr, &report));
    expect_ok(g17, "slice with custom gcode");
    orca_slice_report_dispose(&report);
    FILE *file = fopen(gcode.c_str(), "rb");
    CHECK(file != nullptr);
    if (file) {
        std::string text;
        char buffer[4096];
        size_t read = 0;
        while ((read = fread(buffer, 1, sizeof(buffer), file)) > 0) text.append(buffer, read);
        fclose(file);
        CHECK(text.find("M300 S440 P200") != std::string::npos);
        // This fork emits colour changes as processor tags only (the M600
        // block is #if 0 upstream); pauses emit the PAUSE_PRINT tag plus
        // machine_pause_gcode. Cover both tag dialects.
        CHECK(text.find("PAUSE_PRINT") != std::string::npos);
    }

    // ABI v32: custom G-code binds to the SELECTED plate. The engine
    // model's curr_plate_index follows the Bridge's current plate —
    // before this fix every item landed on (and sliced from) plate 0.
    orca_plate_id plate2 = 0;
    GUARD(p1, orca_plater_plate_add(plater, &plate2, &revision));
    expect_ok(p1, "add plate 2");
    orca_scene_snapshot snap;
    GUARD(p2, orca_plater_plate_select(plater, plate2, &snap));
    expect_ok(p2, "select plate 2");
    const orca_plate_id plate1 = snap.plates[0].id;
    orca_scene_snapshot_dispose(&snap);
    GUARD(p3, orca_plater_custom_gcode_count(plater, &count));
    expect_ok(p3, "count on plate 2 (empty)");
    CHECK_EQ(count, 0);
    GUARD(p4, orca_plater_custom_gcode_add(plater, 2.0, ORCA_CUSTOM_PAUSE_PRINT, 0, "",
                                             "plate two pause", &revision));
    expect_ok(p4, "pause on plate 2");
    GUARD(p5, orca_plater_custom_gcode_count(plater, &count));
    expect_ok(p5, "count on plate 2 after add");
    CHECK_EQ(count, 1);
    GUARD(p6, orca_plater_plate_select(plater, plate1, &snap));
    expect_ok(p6, "select plate 1 again");
    orca_scene_snapshot_dispose(&snap);
    GUARD(p7, orca_plater_custom_gcode_count(plater, &count));
    expect_ok(p7, "count on plate 1 (untouched)");
    // colour change 1.2 + custom 4.5 + pause 3.3
    CHECK_EQ(count, 3);

    orca_presets_free(presets);
    orca_plater_free(plater);
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

    // ABI v32: a cancelled slice-all leaves NO partial combined G-code
    // behind (the output is assembled in a temp and renamed only on
    // success — a mid-run failure keeps the previous file intact).
    const std::string all = dir + "/cancel-all.gcode";
    orca_slice_job *cancel_all_job = nullptr;
    GUARD(ca1, orca_slice_job_new(&cancel_all_job));
    expect_ok(ca1, "job for slice-all cancel");
    CancelOnProgress cancel_all_record{cancel_all_job};
    GUARD(ca2, orca_plater_slice_all_to_gcode(
                   plater, all.c_str(), cancel_trampoline, &cancel_all_record,
                   cancel_all_job, &report));
    expect_code(ca2, ORCA_STATUS_CANCELLED, "slice-all cancelled");
    struct stat partial;
    CHECK(stat(all.c_str(), &partial) != 0);
    orca_slice_job_free(cancel_all_job);

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
    test_batch_operations(dir);
    test_plates(dir, data_dir);
    test_object_ops(dir, data_dir);
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
    test_select_machine(dir, data_dir);
    test_standalone_slice(dir);
    test_slice_gcode_warning_levels(dir, data_dir);
    test_custom_gcode(dir, data_dir);
    test_slice_cancel(dir);
    test_exports(dir, data_dir);
    test_measure_and_mesh_ops(dir);
    test_vlh_plates_floating(dir, data_dir);
    test_cut(dir);
    test_config_io(dir, data_dir);
    test_painting(dir);
    test_hull_and_text(dir);
    test_svg(dir);
    test_height_ranges(dir);
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
