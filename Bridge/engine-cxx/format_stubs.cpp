// SPDX-License-Identifier: AGPL-3.0-only
// Copyright (c) 2026 OrcaPad contributors

// OrcaPad adapter: loud stubs for model formats whose engines (draco, OCCT)
// are not yet cross-built for iOS (3MF is the real Format/3mf.cpp +
// Format/bbs_3mf.cpp). Each throws the moment
// it is called — no silent fallbacks. Replace as real deps land.
// NOTE: everything is inside namespace Slic3r to match the headers' linkage.
#include "libslic3r/Config.hpp"
#include "libslic3r/Exception.hpp"
#include "libslic3r/Format/3mf.hpp"
#include "libslic3r/Format/STEP.hpp"
#include "libslic3r/Format/bbs_3mf.hpp"
#include "libslic3r/GCode/Thumbnails.hpp"
#include "libslic3r/Model.hpp"

#include <stdexcept>
#include <string>

namespace Slic3r {

static void orcapad_unsupported(const char *what) {
    throw Slic3r::RuntimeError(std::string("OrcaPad: ") + what +
                               " not supported in this build (dependency not yet ported)");
}

void delete_temp_file(const std::string &) {
    orcapad_unsupported("3MF temp file cleanup");
}

// --- STEP (blocked on OCCT) ---
bool load_step(const char *, Model *, bool &,
               double, double, bool, ImportStepProgressFn,
               StepIsUtf8Fn, long &) {
    orcapad_unsupported("STEP import");
}
Step::Step(fs::path, ImportStepProgressFn, StepIsUtf8Fn) {}
Step::Step(std::string, ImportStepProgressFn, StepIsUtf8Fn) {}
Step::~Step() = default;
Step::Step_Status Step::load() {
    orcapad_unsupported("STEP load");
}
Step::Step_Status Step::mesh(Model *, bool &, bool, double, double) {
    orcapad_unsupported("STEP mesh conversion");
}

// --- GCode thumbnails: the REAL GCode/Thumbnails.cpp is compiled into the
// closure (pure-string list parsing for load paths; PNG/QOI via vendored
// miniz/qoi; JPEG reaches the loud adapter in jpeg_stubs.cpp).

} // namespace Slic3r

// --- more format/utility adapters (same walls as above) ---
#include "libslic3r/Format/DRC.hpp"
#include "libslic3r/Format/bbs_3mf.hpp"
#include "libslic3r/Format/svg.hpp"
#include "libslic3r/Utils.hpp"
#include <unistd.h>

namespace Slic3r {

unsigned get_current_pid() { return (unsigned)getpid(); } // real: iOS has getpid

bool load_drc(const char *, Model *, const char *) {
    orcapad_unsupported("DRC import");
}
bool load_svg(const char *, Model *, std::string &) {
    orcapad_unsupported("SVG import");
}
std::string make_temp_stl_with_modelio(const std::string &) {
    orcapad_unsupported("ModelIO STEP conversion");
}

// --- MeshBoolean (CGAL/mcut wall) ---
#include "libslic3r/MeshBoolean.hpp"
namespace MeshBoolean { namespace mcut {
bool make_boolean(const TriangleMesh &, const TriangleMesh &,
                  std::vector<TriangleMesh> &, const std::string &) {
    orcapad_unsupported("mesh boolean");
}
}} // namespace MeshBoolean::mcut

} // namespace Slic3r

// --- misc utilities from macOS-leaning files ---
namespace Slic3r {
// Utils.cpp (needs libproc/procfs): memory logging is a diagnostics aid;
// reporting "unavailable" is honest, not a feature fallback.
std::string log_memory_info(bool) { return "memory info unavailable on OrcaPad"; }
} // namespace Slic3r

