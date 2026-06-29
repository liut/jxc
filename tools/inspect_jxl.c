// tools/inspect_jxl.c — decode a JXL file and print pixel stats, to verify
// whether jxc's output is correctly viewable.
//
// Uses libjxl 0.11 decoder API (SetInput/ProcessInput + SetImageOutBuffer).

#include <stdio.h>
#include <stdlib.h>
#include <string.h>

#include "jxl/decode.h"
#include "jxl/codestream_header.h"
#include "jxl/color_encoding.h"
#include "jxl/types.h"

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s input.jxl\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];

    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "fopen failed\n"); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* data = malloc(size);
    fread(data, 1, size, f);
    fclose(f);

    JxlDecoder* dec = JxlDecoderCreate(NULL);
    if (!dec) { fprintf(stderr, "JxlDecoderCreate failed\n"); return 1; }

    if (JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE) != JXL_DEC_SUCCESS) {
        fprintf(stderr, "subscribe failed\n");
        return 1;
    }

    JxlBasicInfo info;
    // Use UINT8 output so we see what's literally in the file (no inverse
    // gamma applied by the decoder). For SDR-mode JXLs this is the raw
    // sRGB-encoded 8-bit value.
    JxlPixelFormat pix_fmt = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };
    int got_full = 0;
    uint8_t* pixels = NULL;

    JxlDecoderSetInput(dec, data, size);
    JxlDecoderCloseInput(dec);

    while (!got_full) {
        JxlDecoderStatus status = JxlDecoderProcessInput(dec);
        if (status == JXL_DEC_ERROR) {
            fprintf(stderr, "decoder error\n");
            return 1;
        }
        if (status == JXL_DEC_BASIC_INFO) {
            JxlDecoderGetBasicInfo(dec, &info);
            fprintf(stdout, "size: %ux%u, bits: %u+%u, channels: %u+%u, container: %d, profile: %d\n",
                info.xsize, info.ysize, info.bits_per_sample, info.exponent_bits_per_sample,
                info.num_color_channels, info.num_extra_channels,
                (int)info.have_container, (int)info.uses_original_profile);

            size_t buf_size;
            if (JxlDecoderImageOutBufferSize(dec, &pix_fmt, &buf_size) != JXL_DEC_SUCCESS) {
                fprintf(stderr, "out buf size failed\n");
                return 1;
            }
            fprintf(stdout, "buf_size: %zu (%.1f MB)\n", buf_size, buf_size / (1024.0*1024.0));
            pixels = malloc(buf_size);
            if (JxlDecoderSetImageOutBuffer(dec, &pix_fmt, pixels, buf_size) != JXL_DEC_SUCCESS) {
                fprintf(stderr, "set out buf failed\n");
                return 1;
            }
        }
        if (status == JXL_DEC_NEED_MORE_INPUT) {
            fprintf(stderr, "need more input — truncated?\n");
            return 1;
        }
        if (status == JXL_DEC_FULL_IMAGE) {
            got_full = 1;
        }
        if (status == JXL_DEC_SUCCESS) break;
    }

    if (!got_full) {
        fprintf(stderr, "didn't get full image event\n");
        return 1;
    }

    // Print pixel stats (8-bit values, 0-255)
    size_t N = info.xsize * info.ysize;
    int rmin = 256, rmax = -1, gmin = 256, gmax = -1, bmin = 256, bmax = -1;
    for (size_t i = 0; i < N; i += 100) {
        int r = pixels[i*3 + 0];
        int g = pixels[i*3 + 1];
        int b = pixels[i*3 + 2];
        if (r < rmin) rmin = r; if (r > rmax) rmax = r;
        if (g < gmin) gmin = g; if (g > gmax) gmax = g;
        if (b < bmin) bmin = b; if (b > bmax) bmax = b;
    }
    fprintf(stdout, "Decoded 8-bit RGB stats: R=[%d, %d] G=[%d, %d] B=[%d, %d]\n", rmin, rmax, gmin, gmax, bmin, bmax);
    fprintf(stdout, "Spot pixels (row 0):\n");
    for (int col = 0; col < 5; col++) {
        int x = col * 800;
        if (x >= info.xsize) break;
        uint8_t* px = &pixels[x * 3];
        fprintf(stdout, "  [%4d,0] R=%3d G=%3d B=%3d\n", x, px[0], px[1], px[2]);
    }
    fprintf(stdout, "Spot pixels (row 1080):\n");
    for (int col = 0; col < 5; col++) {
        int x = col * 800;
        if (x >= info.xsize) break;
        uint8_t* px = &pixels[(1080 * info.xsize + x) * 3];
        fprintf(stdout, "  [%4d,1080] R=%3d G=%3d B=%3d\n", x, px[0], px[1], px[2]);
    }

    free(pixels);
    JxlDecoderDestroy(dec);
    free(data);
    return 0;
}