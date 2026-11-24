#include "RasterRegions.h"
#include <tiffio.h>
#include <stdlib.h>
#include <string.h>
#include <stdio.h>

typedef struct {
    const uint8_t *bytes;
    size_t count, offset;
} TIFFMemory;

static tmsize_t read_bytes(thandle_t handle, void *dst, tmsize_t requested) {
    TIFFMemory *memory = (TIFFMemory *)handle;
    if (requested < 0) return -1;
    size_t count = (size_t)requested;
    if (count > memory->count - memory->offset) count = memory->count - memory->offset;
    memcpy(dst, memory->bytes + memory->offset, count);
    memory->offset += count;
    return (tmsize_t)count;
}
static tmsize_t no_write(thandle_t handle, void *src, tmsize_t count) {
    (void)handle; (void)src; (void)count; return -1;
}
static toff_t seek_bytes(thandle_t handle, toff_t offset, int whence) {
    TIFFMemory *memory = (TIFFMemory *)handle;
    if (whence == SEEK_SET) {
        if (offset > memory->count) return (toff_t)-1;
        memory->offset = (size_t)offset;
    } else {
        size_t base = whence == SEEK_CUR ? memory->offset : memory->count;
        if (whence != SEEK_CUR && whence != SEEK_END) return (toff_t)-1;
        int64_t delta = (int64_t)offset;
        if (delta < 0) {
            uint64_t magnitude = (uint64_t)(-(delta + 1)) + 1;
            if (magnitude > base) return (toff_t)-1;
            memory->offset = base - (size_t)magnitude;
        } else {
            if ((uint64_t)delta > memory->count - base) return (toff_t)-1;
            memory->offset = base + (size_t)delta;
        }
    }
    return memory->offset;
}
static int no_close(thandle_t handle) { (void)handle; return 0; }
static toff_t byte_count(thandle_t handle) { return ((TIFFMemory *)handle)->count; }
static int map_bytes(thandle_t handle, void **base, toff_t *size) {
    TIFFMemory *memory = (TIFFMemory *)handle;
    *base = (void *)memory->bytes; *size = memory->count; return 1;
}
static void no_unmap(thandle_t handle, void *base, toff_t size) {
    (void)handle; (void)base; (void)size;
}
static int quiet(TIFF *tif, void *user, const char *module, const char *format, va_list args) {
    (void)tif; (void)user; (void)module; (void)format; (void)args; return 1;
}
static TIFF *open_tiff(TIFFMemory *memory) {
    TIFFOpenOptions *options = TIFFOpenOptionsAlloc();
    if (!options) return NULL;
    TIFFOpenOptionsSetMaxSingleMemAlloc(options, 32 * 1024 * 1024);
    TIFFOpenOptionsSetMaxCumulatedMemAlloc(options, 64 * 1024 * 1024);
    TIFFOpenOptionsSetErrorHandlerExtR(options, quiet, NULL);
    TIFFOpenOptionsSetWarningHandlerExtR(options, quiet, NULL);
    TIFF *tiff = TIFFClientOpenExt("Bailey raster", "rB", (thandle_t)memory,
        read_bytes, no_write, seek_bytes, no_close, byte_count, map_bytes, no_unmap, options);
    TIFFOpenOptionsFree(options);
    return tiff;
}

typedef struct {
    uint32_t width, height;
    uint16_t bits, samples, planar, photo;
    uint16_t out_bits, out_channels;
    BRColorModel model;
    BRAlpha alpha;
    uint32_t tile_width, tile_height, rows_per_strip;
    size_t row_bytes, tile_bytes;
} TIFFLayout;