// --- utils.cpp adapters (macOS libproc wall) — REAL implementations ---
#include <fstream>
namespace Slic3r {

// Pure string logic from utils.cpp:1749 — reimplemented identically.
bool check_layer_id_pattern(const std::string &pattern, int layer_id);

// (definition below, out-of-line to keep the adapter readable)
static bool orcapad_layer_id_match(const std::string &pattern, int layer_id);

bool check_layer_id_pattern(const std::string &pattern, int layer_id) {
    return orcapad_layer_id_match(pattern, layer_id);
}
static bool orcapad_layer_id_match(const std::string &pattern, int layer_id) {
    // Accepts "N", "aN" (every N), "bN" (before N), "aN-bM" ranges —
    // semantics mirrored from utils.cpp (used by layer-specific gcode).
    if (pattern.empty()) return false;
    try {
        size_t pos = 0;
        auto parse = [&](const char *p, size_t &i) -> int {
            int v = 0; bool any = false;
            while (i < pattern.size() && isdigit((unsigned char)pattern[i])) {
                v = v * 10 + (pattern[i] - '0'); ++i; any = true;
            }
            if (!any) throw std::invalid_argument("no digits");
            (void)p;
            return v;
        };
        if (pattern[0] == 'a' || pattern[0] == 'b') {
            bool every = pattern[0] == 'a';
            pos = 1;
            int v = parse("", pos);
            if (pos != pattern.size()) {
                // range aN-bM
                if (pos + 1 < pattern.size() && pattern[pos] == '-') {
                    size_t p2 = pos + 1;
                    if (pattern[p2] == 'b') {
                        ++p2;
                        int hi = parse("", p2);
                        return layer_id >= v && layer_id <= hi;
                    }
                }
                throw std::invalid_argument("bad range");
            }
            return every ? (layer_id % v == 0) : (layer_id < v);
        }
        int v = parse("", pos);
        return pos == pattern.size() && layer_id == v;
    } catch (...) {
        return false;
    }
}

void save_string_file(const fs::path &path, const std::string &data) {
    std::ofstream f(path.string(), std::ios::binary | std::ios::trunc);
    if (!f) orcapad_unsupported("save_string_file open failed");
    f.write(data.data(), (std::streamsize)data.size());
    if (!f) orcapad_unsupported("save_string_file write failed");
}
void load_string_file(const fs::path &path, std::string &out) {
    std::ifstream f(path.string(), std::ios::binary);
    if (!f) orcapad_unsupported("load_string_file open failed");
    out.assign((std::istreambuf_iterator<char>(f)),
               std::istreambuf_iterator<char>());
}

// Resources dir: OrcaSlicer's resource folder doesn't exist in the app
// bundle yet (Phase 3 brings profile bundles). Empty keeps callers that
// only *log* quiet; real file consumers fail loudly at open.
static std::string orcapad_resources_dir;
void set_resources_dir(const std::string &path) { orcapad_resources_dir = path; }
const std::string &resources_dir() { return orcapad_resources_dir; }


} // namespace Slic3r

// --- utils.cpp / EdgeGrid adapters: real trivial implementations ---
#include <cstdarg>
#include <cstdio>
namespace Slic3r {

std::string debug_out_path(const char *name, ...) {
    static int idx = 0;
    char buf[512];
    va_list ap;
    va_start(ap, name);
    vsnprintf(buf, sizeof(buf), name, ap);
    va_end(ap);
    return std::string("/tmp/orcapad-debug-") + std::to_string(idx++) + "-" + buf;
}

// Upstream returns (SLIC3R_APP_NAME " " SoftFever_VERSION). Desktop
// OrcaSlicer's GCodeProcessor REQUIRES a recognizable producer marker in
// the "; generated by X on Y" header or it refuses the file — mirror it.
std::string header_slic3r_generated() {
    return std::string("OrcaSlicer") + " " + SoftFever_VERSION;
}

bool is_gcode_file(const std::string &path) {
    auto ends = [&](const char *ext) {
        size_t n = strlen(ext);
        return path.size() >= n && path.compare(path.size() - n, n, ext) == 0;
    };
    return ends(".gcode") || ends(".g") || ends(".gco") || ends(".bgcode") || ends(".ngc");
}
bool is_json_file(const std::string &path) {
    return path.size() >= 5 && path.compare(path.size() - 5, 5, ".json") == 0;
}

size_t get_utf8_sequence_length(const std::string &text, size_t pos) {
    return get_utf8_sequence_length(text.c_str() + pos, text.size() - pos);
}
size_t get_utf8_sequence_length(const char *seq, size_t size) {
    if (size == 0 || seq == nullptr) return 0;
    unsigned char c = (unsigned char)seq[0];
    size_t len = (c < 0x80) ? 1 : (c & 0xE0) == 0xC0 ? 2 : (c & 0xF0) == 0xE0 ? 3 : (c & 0xF8) == 0xF0 ? 4 : 1;
    return len <= size ? len : 1;
}

} // namespace Slic3r

// --- png debug output (EdgeGrid debug dumps; libpng not ported) ---
namespace Slic3r { namespace png {
void write_rgb_to_file_scaled(const std::string &, size_t, size_t,
                              const std::vector<unsigned char> &, size_t) {
    // Debug-only dump helper; fails loudly rather than silently faking output.
    throw std::runtime_error("OrcaPad: png debug output not supported");
}
}} // namespace Slic3r::png

// --- thumbnails helpers: the REAL GCode/Thumbnails.cpp is compiled into the
// closure (parse + PNG/QOI encode through vendored miniz/qoi; JPEG reaches
// the loud adapter in jpeg_stubs.cpp). No stubs remain here.

