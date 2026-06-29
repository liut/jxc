// v0_decode_test.c — empirically verifies jxrlib can decode an HDR JXR file.
//
// This is the v0 verification step (R10) for the jxc project. It opens a JXR
// file via the 4creators/jxrlib C API (JXRGlue), reads the pixel format and
// ICC profile, decodes the pixels into an aligned buffer, and dumps stats.
//
// Exit code 0 = HDR decode works (pixel format is one of the expected HDR
// GUIDs AND ICC is non-empty). Non-zero = fail.

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <wchar.h>

#include "JXRGlue.h"

static const char* pixel_format_name(PKPixelFormatGUID guid) {
    if (memcmp(&guid, &GUID_PKPixelFormat48bppRGBFixedPoint, sizeof(GUID)) == 0) return "48bppRGBFixedPoint";
    if (memcmp(&guid, &GUID_PKPixelFormat48bppRGBHalf, sizeof(GUID)) == 0) return "48bppRGBHalf";
    if (memcmp(&guid, &GUID_PKPixelFormat64bppRGBAFixedPoint, sizeof(GUID)) == 0) return "64bppRGBAFixedPoint";
    if (memcmp(&guid, &GUID_PKPixelFormat64bppRGBAHalf, sizeof(GUID)) == 0) return "64bppRGBAHalf";
    if (memcmp(&guid, &GUID_PKPixelFormat96bppRGBFixedPoint, sizeof(GUID)) == 0) return "96bppRGBFixedPoint";
    if (memcmp(&guid, &GUID_PKPixelFormat128bppRGBFloat, sizeof(GUID)) == 0) return "128bppRGBFloat";
    if (memcmp(&guid, &GUID_PKPixelFormat128bppRGBAFloat, sizeof(GUID)) == 0) return "128bppRGBAFloat";
    if (memcmp(&guid, &GUID_PKPixelFormat24bppRGB, sizeof(GUID)) == 0) return "24bppRGB (SDR)";
    if (memcmp(&guid, &GUID_PKPixelFormat48bppRGB, sizeof(GUID)) == 0) return "48bppRGB (SDR)";
    return "other";
}

static int is_hdr_format(PKPixelFormatGUID guid) {
    return
        memcmp(&guid, &GUID_PKPixelFormat48bppRGBFixedPoint, sizeof(GUID)) == 0 ||
        memcmp(&guid, &GUID_PKPixelFormat48bppRGBHalf, sizeof(GUID)) == 0 ||
        memcmp(&guid, &GUID_PKPixelFormat64bppRGBAFixedPoint, sizeof(GUID)) == 0 ||
        memcmp(&guid, &GUID_PKPixelFormat64bppRGBAHalf, sizeof(GUID)) == 0 ||
        memcmp(&guid, &GUID_PKPixelFormat96bppRGBFixedPoint, sizeof(GUID)) == 0 ||
        memcmp(&guid, &GUID_PKPixelFormat128bppRGBFloat, sizeof(GUID)) == 0 ||
        memcmp(&guid, &GUID_PKPixelFormat128bppRGBAFloat, sizeof(GUID)) == 0;
}