static BRStatus read_layout(TIFF *tif, uint32_t width, uint32_t height, TIFFLayout *layout) {
    if (!TIFFGetField(tif, TIFFTAG_IMAGEWIDTH, &layout->width) ||
        !TIFFGetField(tif, TIFFTAG_IMAGELENGTH, &layout->height) ||
        layout->width != width || layout->height != height ||
        !width || !height || (uint64_t)width * height > 32000000) return BR_INVALID;
    uint16_t format, compression, extra_count = 0, *extra = NULL;
    TIFFGetFieldDefaulted(tif, TIFFTAG_BITSPERSAMPLE, &layout->bits);
    TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLESPERPIXEL, &layout->samples);
    TIFFGetFieldDefaulted(tif, TIFFTAG_PLANARCONFIG, &layout->planar);
    TIFFGetFieldDefaulted(tif, TIFFTAG_PHOTOMETRIC, &layout->photo);
    TIFFGetFieldDefaulted(tif, TIFFTAG_SAMPLEFORMAT, &format);
    TIFFGetFieldDefaulted(tif, TIFFTAG_COMPRESSION, &compression);
    TIFFGetFieldDefaulted(tif, TIFFTAG_EXTRASAMPLES, &extra_count, &extra);
    if (!TIFFIsCODECConfigured(compression) || format != SAMPLEFORMAT_UINT ||
        (layout->planar != PLANARCONFIG_CONTIG && layout->planar != PLANARCONFIG_SEPARATE) ||
        (layout->bits != 1 && layout->bits != 2 && layout->bits != 4 && layout->bits != 8 && layout->bits != 16)) return BR_UNSUPPORTED;
    layout->out_bits = layout->bits < 8 ? 8 : layout->bits;
    uint16_t colors;
    switch (layout->photo) {
    case PHOTOMETRIC_MINISBLACK: case PHOTOMETRIC_MINISWHITE:
        layout->model = BR_GRAY; colors = 1; break;
    case PHOTOMETRIC_RGB:
        if (layout->bits < 8) return BR_UNSUPPORTED;
        layout->model = BR_RGB; colors = 3; break;
    case PHOTOMETRIC_SEPARATED: {
        uint16_t inkset;
        TIFFGetFieldDefaulted(tif, TIFFTAG_INKSET, &inkset);
        if (inkset != INKSET_CMYK || layout->bits < 8) return BR_UNSUPPORTED;
        layout->model = BR_CMYK; colors = 4; break;
    }
    case PHOTOMETRIC_PALETTE: {
        uint16_t *red, *green, *blue;
        if (layout->bits > 8) return BR_UNSUPPORTED;
        if (!TIFFGetField(tif, TIFFTAG_COLORMAP, &red, &green, &blue)) return BR_INVALID;
        layout->model = BR_INDEXED; layout->out_bits = 8; layout->out_channels = 1;
        colors = 1; break;
    }
    default: return BR_UNSUPPORTED;
    }
    if (layout->samples == colors && extra_count == 0) {
        layout->alpha = BR_NO_ALPHA;
    } else if (layout->samples == colors + 1 && extra_count == 1 &&
        (layout->model == BR_RGB || layout->model == BR_GRAY) && layout->photo != PHOTOMETRIC_PALETTE) {
        if (extra[0] == EXTRASAMPLE_ASSOCALPHA) layout->alpha = BR_ASSOCIATED_ALPHA;
        else if (extra[0] == EXTRASAMPLE_UNASSALPHA) layout->alpha = BR_STRAIGHT_ALPHA;
        else return BR_UNSUPPORTED;
    } else return BR_UNSUPPORTED;
    if (layout->photo != PHOTOMETRIC_PALETTE) layout->out_channels = layout->samples;
    uint16_t samples_per_row = layout->planar == PLANARCONFIG_CONTIG ? layout->samples : 1;
    uint64_t row_bytes;
    if (TIFFIsTiled(tif)) {
        if (!TIFFGetField(tif, TIFFTAG_TILEWIDTH, &layout->tile_width) ||
            !TIFFGetField(tif, TIFFTAG_TILELENGTH, &layout->tile_height) ||
            !layout->tile_width || !layout->tile_height) return BR_INVALID;
        // A TIFF tile is the smallest independently compressed unit. Do not
        // allocate a malicious tile whose pixel count exceeds the image budget.
        if ((uint64_t)layout->tile_width * layout->tile_height > 32000000) return BR_UNSUPPORTED;
        row_bytes = TIFFTileRowSize64(tif);
        uint64_t tile_bytes = TIFFTileSize64(tif);
        if (row_bytes != ((uint64_t)layout->tile_width * samples_per_row * layout->bits + 7) / 8 ||
            tile_bytes != row_bytes * layout->tile_height || tile_bytes > 32 * 1024 * 1024) return BR_UNSUPPORTED;
        layout->tile_bytes = (size_t)tile_bytes;
    } else {
        TIFFGetFieldDefaulted(tif, TIFFTAG_ROWSPERSTRIP, &layout->rows_per_strip);
        if (!layout->rows_per_strip) return BR_INVALID;
        row_bytes = TIFFScanlineSize64(tif);
        if (row_bytes != ((uint64_t)width * samples_per_row * layout->bits + 7) / 8) return BR_UNSUPPORTED;
    }
    layout->row_bytes = (size_t)row_bytes;
    return BR_OK;
}

