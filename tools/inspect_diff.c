// tools/inspect_diff.c — detailed pixel-by-pixel comparison of two JXL files.
//
// Decodes both with FLOAT output, reports per-channel histograms, mean abs
// diff in luminance bins, and worst offending regions.

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
    float* pixels; // size = width*height*3, in each file's native color space
    char transfer[32];
    char primaries[32];
    uint32_t bits;
} ImageData;

static int load_jxl(const char* path, ImageData* img) {
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

    JxlPixelFormat pix_fmt = { 3, JXL_TYPE_FLOAT, JXL_NATIVE_ENDIAN, 0 };
    int got_full = 0;
    float* pixels = NULL;
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

static float srgb_encode(float lin) {
    if (lin < 0.0) lin = 0.0;
    if (lin > 1.0) lin = 1.0;
    if (lin <= 0.0031308) return 12.92f * lin;
    return 1.055f * powf(lin, 1.0f/2.4f) - 0.055f;
}

int main(int argc, char** argv) {
    if (argc != 3) {
        fprintf(stderr, "usage: %s <file1.jxl> <file2.jxl>\n", argv[0]);
        return 2;
    }
    ImageData a = {0}, b = {0};
    if (load_jxl(argv[1], &a)) return 1;
    if (load_jxl(argv[2], &b)) return 1;

    printf("A (%s): %s/%s, %u-bit, %ux%u\n", argv[1], a.transfer, a.primaries, a.bits, a.width, a.height);
    printf("B (%s): %s/%s, %u-bit, %ux%u\n", argv[2], b.transfer, b.primaries, b.bits, b.width, b.height);

    if (a.width != b.width || a.height != b.height) {
        printf("size mismatch\n");
        return 1;
    }

    size_t N = a.width * a.height;

    // Histogram: linear luminance Y = 0.2126R + 0.7152G + 0.0722B
    int histA[16] = {0}, histB[16] = {0};
    int histDiff[16] = {0}; // count of pixels where |YA - YB| >> 0.05
    long long sumA_r = 0, sumA_g = 0, sumA_b = 0;
    long long sumB_r = 0, sumB_g = 0, sumB_b = 0;
    double max_abs_err = 0;
    int max_w_x = 0, max_w_y = 0;
    int count = 0;
    long long sum_diff_lum = 0;
    // For sRGB-encoded comparison
    long long sumA_y = 0, sumB_y = 0;
    long long sum_diff_srgb_y = 0;
    long long sum_diff_srgb_r = 0, sum_diff_srgb_g = 0, sum_diff_srgb_b = 0;

    for (size_t i = 0; i < N; i++) {
        float ar = a.pixels[i*3 + 0], ag = a.pixels[i*3 + 1], ab = a.pixels[i*3 + 2];
        float br = b.pixels[i*3 + 0], bg = b.pixels[i*3 + 1], bb = b.pixels[i*3 + 2];

        // Sum in linear space (approximation)
        sumA_r += ar*1000; sumA_g += ag*1000; sumA_b += ab*1000;
        sumB_r += br*1000; sumB_g += bg*1000; sumB_b += bb*1000;

        // Luminance
        float YA = 0.2126f*ar + 0.7152f*ag + 0.0722f*ab;
        float YB = 0.2126f*br + 0.7152f*bg + 0.0722f*bb;

        // Histogram (in linear)
        int binA = (int)(fminf(fmaxf(YA, 0), 1.0) * 16);
        int binB = (int)(fminf(fmaxf(YB, 0), 1.0) * 16);
        if (binA >= 16) binA = 15; if (binB >= 16) binB = 15;
        histA[binA]++;
        histB[binB]++;
        if (fabsf(YA - YB) > 0.05) {
            int binDA = binA;
            histDiff[binDA]++;
        }
        sum_diff_lum += (YA - YB) * 1000;

        // sRGB-encoded comparison
        float Aar = srgb_encode(ar), Aag = srgb_encode(ag), Aab = srgb_encode(ab);
        float Bbr = srgb_encode(br), Bbg = srgb_encode(bg), Bbb = srgb_encode(bb);
        sumA_y += Aar*100; sumB_y += Bbr*100;
        sum_diff_srgb_r += fabsf(Aar - Bbr) * 1000;
        sum_diff_srgb_g += fabsf(Aag - Bbg) * 1000;
        sum_diff_srgb_b += fabsf(Aab - Bbb) * 1000;
        sum_diff_srgb_y += fabsf(0.2126f*Aar + 0.7152f*Aag + 0.0722f*Aab
                               - 0.2126f*Bbr - 0.7152f*Bbg - 0.0722f*Bbb) * 1000;

        double err = fabs(YA - YB);
        if (err > max_abs_err) {
            max_abs_err = err;
            max_w_x = i % a.width;
            max_w_y = i / a.width;
        }
        count++;
    }

    printf("\n--- Linear mean (scaled by 1000) ---\n");
    printf("A: R=%.1f G=%.1f B=%.1f\n", (double)sumA_r/count, (double)sumA_g/count, (double)sumA_b/count);
    printf("B: R=%.1f G=%.1f B=%.1f\n", (double)sumB_r/count, (double)sumB_g/count, (double)sumB_b/count);
    printf("diff (B-A): R=%.1f G=%.1f B=%.1f\n", (double)(sumB_r-sumA_r)/count, (double)(sumB_g-sumA_g)/count, (double)(sumB_b-sumA_b)/count);

    printf("\n--- sRGB-encoded mean abs diff (0-1000) ---\n");
    printf("R=%.2f  G=%.2f  B=%.2f  Y=%.2f\n", (double)sum_diff_srgb_r/count, (double)sum_diff_srgb_g/count, (double)sum_diff_srgb_b/count, (double)sum_diff_srgb_y/count);

    printf("\n--- Luminance histogram (16 bins, linear [0,1]) ---\n");
    printf("bin  |    A    |    B    |  diff>0.05 (A bin)\n");
    for (int i = 0; i < 16; i++) {
        printf("%4d  | %6d  | %6d  | %6d\n", i, histA[i], histB[i], histDiff[i]);
    }

    printf("\nMax luminance diff: %.3f at (%d, %d)\n", max_abs_err, max_w_x, max_w_y);
    return 0;
}
