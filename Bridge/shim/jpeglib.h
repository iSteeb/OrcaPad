#pragma once
// OrcaPad adapter shim: declaration-only libjpeg surface for the upstream
// GCode/Thumbnails.cpp compile. Only compress_thumbnail_jpg touches libjpeg;
// OrcaPad provides loud-throwing definitions (Bridge/engine-cxx/jpeg_stubs.cpp)
// so JPG thumbnails fail typed while PNG/QOI work through vendored miniz/qoi.
// Struct layouts here are NOT the real libjpeg ABI — never link real libjpeg
// against this header.
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

#define JPEG_LIB_VERSION 80

typedef int boolean;
#ifndef TRUE
#define TRUE 1
#define FALSE 0
#endif

enum J_COLOR_SPACE { JCS_UNKNOWN, JCS_GRAYSCALE, JCS_RGB, JCS_YCbCr, JCS_CMYK, JCS_YCCK, JCS_EXT_RGB, JCS_EXT_RGBA };

struct jpeg_error_mgr {
    int placeholder;
};

struct jpeg_memory_mgr {
    int placeholder;
};

struct jpeg_destination_mgr {
    unsigned char *next_output_byte;
    size_t free_in_buffer;
    void (*init_destination)(void *);
    int (*empty_output_buffer)(void *);
    void (*term_destination)(void *);
};

struct jpeg_compress_struct {
    jpeg_error_mgr *err;
    jpeg_memory_mgr *mem;
    jpeg_destination_mgr *dest;
    unsigned long image_width;
    unsigned long image_height;
    int input_components;
    J_COLOR_SPACE in_color_space;
};

struct jpeg_error_mgr *jpeg_std_error(struct jpeg_error_mgr *err);
void jpeg_create_compress(jpeg_compress_struct *cinfo);
void jpeg_mem_dest(jpeg_compress_struct *cinfo, unsigned char **outbuffer,
                   unsigned long *outsize);
void jpeg_set_defaults(jpeg_compress_struct *cinfo);
void jpeg_set_quality(jpeg_compress_struct *cinfo, int quality,
                      boolean force_baseline);
void jpeg_start_compress(jpeg_compress_struct *cinfo,
                         boolean write_all_tables);
int jpeg_write_scanlines(jpeg_compress_struct *cinfo,
                         unsigned char **scanlines, int num_lines);
void jpeg_finish_compress(jpeg_compress_struct *cinfo);
void jpeg_destroy_compress(jpeg_compress_struct *cinfo);

#ifdef __cplusplus
}
#endif