BRStatus br_tiff_region_supported(const uint8_t *bytes, size_t count, uint32_t width, uint32_t height,
                                  bool native_inverts_gray) {
    TIFFMemory memory = {bytes, count, 0};
    TIFF *tif = open_tiff(&memory);
    if (!tif) return BR_UNSUPPORTED;
    TIFFLayout layout = {0};
    BRStatus status = read_layout(tif, width, height, &layout);
    // ImageIO is the thumbnail/color-space authority. It currently ignores
    // MINISWHITE on some sample widths and drops alpha in separate planes.
    // Keep those layouts on its existing bounded whole-image path rather
    // than changing brightness or transparency when the user zooms in.
    if (status == BR_OK &&
        ((layout.photo == PHOTOMETRIC_MINISWHITE && !native_inverts_gray) ||
         (layout.planar == PLANARCONFIG_SEPARATE && layout.alpha != BR_NO_ALPHA))) {
        status = BR_UNSUPPORTED;
    }
    TIFFClose(tif);
    return status;
}

static uint16_t sample_at(const uint8_t *row, size_t index, uint16_t bits) {
    if (bits == 8) return row[index];
    if (bits == 16) { uint16_t value; memcpy(&value, row + index * 2, 2); return value; }
    size_t bit = index * bits;
    return (row[bit / 8] >> (8 - bits - bit % 8)) & ((1U << bits) - 1);
}
static void store_sample(uint8_t *row, size_t index, uint16_t bits, uint16_t value) {
    if (bits == 8) row[index] = (uint8_t)value;
    else memcpy(row + index * 2, &value, 2);
}
static void copy_span(const TIFFLayout *layout, const uint8_t *row, uint32_t source_x,
                      uint8_t *out, uint32_t count, uint16_t plane) {
    bool contiguous = layout->planar == PLANARCONFIG_CONTIG;
    if (contiguous && layout->bits == layout->out_bits && layout->photo != PHOTOMETRIC_PALETTE) {
        size_t stride = (size_t)layout->samples * (layout->bits / 8);
        memcpy(out, row + (size_t)source_x * stride, (size_t)count * stride);
        return;
    }
    for (uint32_t x = 0; x < count; ++x) {
        size_t source = (size_t)(source_x + x) * (contiguous ? layout->samples : 1);
        size_t dest = (size_t)x * layout->out_channels;
        if (layout->photo == PHOTOMETRIC_PALETTE) {
            out[dest] = (uint8_t)sample_at(row, source, layout->bits);
        } else {
            for (uint16_t sample = 0; sample < (contiguous ? layout->samples : 1); ++sample) {
                uint16_t value = sample_at(row, source + sample, layout->bits);
                if (layout->bits < 8) value = (uint16_t)(value * 255 / ((1U << layout->bits) - 1));
                store_sample(out, dest + (contiguous ? sample : plane), layout->out_bits, value);
            }
        }
    }
}