// --- rename (utils.cpp wall; zip wrappers are the real miniz_extension.cpp) ---
#include "miniz_extension.hpp"
#include <cstdio>
namespace Slic3r {
std::error_code rename_file(const std::string &from, const std::string &to) {
    return std::rename(from.c_str(), to.c_str()) == 0
        ? std::error_code{} : std::make_error_code(std::errc::io_error);
}
} // namespace Slic3r

// --- temporary_dir: iOS sets TMPDIR to the app container's tmp — real impl ---
namespace Slic3r {
static std::string orcapad_temporary_dir;
void set_temporary_dir(const std::string &path) { orcapad_temporary_dir = path; }
const std::string &temporary_dir() {
    if (orcapad_temporary_dir.empty()) {
        const char *tmp = getenv("TMPDIR");
        orcapad_temporary_dir = tmp ? tmp : "/tmp";
    }
    return orcapad_temporary_dir;
}
} // namespace Slic3r

// --- utils.cpp string/path helpers needed by Format/3mf.cpp + bbs_3mf.cpp.
// utils.cpp itself is not portable (compiled boost::log/locale, real TBB,
// libproc, ObjC++ MacUtils); these bodies are copied VERBATIM from the
// pinned utils.cpp (non-Windows branches) so behaviour is identical.
#include <cstring>
#include <errno.h>
namespace Slic3r {

// utils.cpp:1291
std::string xml_escape(std::string text, bool is_marked /* = false*/)
{
    std::string::size_type pos = 0;
    for (;;)
    {
        pos = text.find_first_of("\"\'&<>", pos);
        if (pos == std::string::npos)
            break;

        std::string replacement;
        switch (text[pos])
        {
        case '\"': replacement = "&quot;"; break;
        case '\'': replacement = "&apos;"; break;
        case '&':  replacement = "&amp;";  break;
        case '<':  replacement = is_marked ? "<" :"&lt;"; break;
        case '>':  replacement = is_marked ? ">" :"&gt;"; break;
        default: break;
        }

        text.replace(pos, 1, replacement);
        pos += replacement.size();
    }

    return text;
}

// utils.cpp:1321
std::string xml_escape_double_quotes_attribute_value(std::string text)
{
    std::string::size_type pos = 0;
    for (;;) {
        pos = text.find_first_of("\"&<\r\n\t", pos);
        if (pos == std::string::npos) break;

        std::string replacement;
        switch (text[pos]) {
        case '\"': replacement = "&quot;"; break;
        case '&': replacement = "&amp;"; break;
        case '<': replacement = "&lt;"; break;
        case '\r': replacement = "&#xD;"; break;
        case '\n': replacement = "&#xA;"; break;
        case '\t': replacement = "&#x9;"; break;
        default: break;
        }

        text.replace(pos, 1, replacement);
        pos += replacement.size();
    }

    return text;
}

// utils.cpp:1346
std::string xml_unescape(std::string s)
{
    std::string ret;
    std::string::size_type i = 0;
    std::string::size_type pos = 0;
    while (i < s.size()) {
        std::string rep;
        if (s[i] == '&') {
            if (s.substr(i, 4) == "&lt;") {
                ret += s.substr(pos, i - pos) + "<";
                i += 4;
                pos = i;
            }
            else if (s.substr(i, 4) == "&gt;") {
                ret += s.substr(pos, i - pos) + ">";
                i += 4;
                pos = i;
            }
            else if (s.substr(i, 5) == "&amp;") {
                ret += s.substr(pos, i - pos) + "&";
                i += 5;
                pos = i;
            }
            else {
                ++i;
            }
        }
        else {
            ++i;
        }
    }

    ret += s.substr(pos);
    return ret;
}

// utils.cpp:1209
std::string string_printf(const char *format, ...)
{
    va_list args1;
    va_start(args1, format);
    va_list args2;
    va_copy(args2, args1);

    static const size_t INITIAL_LEN = 200;
    std::string buffer(INITIAL_LEN, '\0');

    int bufflen = ::vsnprintf(buffer.data(), INITIAL_LEN - 1, format, args1);

    if (bufflen >= int(INITIAL_LEN)) {
        buffer.resize(size_t(bufflen) + 1);
        ::vsnprintf(buffer.data(), buffer.size(), format, args2);
    }

    buffer.resize(bufflen);
    va_end(args2);
    va_end(args1);

    return buffer;
}

// utils.cpp:1162 (non-WIN32 branch)
std::string decode_path(const char *src) { return src; }

// utils.cpp:1251. Upstream returns {} when the name cannot be determined.
// The iOS sandbox forbids inspecting other processes (no /proc, no public
// libproc), so only this process' own name is determinable — exactly the
// upstream failure contract for every other pid.
std::string get_process_name(int pid)
{
    if (pid != 0 && pid != int(::getpid())) return {};
#ifdef __APPLE__
    return getprogname();
#else
    return program_invocation_short_name;
#endif
}

} // namespace Slic3r
