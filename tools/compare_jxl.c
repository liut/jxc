// tools/compare_jxl.c — decode two JXL files to UINT8 (what a viewer shows
// on an sRGB display by default) and compare them pixel-by-pixel.
//
// For HDR files, FLOAT pixels are clipped to [0,255] by the decoder, which
// mirrors what a non-color-managed viewer displays.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>

#include "jxl/decode.h"
#include "jxl/codestream_header.h"
#include "jxl/color_encoding.h"
#include "jxl/types.h"

typedef struct {
    uint32_t width;
    uint32_t height;
    uint8_t* pixels; // size = width*height*3
    char transfer[32];
    char primaries[32];
    uint32_t bits;
} ImageData;

static int load_jxl_uint8(const char* path, ImageData* img) {
    FILE* f = fopen(path, "rb");
    if (!f) { fprintf(stderr, "fopen %s failed\n", path); return 1; }
    fseek(f, 0, SEEK_END);
    long size = ftell(f);
    fseek(f, 0, SEEK_SET);
    uint8_t* data = malloc(size);
    fread(data, 1, size, f);
    fclose(f);

    JxlDecoder* dec = JxlDecoderCreate(NULL);
    JxlDecoderSubscribeEvents(dec, JXL_DEC_BASIC_INFO | JXL_DEC_FULL_IMAGE);

    JxlPixelFormat pix_fmt = { 3, JXL_TYPE_UINT8, JXL_NATIVE_ENDIAN, 0 };
    int got_full = 0;
    uint8_t* pixels = NULL;
    uint32_t width = 0, height = 0;

    JxlDecoderSetInput(dec, data, size);
    JxlDecoderCloseInput(dec);

    while (!got_full) {
        JxlDecoderStatus status = JxlDecoderProcessInput(dec);
        if (status == JXL_DEC_ERROR) { fprintf(stderr, "%s: decoder error\n", path); return 1; }
        if (status == JXL_DEC_NEED_MORE_INPUT) { fprintf(stderr, "%s: truncated\n", path); return 1; }
        if (status == JXL_DEC_BASIC_INFO) {
            JxlBasicInfo info;
            JxlDecoderGetBasicInfo(dec, &info);
            width = info.xsize;
            height = info.ysize;
            size_t buf_size;
            JxlDecoderImageOutBufferSize(dec, &pix_fmt, &buf_size);
            pixels = malloc(buf_size);
            JxlDecoderSetImageOutBuffer(dec, &pix_fmt, pixels, buf_size);

            JxlColorEncoding src_enc;
            JxlDecoderGetColorAsEncodedProfile(dec, JXL_COLOR_PROFILE_TARGET_DATA, &src_enc);
            const char* tf_str = "?";
            switch (src_enc.transfer_function) {
                case JXL_TRANSFER_FUNCTION_LINEAR: tf_str = "linear"; break;
                case JXL_TRANSFER_FUNCTION_SRGB:    tf_str = "srgb"; break;
                case JXL_TRANSFER_FUNCTION_PQ:      tf_str = "pq"; break;
                case JXL_TRANSFER_FUNCTION_HLG:     tf_str = "hlg"; break;
                default: tf_str = "other"; break;
            }
            snprintf(img->transfer, sizeof(img->transfer), "%s", tf_str);
            const char* pr_str = "?";
            switch (src_enc.primaries) {
                case JXL_PRIMARIES_SRGB:        pr_str = "srgb"; break;
                case JXL_PRIMARIES_2100:        pr_str = "2100"; break;
                case JXL_PRIMARIES_P3:          pr_str = "p3"; break;
                default: pr_str = "other"; break;
            }
            snprintf(img->primaries, sizeof(img->primaries), "%s", pr_str);
            img->bits = info.bits_per_sample;
        }
        if (status == JXL_DEC_FULL_IMAGE) got_full = 1;
        if (status == JXL_DEC_SUCCESS) break;
    }

    if (!got_full) { fprintf(stderr, "%s: didn't get full image\n", path); return 1; }
    img->width = width;
    img->height = height;
    img->pixels = pixels;

    JxlDecoderDestroy(dec);
    free(data);
    return 0;
}

static void print_spot(const char* label, const ImageData* img, int x, int y) {
    if ((uint32_t)y >= img->height || (uint32_t)x >= img->width) return;
    uint8_t r = img->pixels[(y * img->width + x) * 3 + 0];
    uint8_t g = img->pixels[(y * img->width + x) * 3 + 1];
    uint8_t b = img->pixels[(y * img->width + x) * 3 + 2];
    printf("  %s [%4d,%4d]: R=%3d G=%3d B=%3d\n", label, x, y, r, g, b);
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <file1.jxl> <file2.jxl>\n", argv[0]);
        return 2;
    }
    ImageData a = {0}, b = {0};
    if (load_jxl_uint8(argv[1], &a)) return 1;
    if (load_jxl_uint8(argv[2], &b)) return 1;

    printf("=== %s ===\n", argv[1]);
    printf("  file: %s %s, %u-bit, %ux%u\n", a.transfer, a.primaries, a.bits, a.width, a.height);
    printf("=== %s ===\n", argv[2]);
    printf("  file: %s %s, %u-bit, %ux%u\n", b.transfer, b.primaries, b.bits, b.width, b.height);

    printf("\n--- Spot pixels (UINT8, what the decoder gives) ---\n");
    int xs[] = {100, 800, 1600, 2400, 3200};
    int ys[] = {100, 540, 1080, 1620, 2050};
    for (int j = 0; j < 5; j++) {
        for (int i = 0; i < 5; i++) {
            printf("[%d,%d]:\n", xs[i], ys[j]);
            print_spot("A", &a, xs[i], ys[j]);
            print_spot("B", &b, xs[i], ys[j]);
        }
    }

    if (a.width != b.width || a.height != b.height) {
        printf("\nsize mismatch — skipping diff\n");
        return 0;
    }

    size_t N = a.width * a.height;
    long long sum_abs_r = 0, sum_abs_g = 0, sum_abs_b = 0;
    int max_abs = 0;
    int count = 0;
    int n_a_bright = 0, n_b_bright = 0;
    for (size_t i = 0; i < N; i++) {
        int dr = (int)a.pixels[i*3+0] - (int)b.pixels[i*3+0];
        int dg = (int)a.pixels[i*3+1] - (int)b.pixels[i*3+1];
        int db = (int)a.pixels[i*3+2] - (int)b.pixels[i*3+2];
        sum_abs_r += abs(dr); sum_abs_g += abs(dg); sum_abs_b += abs(db);
        int m = abs(dr); if (abs(dg) > m) m = abs(dg); if (abs(db) > m) m = abs(db);
        if (m > max_abs) max_abs = m;
        count++;
        if (a.pixels[i*3+0] > 250 && a.pixels[i*3+1] > 250 && a.pixels[i*3+2] > 250) n_a_bright++;
        if (b.pixels[i*3+0] > 250 && b.pixels[i*3+1] > 250 && b.pixels[i*3+2] > 250) n_b_bright++;
    }
    printf("\n--- Diff stats ---\n");
    printf("mean abs diff: R=%.1f G=%.1f B=%.1f\n", (double)sum_abs_r/count, (double)sum_abs_g/count, (double)sum_abs_b/count);
    printf("max abs diff: %d\n", max_abs);
    printf("near-white pixels (R>250 && G>250 && B>250):\n");
    printf("  A: %d / %d (%.1f%%)\n", n_a_bright, count, 100.0*n_a_bright/count);
    printf("  B: %d / %d (%.1f%%)\n", n_b_bright, count, 100.0*n_b_bright/count);

    return 0;
}
