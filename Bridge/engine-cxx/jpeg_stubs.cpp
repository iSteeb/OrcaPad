// OrcaPad adapter: loud-throwing libjpeg definitions backing the
// declaration-only shim headers (Bridge/shim/jpeglib.h). The upstream
// GCode/Thumbnails.cpp compiles against these; reaching a JPEG encode is a
// typed failure until libjpeg is actually ported (PNG/QOI thumbnails work
// through vendored miniz/qoi and never reach these symbols).
#include <stdexcept>
#include <string>

extern "C" {

static void orcapad_jpeg_unsupported(const char *symbol) {
    throw std::runtime_error(
        std::string("OrcaPad: JPEG thumbnails not supported (libjpeg not ") +
        "ported); symbol " + symbol);
}

struct jpeg_error_mgr;
struct jpeg_compress_struct;

jpeg_error_mgr *jpeg_std_error(jpeg_error_mgr *) {
    orcapad_jpeg_unsupported("jpeg_std_error");
}
void jpeg_create_compress(jpeg_compress_struct *) {
    orcapad_jpeg_unsupported("jpeg_create_compress");
}
void jpeg_mem_dest(jpeg_compress_struct *, unsigned char **, unsigned long *) {
    orcapad_jpeg_unsupported("jpeg_mem_dest");
}
void jpeg_set_defaults(jpeg_compress_struct *) {
    orcapad_jpeg_unsupported("jpeg_set_defaults");
}
void jpeg_set_quality(jpeg_compress_struct *, int, int) {
    orcapad_jpeg_unsupported("jpeg_set_quality");
}
void jpeg_start_compress(jpeg_compress_struct *, int) {
    orcapad_jpeg_unsupported("jpeg_start_compress");
}
int jpeg_write_scanlines(jpeg_compress_struct *, unsigned char **, int) {
    orcapad_jpeg_unsupported("jpeg_write_scanlines");
    return 0;
}
void jpeg_finish_compress(jpeg_compress_struct *) {
    orcapad_jpeg_unsupported("jpeg_finish_compress");
}
void jpeg_destroy_compress(jpeg_compress_struct *) {
    orcapad_jpeg_unsupported("jpeg_destroy_compress");
}

} // extern "C"
