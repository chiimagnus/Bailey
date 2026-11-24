#include "RasterRegions.h"
#include <png.h>
#include <stdlib.h>
#include <string.h>

// All libpng state and allocations stay inside C: its error jump must never
// cross a Swift frame, and no decoded whole-image pixel buffer is created.
typedef struct {
    const uint8_t *bytes;
    size_t count, offset;
    uint8_t *row, *pixels;
    BRStatus status;
} PNGRead;

static void read_bytes(png_structp png, png_bytep dst, png_size_t count) {
    PNGRead *input = png_get_io_ptr(png);
    if (count > input->count - input->offset) png_error(png, "truncated PNG");
    memcpy(dst, input->bytes + input->offset, count);
    input->offset += count;
}

static void read_error(png_structp png, png_const_charp message) {
    (void)message;
    png_longjmp(png, 1);
}

static void ignore_warning(png_structp png, png_const_charp message) {
    (void)png; (void)message;
}

BRStatus br_read_png_region(const uint8_t *bytes, size_t count,
    uint32_t image_width, uint32_t image_height,
    uint32_t x, uint32_t y, uint32_t width, uint32_t height,
    BRCancel cancelled, BRRegion *out) {
    *out = (BRRegion){0};
    if (!image_width || !image_height || (uint64_t)image_width * image_height > 32000000 ||
        !width || !height || x >= image_width || y >= image_height ||
        width > image_width - x || height > image_height - y) return BR_INVALID;
    PNGRead *input = calloc(1, sizeof(*input));
    if (!input) return BR_NO_MEMORY;
    input->bytes = bytes;
    input->count = count;
    input->status = BR_INVALID;
    png_structp png = png_create_read_struct(PNG_LIBPNG_VER_STRING, NULL, read_error, ignore_warning);
    if (!png) { free(input); return BR_NO_MEMORY; }
    png_infop info = png_create_info_struct(png);
    if (!info) { png_destroy_read_struct(&png, NULL, NULL); free(input); return BR_NO_MEMORY; }
    if (setjmp(png_jmpbuf(png))) goto cleanup;
    png_set_read_fn(png, input, read_bytes);
    png_set_user_limits(png, image_width, image_height);
    png_set_crc_action(png, PNG_CRC_ERROR_QUIT, PNG_CRC_ERROR_QUIT);
    png_read_info(png, info);
    png_uint_32 w, h;
    int depth, type, interlace, compression, filter;
    if (!png_get_IHDR(png, info, &w, &h, &depth, &type, &interlace, &compression, &filter) ||
        w != image_width || h != image_height) goto cleanup;
    bool transparent = png_get_valid(png, info, PNG_INFO_tRNS) != 0;
    bool indexed = type == PNG_COLOR_TYPE_PALETTE && !transparent;
    // Keep opaque palette indices and their original ImageIO color space.
    // Only a palette with transparency requires expansion to RGB and alpha.
    if (indexed && depth < 8) png_set_packing(png);
    if (type == PNG_COLOR_TYPE_PALETTE && transparent) png_set_palette_to_rgb(png);
    if (type == PNG_COLOR_TYPE_GRAY && depth < 8) png_set_expand_gray_1_2_4_to_8(png);
    if (transparent) png_set_tRNS_to_alpha(png);
#if __BYTE_ORDER__ == __ORDER_LITTLE_ENDIAN__
    if (depth == 16) png_set_swap(png);
#endif
    int passes = png_set_interlace_handling(png);
    png_read_update_info(png, info);
    depth = png_get_bit_depth(png, info);
    int channels = png_get_channels(png, info);
    if ((depth != 8 && depth != 16) || channels < 1 || channels > 4) goto cleanup;
    size_t pixel_bytes = (size_t)channels * (depth / 8);
    size_t row_bytes = (size_t)width * pixel_bytes;
    size_t raw_row_bytes = png_get_rowbytes(png, info);
    if (raw_row_bytes != (size_t)image_width * pixel_bytes) goto cleanup;
    input->row = calloc(1, raw_row_bytes);
    input->pixels = calloc(height, row_bytes);
    if (!input->row || !input->pixels) { input->status = BR_NO_MEMORY; goto cleanup; }
    for (int pass = 0; pass < passes; ++pass) {
        for (uint32_t row = 0; row < image_height; ++row) {
            if (cancelled && cancelled()) { input->status = BR_CANCELLED; goto cleanup; }
            bool selected = row >= y && row - y < height;
            uint8_t *span = input->row + (size_t)x * pixel_bytes;
            uint8_t *output = selected ? input->pixels + (size_t)(row - y) * row_bytes : NULL;
            // Adam7 merges a pass with earlier pixels. Preserve only the ROI;
            // the rest of the scanline is scratch, never retained across rows.
            if (output && passes > 1) memcpy(span, output, row_bytes);
            png_read_row(png, input->row, NULL);
            if (output) memcpy(output, span, row_bytes);
        }
    }
    png_read_end(png, NULL);
    out->pixels = input->pixels;
    input->pixels = NULL;
    out->row_bytes = row_bytes;
    out->width = width;
    out->height = height;
    out->bits_per_component = (uint16_t)depth;
    out->channels = (uint16_t)channels;
    out->model = indexed ? BR_INDEXED : channels <= 2 ? BR_GRAY : BR_RGB;
    out->alpha = channels == 2 || channels == 4 ? BR_STRAIGHT_ALPHA : BR_NO_ALPHA;
    input->status = BR_OK;
cleanup:
    png_destroy_read_struct(&png, &info, NULL);
    free(input->row);
    free(input->pixels);
    BRStatus status = input->status;
    free(input);
    return status;
}
