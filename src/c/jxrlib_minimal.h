// jxrlib_minimal.h — minimal jxrlib bindings for translate-c on Windows.
//
// jxrlib's full headers drag in <wchar.h> which (in Strawberry's UCRT
// distribution) unconditionally declares wcscat_s / wcscpy_s / etc.
// `translate-c` emits wrapper structs for every declared symbol and Zig
// 0.16 errors on the unused ones. Skipping the full headers entirely
// avoids the whole class of problems.
//
// The struct field declarations here MUST match jxrlib's JXRGlue.h
// exactly: Zig computes field offsets from the declarations and jxrlib
// the actual layout from libjxrglue.a. Mismatched fields = reading the
// wrong function pointer = UB. Field ORDER copied verbatim from
// JXRGlue.h; field types use plain C stdint where jxrlib uses its
// own U8/U32/Bool (translationally equivalent).

#ifndef JXC_JXRLIB_MINIMAL_H_
#define JXC_JXRLIB_MINIMAL_H_

#include <stddef.h>
#include <stdint.h>

typedef int32_t ERR;

#define WMP_SDK_VERSION 0x0101
#define PK_SDK_VERSION  0x0101

typedef struct tagWMPStream        WMPStream;
typedef struct tagPKStream        PKStream;
typedef struct tagPKFactory        PKFactory;
typedef struct tagPKCodecFactory   PKCodecFactory;
typedef struct tagPKImageDecode    PKImageDecode;
typedef struct tagPKFormatConverter PKFormatConverter;
typedef struct tagPKImageEncode    PKImageEncode;
typedef struct tagWMPGUIDHelper    WMPGUIDHelper;

/* Field-order copies must mirror JXRGlue.h:330, :351, :495, :589. */

typedef struct tagPKFactory {
    ERR (*CreateStream)(PKStream**);
    ERR (*CreateStreamFromFilename)(WMPStream**, const char*, const char*);
    ERR (*CreateStreamFromMemory)(WMPStream**, void*, size_t);
    ERR (*Release)(PKFactory**);
} PKFactory;

typedef struct tagPKCodecFactory {
    ERR (*CreateCodec)(const uint8_t*, void**);
    ERR (*CreateDecoderFromFile)(const char*, PKImageDecode**);
    ERR (*CreateFormatConverter)(PKFormatConverter**);
    ERR (*Release)(PKCodecFactory**);
} PKCodecFactory;

typedef struct tagPKImageDecode {
    ERR (*Initialize)(PKImageDecode*, WMPStream*);
    ERR (*GetPixelFormat)(PKImageDecode*, uint8_t* /* GUID[16] */);
    ERR (*GetSize)(PKImageDecode*, int32_t*, int32_t*);
    ERR (*GetResolution)(PKImageDecode*, float*, float*);
    ERR (*GetColorContext)(PKImageDecode*, uint8_t*, uint32_t*);
    ERR (*GetDescriptiveMetadata)(PKImageDecode*, void*);
    ERR (*GetRawStream)(PKImageDecode*, WMPStream**);
    ERR (*Copy)(PKImageDecode*, const void* /* PKRect */, uint8_t*, uint32_t);
    ERR (*GetFrameCount)(PKImageDecode*, uint32_t*);
    ERR (*SelectFrame)(PKImageDecode*, uint32_t);
    ERR (*Release)(PKImageDecode**);
} PKImageDecode;

typedef struct tagPKFormatConverter {
    ERR (*Initialize)(PKFormatConverter*, PKImageDecode*, char*, uint8_t* /* GUID */);
    ERR (*InitializeConvert)(PKFormatConverter*, const uint8_t*, char*, uint8_t*);
    ERR (*GetPixelFormat)(PKFormatConverter*, uint8_t*);
    ERR (*GetSourcePixelFormat)(PKFormatConverter*, uint8_t*);
    ERR (*GetSize)(PKFormatConverter*, int32_t*, int32_t*);
    ERR (*GetResolution)(PKFormatConverter*, float*, float*);
    ERR (*Copy)(PKFormatConverter*, const void*, uint8_t*, uint32_t);
    ERR (*Convert)(PKFormatConverter*, const void*, uint8_t*, uint32_t);
    ERR (*Release)(PKFormatConverter**);
} PKFormatConverter;

typedef struct {
    uint32_t Data1;
    uint16_t Data2;
    uint16_t Data3;
    uint8_t  Data4[8];
} PKPixelFormatGUID;

typedef struct {
    int32_t X;
    int32_t Y;
    int32_t Width;
    int32_t Height;
} PKRect;

ERR PKCreateFactory(PKFactory** ppFactory, uint32_t uVersion);
ERR PKCreateCodecFactory(PKCodecFactory** ppCodecFactory, uint32_t uVersion);
ERR PKAllocAligned(void** ppv, size_t cb, size_t cbAlign);
void PKFreeAligned(void** ppv);

/* GUIDs jxr.zig's classifyPixelFormat uses — values copied verbatim from
 * JXRGlue.h. jxr.zig compares them via mem.eql on raw bytes, so the
 * exact byte layout must match. */
extern const PKPixelFormatGUID GUID_PKPixelFormat48bppRGBFixedPoint;
extern const PKPixelFormatGUID GUID_PKPixelFormat48bppRGBHalf;
extern const PKPixelFormatGUID GUID_PKPixelFormat64bppRGBFixedPoint;
extern const PKPixelFormatGUID GUID_PKPixelFormat64bppRGBHalf;
extern const PKPixelFormatGUID GUID_PKPixelFormat96bppRGBFixedPoint;
extern const PKPixelFormatGUID GUID_PKPixelFormat128bppRGBFloat;
extern const PKPixelFormatGUID GUID_PKPixelFormat128bppRGBAFloat;
extern const PKPixelFormatGUID GUID_PKPixelFormat128bppRGBAFixedPoint;
extern const PKPixelFormatGUID GUID_PKPixelFormat16bppGrayFixedPoint;
extern const PKPixelFormatGUID GUID_PKPixelFormat16bppGrayHalf;
extern const PKPixelFormatGUID GUID_PKPixelFormat32bppGrayFixedPoint;
extern const PKPixelFormatGUID GUID_PKPixelFormat32bppGrayFloat;

#endif /* JXC_JXRLIB_MINIMAL_H_ */