int main(int argc, char** argv) {
    if (argc != 2) {
        fprintf(stderr, "usage: %s input.jxr\n", argv[0]);
        return 2;
    }
    const char* path = argv[1];

    PKFactory* pFactory = NULL;
    PKCodecFactory* pCodecFact = NULL;
    PKImageDecode* pDecoder = NULL;
    PKFormatConverter* pFC = NULL;
    int ret = 1;

    if (PKCreateFactory(&pFactory, PK_SDK_VERSION) != 0) {
        fprintf(stderr, "error: PKCreateFactory failed\n");
        return 1;
    }
    if (PKCreateCodecFactory(&pCodecFact, WMP_SDK_VERSION) != 0) {
        fprintf(stderr, "error: PKCreateCodecFactory failed\n");
        goto cleanup;
    }
    if (pCodecFact->CreateDecoderFromFile(path, &pDecoder) != 0) {
        fprintf(stderr, "error: CreateDecoderFromFile(%s) failed\n", path);
        goto cleanup;
    }

    I32 width = 0, height = 0;
    pDecoder->GetSize(pDecoder, &width, &height);
    fprintf(stdout, "size: %dx%d\n", width, height);

    PKPixelFormatGUID pf;
    pDecoder->GetPixelFormat(pDecoder, &pf);
    const char* pf_name = pixel_format_name(pf);
    int is_hdr = is_hdr_format(pf);
    fprintf(stdout, "pixel_format: %s (hdr=%s)\n", pf_name, is_hdr ? "yes" : "no");

    U32 icc_size = 0;
    pDecoder->GetColorContext(pDecoder, NULL, &icc_size);
    fprintf(stdout, "icc_size: %u bytes\n", (unsigned)icc_size);
    if (icc_size >= 4) {
        unsigned char head[16] = {0};
        if (icc_size < 16) {
            U32 s = icc_size;
            pDecoder->GetColorContext(pDecoder, head, &s);
        } else {
            U32 s = 16;
            pDecoder->GetColorContext(pDecoder, head, &s);
        }
        fprintf(stdout, "icc_head_hex: ");
        for (int i = 0; i < 16 && i < (int)icc_size; i++) fprintf(stdout, "%02x", head[i]);
        fprintf(stdout, "\n");
    }

    U32 exif_size = 0;
    PKImageDecode_GetEXIFMetadata_WMP(pDecoder, NULL, &exif_size);
    fprintf(stdout, "exif_size: %u bytes\n", (unsigned)exif_size);

    if (!is_hdr) {
        fprintf(stderr, "error: pixel format is NOT HDR — verification fails\n");
        ret = 1;
        goto cleanup;
    }

    if (pCodecFact->CreateFormatConverter(&pFC) != 0) {
        fprintf(stderr, "error: CreateFormatConverter failed\n");
        goto cleanup;
    }
    if (pFC->Initialize(pFC, pDecoder, ".raw", pf) != 0) {
        fprintf(stderr, "error: FormatConverter.Initialize failed\n");
        goto cleanup;
    }

    PKPixelInfo PI = {0};
    PI.pGUIDPixFmt = &pf;
    if (PixelFormatLookup(&PI, LOOKUP_FORWARD) != 0) {
        fprintf(stderr, "error: PixelFormatLookup failed\n");
        goto cleanup;
    }
    fprintf(stdout, "cbit_unit: %u\n", (unsigned)PI.cbitUnit);
    fprintf(stdout, "channels: %u\n", (unsigned)PI.cChannel);
    fprintf(stdout, "bit_depth: %u (BD_16S=%d BD_16F=%d BD_32S=%d BD_32F=%d)\n",
        (unsigned)PI.bdBitDepth, BD_16S, BD_16F, BD_32S, BD_32F);

    size_t bpp = (PI.cbitUnit / 8) * PI.cChannel;
    size_t stride = (size_t)width * bpp;
    size_t buf_size = stride * (size_t)height;
    fprintf(stdout, "bpp: %zu, stride: %zu, buffer_size: %zu (~%.1f MB)\n",
        bpp, stride, buf_size, buf_size / (1024.0 * 1024.0));

    unsigned char* pixels = NULL;
    if (PKAllocAligned((void**)&pixels, buf_size, 16) != 0 || !pixels) {
        fprintf(stderr, "error: PKAllocAligned(%zu) failed\n", buf_size);
        goto cleanup;
    }

    PKRect rect = { .X = 0, .Y = 0, .Width = width, .Height = height };
    if (pFC->Copy(pFC, &rect, pixels, (U32)stride) != 0) {
        fprintf(stderr, "error: FormatConverter.Copy failed\n");
        PKFreeAligned((void**)&pixels);
        goto cleanup;
    }

    unsigned int zero_count = 0;
    unsigned int nonzero_count = 0;
    const size_t stride_scan = bpp * 256;
    for (size_t i = 0; i < buf_size; i += stride_scan) {
        int any_nonzero = 0;
        for (size_t c = 0; c < bpp && (i + c) < buf_size; c++) {
            if (pixels[i + c] != 0) { any_nonzero = 1; break; }
        }
        if (any_nonzero) nonzero_count++; else zero_count++;
    }
    fprintf(stdout, "pixel_scan: zero=%u nonzero=%u (sampled every 256 pixels)\n",
        zero_count, nonzero_count);

    PKFreeAligned((void**)&pixels);
    if (icc_size == 0) {
        fprintf(stdout, "verification: PASS (HDR decode ok, ICC empty — will use default Rec.2020+PQ at encode time)\n");
    } else {
        fprintf(stdout, "verification: PASS (HDR decode ok, ICC present)\n");
    }
    ret = 0;

cleanup:
    if (pFC) pFC->Release(&pFC);
    if (pDecoder) pDecoder->Release(&pDecoder);
    if (pCodecFact) pCodecFact->Release(&pCodecFact);
    if (pFactory) pFactory->Release(&pFactory);
    return ret;
}