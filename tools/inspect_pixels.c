// tools/inspect_pixels.c — quick peek at raw pixel values from jxrlib decode
// to understand what transfer function / color encoding the source uses.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdint.h>
#include <wchar.h>

#include "JXRGlue.h"

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s input.jxr\n", argv[0]);
        return 2;
    }

    PKFactory* pFactory = NULL;
    PKCodecFactory* pCodecFact = NULL;
    PKImageDecode* pDecoder = NULL;
    PKFormatConverter* pFC = NULL;
    int ret = 1;

    if (PKCreateFactory(&pFactory, PK_SDK_VERSION) != 0) return 1;
    if (PKCreateCodecFactory(&pCodecFact, WMP_SDK_VERSION) != 0) goto cleanup;
    if (pCodecFact->CreateDecoderFromFile(argv[1], &pDecoder) != 0) goto cleanup;

    I32 w = 0, h = 0;
    pDecoder->GetSize(pDecoder, &w, &h);
    fprintf(stdout, "size: %dx%d\n", w, h);

    PKPixelFormatGUID pf;
    pDecoder->GetPixelFormat(pDecoder, &pf);
    PKPixelInfo PI = { .pGUIDPixFmt = &pf };
    PixelFormatLookup(&PI, LOOKUP_FORWARD);

    U32 icc_size = 0;
    pDecoder->GetColorContext(pDecoder, NULL, &icc_size);
    fprintf(stdout, "icc_size: %u\n", (unsigned)icc_size);

    size_t bpp = PI.cbitUnit / 8;  // cbitUnit is bits per pixel (all channels)
    size_t stride = w * bpp;
    size_t buf_size = stride * h;
    unsigned char* pixels = NULL;
    if (PKAllocAligned((void**)&pixels, buf_size, 16) != 0) goto cleanup;

    if (pCodecFact->CreateFormatConverter(&pFC) != 0) goto cleanup;
    if (pFC->Initialize(pFC, pDecoder, ".raw", pf) != 0) goto cleanup;

    PKRect rect = { 0, 0, w, h };
    if (pFC->Copy(pFC, &rect, pixels, (U32)stride) != 0) goto cleanup;

    fprintf(stdout, "bpp: %zu, stride: %zu, channels: %u, cbit_unit: %u\n", bpp, stride, PI.cChannel, PI.cbitUnit);

    // For 32bppRGBAFloat: 4 channels of float32. Print pixel stats.
    if (bpp == 16 && PI.cChannel == 4) {
        float* p = (float*)pixels;
        size_t N = w * h;
        float rmin = 1e30f, rmax = -1e30f;
        float gmin = 1e30f, gmax = -1e30f;
        float bmin = 1e30f, bmax = -1e30f;
        float amin = 1e30f, amax = -1e30f;
        for (size_t i = 0; i < N; i += 100) {
            float r = p[i*4 + 0];
            float g = p[i*4 + 1];
            float b = p[i*4 + 2];
            float a = p[i*4 + 3];
            if (r < rmin) rmin = r; if (r > rmax) rmax = r;
            if (g < gmin) gmin = g; if (g > gmax) gmax = g;
            if (b < bmin) bmin = b; if (b > bmax) bmax = b;
            if (a < amin) amin = a; if (a > amax) amax = a;
        }
        fprintf(stdout, "R: [%.4f, %.4f]\n", rmin, rmax);
        fprintf(stdout, "G: [%.4f, %.4f]\n", gmin, gmax);
        fprintf(stdout, "B: [%.4f, %.4f]\n", bmin, bmax);
        fprintf(stdout, "A: [%.4f, %.4f]\n", amin, amax);

        fprintf(stdout, "\nSpot pixels (row 0, every 800 cols):\n");
        for (int col = 0; col < 5; col++) {
            int x = col * 800;
            float* px = &p[x * 4];
            fprintf(stdout, "  [%4d,0] R=%.6f G=%.6f B=%.6f A=%.6f\n", x, px[0], px[1], px[2], px[3]);
        }
        fprintf(stdout, "\nSpot pixels (row 1080, every 800 cols):\n");
        for (int col = 0; col < 5; col++) {
            int x = col * 800;
            float* px = &p[(1080 * w + x) * 4];
            fprintf(stdout, "  [%4d,1080] R=%.6f G=%.6f B=%.6f A=%.6f\n", x, px[0], px[1], px[2], px[3]);
        }
    } else if (bpp == 8 && PI.cChannel == 4) {
        unsigned char* p = pixels;
        size_t N = w * h;
        unsigned rmin = 255, rmax = 0, gmin = 255, gmax = 0, bmin = 255, bmax = 0, amin = 255, amax = 0;
        for (size_t i = 0; i < N; i += 100) {
            unsigned r = p[i*4 + 0], g = p[i*4 + 1], b = p[i*4 + 2], a = p[i*4 + 3];
            if (r < rmin) rmin = r; if (r > rmax) rmax = r;
            if (g < gmin) gmin = g; if (g > gmax) gmax = g;
            if (b < bmin) bmin = b; if (b > bmax) bmax = b;
            if (a < amin) amin = a; if (a > amax) amax = a;
        }
        fprintf(stdout, "R: [%u, %u]\n", rmin, rmax);
        fprintf(stdout, "G: [%u, %u]\n", gmin, gmax);
        fprintf(stdout, "B: [%u, %u]\n", bmin, bmax);
        fprintf(stdout, "A: [%u, %u]\n", amin, amax);
    }

    PKFreeAligned((void**)&pixels);
    ret = 0;
cleanup:
    if (pFC) pFC->Release(&pFC);
    if (pDecoder) pDecoder->Release(&pDecoder);
    if (pCodecFact) pCodecFact->Release(&pCodecFact);
    if (pFactory) pFactory->Release(&pFactory);
    return ret;
}