BRStatus br_read_tiff_region(const uint8_t *bytes, size_t count, uint32_t image_width, uint32_t image_height,
    uint32_t x, uint32_t y, uint32_t width, uint32_t height, BRCancel cancelled, BRRegion *out) {
    *out = (BRRegion){0};
    if (!width || !height || x >= image_width || y >= image_height ||
        width > image_width - x || height > image_height - y) return BR_INVALID;
    TIFFMemory memory = {bytes, count, 0};
    TIFF *tif = open_tiff(&memory);
    if (!tif) return BR_INVALID;
    TIFFLayout layout = {0};
    BRStatus status = read_layout(tif, image_width, image_height, &layout);
    uint8_t *scratch = NULL, *pixels = NULL;
    if (status != BR_OK) goto cleanup;
    size_t pixel_bytes = (size_t)layout.out_channels * (layout.out_bits / 8);
    size_t row_bytes = (size_t)width * pixel_bytes;
    scratch = malloc(layout.tile_bytes ? layout.tile_bytes : layout.row_bytes);
    pixels = malloc((size_t)height * row_bytes);
    if (!scratch || !pixels) { status = BR_NO_MEMORY; goto cleanup; }
    uint16_t planes = layout.planar == PLANARCONFIG_SEPARATE ? layout.samples : 1;
    status = BR_INVALID;
    for (uint16_t plane = 0; plane < planes; ++plane) {
        if (layout.tile_bytes) {
            uint32_t first_y = y / layout.tile_height * layout.tile_height;
            uint32_t first_x = x / layout.tile_width * layout.tile_width;
            for (uint32_t ty = first_y; ty < y + height; ty += layout.tile_height) {
                for (uint32_t tx = first_x; tx < x + width; tx += layout.tile_width) {
                    if (cancelled && cancelled()) { status = BR_CANCELLED; goto cleanup; }
                    if (TIFFReadTile(tif, scratch, tx, ty, 0, plane) != (tmsize_t)layout.tile_bytes) goto cleanup;
                    uint32_t left = tx > x ? tx : x;
                    uint32_t top = ty > y ? ty : y;
                    uint32_t right = tx + layout.tile_width < x + width ? tx + layout.tile_width : x + width;
                    uint32_t bottom = ty + layout.tile_height < y + height ? ty + layout.tile_height : y + height;
                    for (uint32_t row = top; row < bottom; ++row) {
                        if (cancelled && cancelled()) { status = BR_CANCELLED; goto cleanup; }
                        copy_span(&layout, scratch + (size_t)(row - ty) * layout.row_bytes, left - tx,
                            pixels + (size_t)(row - y) * row_bytes + (size_t)(left - x) * pixel_bytes,
                            right - left, plane);
                    }
                }
            }
        } else {
            // Compressed strips may not support seeking within a strip. Decode
            // sequentially from the strip containing the requested first row.
            uint32_t first = y / layout.rows_per_strip * layout.rows_per_strip;
            for (uint32_t row = first; row < y + height; ++row) {
                if (cancelled && cancelled()) { status = BR_CANCELLED; goto cleanup; }
                if (TIFFReadScanline(tif, scratch, row, plane) != 1) goto cleanup;
                if (row >= y) copy_span(&layout, scratch, x, pixels + (size_t)(row - y) * row_bytes, width, plane);
            }
        }
    }
    *out = (BRRegion){pixels, row_bytes, width, height, layout.out_bits, layout.out_channels, layout.model, layout.alpha};
    pixels = NULL;
    status = BR_OK;
cleanup:
    free(scratch);
    free(pixels);
    TIFFClose(tif);
    return status;
}
