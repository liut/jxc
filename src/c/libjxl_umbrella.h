// libjxl_umbrella.h — single translation unit for `addTranslateC` in build.zig.
//
// Pulls in the libjxl public C API headers needed by jxc. Anything not
// reachable from this umbrella is intentionally not exposed to Zig.
//
// HDR encoder workflow uses:
//   - JxlEncoderCreate / JxlEncoderDestroy / JxlEncoderProcessOutput
//   - JxlEncoderSetBasicInfo (sets bits_per_sample, exponent_bits_per_sample,
//     num_color_channels, num_extra_channels, alpha_bits, uses_original_profile)
//   - JxlEncoderSetICCProfile (when source JXR has ICC)
//   - JxlEncoderSetColorEncoding + JxlColorEncoding (fallback when no ICC)
//   - JxlEncoderFrameSettingsCreate / JxlEncoderSetFrameLossless
//   - JxlEncoderAddImageFrame (with JxlPixelFormat matching source layout)
//   - JxlEncoderCloseInput
//   - JxlEncoderUseContainer / JxlEncoderUseBoxes / JxlEncoderAddBox (for EXIF)

#ifndef JXC_LIBJXL_UMBRELLA_H_
#define JXC_LIBJXL_UMBRELLA_H_

#include <jxl/encode.h>
#include <jxl/codestream_header.h>
#include <jxl/color_encoding.h>
#include <jxl/types.h>
#include <jxl/parallel_runner.h>

#endif // JXC_LIBJXL_UMBRELLA_H_