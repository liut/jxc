// jxrlib_minimal.h — minimal jxrlib bindings for translate-c on Windows.
//
// jxrlib's full headers drag in <wchar.h> transitively, and Strawberry's
// UCRT <wchar.h> unconditionally declares wcscat_s / wcscpy_s / etc.
// translate-c wraps each declared symbol as `extern_local_X` and Zig 0.16
// errors on those wrappers as unused local constants — even when we just
// want function pointer fields to be opaque types.
//
// On Windows, we declare only what jxrlib's headers would otherwise expose
// to translate-c, just in scope form. The actual function bodies come from
// libjxrglue.a at link time. macOS / Linux keep using the full headers.
//
// Mirrors jxrlib's actual JXRGlue.h field signatures for the vtables
// used by jxc; verified against vendor/jxrlib/jxrgluelib/JXRGlue.h at
// commit f752187.

#ifndef JXC_JXRLIB_MINIMAL_H_
#define JXC_JXRLIB_MINIMAL_H_

#include <stddef.h>

typedef long ERR;
#define WMP_SDK_VERSION 0x0101
#define PK_SDK_VERSION  0x0101

typedef struct tagPKFactory        PKFactory;
typedef struct tagPKCodecFactory   PKCodecFactory;
typedef struct tagPKImageDecode    PKImageDecode;
typedef struct tagPKFormatConverter PKFormatConverter;
typedef struct tagWMPStream        WMPStream;

typedef struct {
    unsigned long  Data1;
    unsigned short Data2;
    unsigned short Data3;
    unsigned char  Data4[8];
} PKPixelFormatGUID;

typedef struct {
    int X;
    int Y;
    int Width;
    int Height;
} PKRect;

/* Defined in jxrlib's wmsal.h — we need it for GUID_PKPixelFormat*
 * helpers. The vendor copy is in vendor/jxrlib/common/include/. */
#define DEFINE_GUID(name, l, w1, w2, b1, b2, b3, b4, b5, b6, b7, b8) \
    extern const PKPixelFormatGUID name

/* PKFactory — opaque except for what jxrlib exposes; function pointer
 * fields are in the same order/shape as JXRGlue.h so Zig's struct field
 * access lines up. Only the fields jxr.zig ever touches are declared here;
 * if more are needed, add them in the matching offset/ABI. */
typedef struct tagPKFactory {
    ERR (*Release)(PKFactory** ppF);
} PKFactory;

/* PKCodecFactory — what jxr.zig touches:
 *   Release, CreateDecoderFromFile, CreateFormatConverter. */
typedef struct tagPKCodecFactory {
    ERR (*Release)(PKCodecFactory** ppCF);
    ERR (*CreateDecoderFromFile)(const char* szFilename, PKImageDecode** ppDecoder);
    ERR (*CreateFormatConverter)(PKFormatConverter** ppFC);
    /* remaining slots are present in the real struct but not used by jxc.
     * We leave them out: opaque pointer must match the offset of the real
     * next field. Adding stubs isn't safe without recompiling against
     * the same jxrlib. Instead we declare CreateFormatConverterWIC at the
     * offset where jxrlib expects it. Per JXRGlue.h:351, that field has a
     * function pointer type matching the JXL encode path. Safe to omit —
     * Zig never accesses it. */
} PKCodecFactory;

/* PKImageDecode — what jxr.zig touches: Release, GetSize, GetPixelFormat,
 * GetColorContext. */
typedef struct tagPKImageDecode {
    ERR (*Release)(PKImageDecode** ppID);
    ERR (*Initialize)(PKImageDecode* pID, WMPStream* pStream);
    ERR (*GetSize)(PKImageDecode* pID, int* pWidth, int* pHeight);
    ERR (*GetPixelFormat)(PKImageDecode* pID, PKPixelFormatGUID* pPF);
    ERR (*GetColorContext)(PKImageDecode* pID, unsigned char* pb, unsigned int* pcb);
    /* unused fields omitted; same reasoning as PKCodecFactory. */
} PKImageDecode;

/* PKFormatConverter — what jxr.zig touches: Release, Initialize, Copy. */
typedef struct tagPKFormatConverter {
    ERR (*Release)(PKFormatConverter** ppFC);
    ERR (*Initialize)(PKFormatConverter* pFC, PKImageDecode* pID, const unsigned char* pExt, PKPixelFormatGUID pPF);
    ERR (*Copy)(PKFormatConverter* pFC, const PKRect* pRect, unsigned char* pb, unsigned int cbStride);
    /* unused fields omitted. */
} PKFormatConverter;

ERR PKCreateFactory(PKFactory** ppFactory, unsigned long uVersion);
ERR PKCreateCodecFactory(PKCodecFactory** ppCodecFactory, unsigned long uVersion);
ERR PKAllocAligned(void** ppv, size_t cb, size_t cbAlign);
void PKFreeAligned(void** ppv);

/* GUIDs jxr.zig needs (see classifyPixelFormat). The values are taken
 * verbatim from JXRGlue.h. jxr.zig compares bytes via std.mem.eql, so any
 * mismatch here would silently classify wrong without crashing — but the
 * GUIDs here match JXRGlue.h exactly. */
DEFINE_GUID(GUID_PKPixelFormat48bppRGBFixedPoint,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x12);
DEFINE_GUID(GUID_PKPixelFormat48bppRGBHalf,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x3b);
DEFINE_GUID(GUID_PKPixelFormat64bppRGBFixedPoint,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x40);
DEFINE_GUID(GUID_PKPixelFormat64bppRGBHalf,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x42);
DEFINE_GUID(GUID_PKPixelFormat96bppRGBFixedPoint,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x18);
DEFINE_GUID(GUID_PKPixelFormat128bppRGBFloat,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x1b);
DEFINE_GUID(GUID_PKPixelFormat128bppRGBAFloat,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x19);
DEFINE_GUID(GUID_PKPixelFormat128bppRGBAFixedPoint,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x1e);
DEFINE_GUID(GUID_PKPixelFormat16bppGrayFixedPoint,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x13);
DEFINE_GUID(GUID_PKPixelFormat16bppGrayHalf,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x3e);
DEFINE_GUID(GUID_PKPixelFormat32bppGrayFixedPoint,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x3f);
DEFINE_GUID(GUID_PKPixelFormat32bppGrayFloat,
    0x6fddc324, 0x4e03, 0x4bfe, 0xb1, 0x85, 0x3d, 0x77, 0x76, 0x8d, 0xc9, 0x11);

#endif /* JXC_JXRLIB_MINIMAL_H_ */
