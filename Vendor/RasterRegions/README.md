# RasterRegions

Bounded original-pixel extraction for Bailey’s existing raster viewport. ImageIO owns
format detection, thumbnails, metadata and color spaces. The wrapper uses the same
versioned file bytes to read PNG scanlines or TIFF strips/tiles into the requested
pixel rectangle; it opens no files and retains no persistent cache.

## Fixed upstream sources

- [libpng 1.6.59](https://github.com/pnggroup/libpng/tree/v1.6.59), archive SHA-256
  `2540302a1844ad2b2b501977abecfa850f265f97b78f065a712ab4074a89f5b5`.
  Unmodified library C sources/headers, ARM NEON sources and the upstream
  `scripts/pnglibconf.h.prebuilt` as `pnglibconf.h`. [License](LICENSE-libpng).
- [LibTIFF 4.7.2](https://download.osgeo.org/libtiff/tiff-4.7.2.tar.gz), archive SHA-256
  `672bd7d10aee4606171afb864f3570b83340f6a33e2c186dc0512f7145ffdf6a`.
  Unmodified library C sources/headers for Unix, with upstream CMake-generated
  `tif_config.h`, `tiffconf.h` and `tiffvers.h`. [License](LICENSE-libtiff).
  Includes LZW compression code developed by the University of California, Berkeley.

Library sources exclude tests, tools, documentation and build scripts. Both licenses
are copied unchanged into the distributed application resources. External TIFF
codecs are disabled except SDK zlib; ordinary uncompressed, LZW, Deflate and PackBits
layouts use the regional path. TIFF tiles are independently compressed units and
are decoded one at a time (up to 32 MiB). Unsupported codecs/layouts, including
ImageIO-inconsistent grayscale inversion or separate-plane alpha, retain the
existing bounded ImageIO path.

The SwiftPM package builds directly from these fixed sources with the macOS SDK.
For TIFF configuration updates use upstream CMake on macOS with
`BUILD_SHARED_LIBS=OFF`, `tiff-tools/tests/contrib/docs/cxx/install/framework=OFF`,
`jpeg/old-jpeg/jpeg12/jbig/lerc/lzma/webp/zstd/libdeflate/pixarlog=OFF`, `zlib=ON`.
Update sources and licenses together; verify the release has no Homebrew dependency.
