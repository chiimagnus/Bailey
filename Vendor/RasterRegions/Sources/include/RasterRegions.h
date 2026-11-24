#ifndef BAILEY_RASTER_REGIONS_H
#define BAILEY_RASTER_REGIONS_H
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>
typedef enum { BR_OK, BR_INVALID, BR_UNSUPPORTED, BR_CANCELLED, BR_NO_MEMORY } BRStatus;
typedef enum { BR_GRAY, BR_RGB, BR_CMYK, BR_INDEXED } BRColorModel;
typedef enum { BR_NO_ALPHA, BR_STRAIGHT_ALPHA, BR_ASSOCIATED_ALPHA } BRAlpha;
typedef struct {
    uint8_t *pixels;
    size_t row_bytes;
    uint32_t width, height;
    uint16_t bits_per_component, channels;
    BRColorModel model;
    BRAlpha alpha;
} BRRegion;
typedef bool (*BRCancel)(void);
BRStatus br_read_png_region(const uint8_t *bytes, size_t count,
    uint32_t image_width, uint32_t image_height,
    uint32_t x, uint32_t y, uint32_t width, uint32_t height,
    BRCancel cancelled, BRRegion *out);
BRStatus br_tiff_region_supported(const uint8_t *bytes, size_t count,
    uint32_t image_width, uint32_t image_height, bool native_inverts_gray);
BRStatus br_read_tiff_region(const uint8_t *bytes, size_t count,
    uint32_t image_width, uint32_t image_height,
    uint32_t x, uint32_t y, uint32_t width, uint32_t height,
    BRCancel cancelled, BRRegion *out);
#endif
