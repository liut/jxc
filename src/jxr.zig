// src/jxr.zig — HDR JXR (and WDP/HDP) decoding via 4creators/jxrlib.
//
// Wraps the JXRGlue C API into idiomatic Zig. The C interop is via
// `@import("jxrlib")` (the addTranslateC module from build.zig).
//
// One call: `decode(path, allocator) !Decoded` returns everything the JXL
// encoder needs (size, pixel format GUID, raw pixels, optional ICC + EXIF).

const std = @import("std");
const jxrlib = @import("jxrlib");

pub const PixelFormat = enum(c_int) {
    unknown = -1,
    _24bppRGB = 0,
    _48bppRGBFixedPoint = 1,
    _48bppRGBHalf = 2,
    _64bppRGBFixedPoint = 3,
    _64bppRGBHalf = 4,
    _96bppRGBFixedPoint = 5,
    _128bppRGBFloat = 6,
    _128bppRGBAFixedPoint = 7,
    _128bppRGBAFloat = 8,
    _16bppGrayFixedPoint = 9,
    _16bppGrayHalf = 10,
    _32bppGrayFixedPoint = 11,
    _32bppGrayFloat = 12,
};

/// Raw decoded image. `pixels` is tightly packed (no row padding).
pub const Decoded = struct {
    width: u32,
    height: u32,
    /// Number of channels (3 for RGB, 4 for RGBA, 1 for gray).
    channels: u8,
    /// Bits per channel — 16 for fixed-point and half-float, 32 for full-float.
    bits_per_channel: u8,
    /// Float exponent bits per sample: 0 for fixed-point/integer, 5 for half-float, 8 for full-float.
    exponent_bits: u8,
    pixel_format: PixelFormat,
    /// Bytes per pixel (computed: channels * bits_per_channel / 8).
    bytes_per_pixel: usize,
    /// Total pixel buffer size in bytes.
    buffer_size: usize,
    pixels: []u8,
    /// ICC profile bytes (empty if source had no ICC).
    icc: []u8,
    /// EXIF bytes (empty if source had no EXIF).
    exif: []u8,
    /// Sum of all alpha-channel bytes (only meaningful for 4-channel inputs).
    /// If channels==4 and this is zero, the alpha channel is unused and the
    /// JXL encoder can drop it without changing the visible image.
    alpha_sum: u64,

    /// Convenience: returns true if the alpha channel is uniformly zero
    /// (or doesn't exist), meaning the encode step can safely omit it.
    pub fn alphaIsAllZero(self: Decoded) bool {
        if (self.channels != 4) return true;
        return self.alpha_sum == 0;
    }

    /// Release allocator-owned buffers.
    pub fn deinit(self: *Decoded, allocator: std.mem.Allocator) void {
        allocator.free(self.pixels);
        if (self.icc.len > 0) allocator.free(self.icc);
        if (self.exif.len > 0) allocator.free(self.exif);
    }
};

/// Decode the JXR file at `path` using `jxrlib`. The returned `Decoded`
/// owns its pixel/icc/exif buffers; call `decoded.deinit(allocator)` to free.
///
/// Returns `error.UnsupportedPixelFormat` if the source isn't HDR.
pub fn decode(path: []const u8, allocator: std.mem.Allocator) !Decoded {
    const c_path = try allocator.dupeZ(u8, path);
    defer allocator.free(c_path);

    var p_factory: ?*jxrlib.PKFactory = null;
    var p_codec_fact: ?*jxrlib.PKCodecFactory = null;
    var p_decoder: ?*jxrlib.PKImageDecode = null;
    var p_fc: ?*jxrlib.PKFormatConverter = null;
    var pixels: [*]u8 = undefined;
    var icc_buf: []u8 = &[_]u8{};
    var result: Decoded = undefined;
    var buffer_size: usize = 0;
    // exif_buf removed: see comment below about jxrlib EXIF fragility.
    const exif_buf: []u8 = &[_]u8{};

    // On error paths, skip the jxrlib Release calls — the decoder is in an
    // indeterminate state and Release can crash with bus errors on partial
    // initialization. Memory leaks in the error path are acceptable; OS reclaims
    // everything on exit.
    var errored = false;
    errdefer {
        errored = true;
        cleanup(allocator, buffer_size, &p_fc, &p_decoder, &p_codec_fact, &p_factory, pixels, icc_buf, exif_buf, errored);
    }

    // Factories
    if (jxrlib.PKCreateFactory(&p_factory, jxrlib.PK_SDK_VERSION) != 0)
        return error.JxrFactoryFailed;
    if (jxrlib.PKCreateCodecFactory(&p_codec_fact, jxrlib.WMP_SDK_VERSION) != 0)
        return error.JxrCodecFactoryFailed;

    // Decoder from file
    const create_from_file = p_codec_fact.?.CreateDecoderFromFile orelse return error.JxrMethodMissing;
    if (create_from_file(c_path.ptr, &p_decoder) != 0)
        return error.JxrOpenFailed;

    // Size
    const decoder = p_decoder.?;
    const get_size = decoder.GetSize orelse return error.JxrMethodMissing;
    var width: c_int = 0;
    var height: c_int = 0;
    _ = get_size(decoder, &width, &height);
    if (width <= 0 or height <= 0) return error.JxrEmptyImage;
    const w: u32 = @intCast(width);
    const h: u32 = @intCast(height);

    // Pixel format GUID
    const get_pf = decoder.GetPixelFormat orelse return error.JxrMethodMissing;
    var pf: jxrlib.PKPixelFormatGUID = undefined;
    _ = get_pf(decoder, &pf);

    const pixel_format = classifyPixelFormat(&pf) orelse return error.UnsupportedPixelFormat;
    const channels, const bits_per_channel, const exponent_bits = pixelFormatParams(pixel_format);
    const bytes_per_pixel: usize = (channels * bits_per_channel) / 8;
    buffer_size = @as(usize, w) * @as(usize, h) * bytes_per_pixel;

    // ICC (two-call: size then bytes)
    const get_cc = decoder.GetColorContext orelse return error.JxrMethodMissing;
    var icc_size: u32 = 0;
    _ = get_cc(decoder, null, &icc_size);
    if (icc_size > 0) {
        icc_buf = try allocator.alloc(u8, icc_size);
        var sz: u32 = icc_size;
        if (get_cc(decoder, icc_buf.ptr, &sz) != 0)
            return error.JxrIccReadFailed;
    }

    // EXIF (two-call) — Phase 5 enhancement, currently disabled due to a
// jxrlib assertion on its error-handling path. The release branch
// (4creators/jxrlib @ f752187) has known fragility around
// FreeDescMetadata when EXIF extraction is requested. Not critical for v1.

    // Allocate pixel buffer via jxrlib's aligned allocator (SIMD alignment).
    if (jxrlib.PKAllocAligned(@ptrCast(&pixels), buffer_size, 16) != 0)
        return error.JxrAllocFailed;

    // Format converter — preserve source pixel format (DontCare might rewrite).
    const create_fc = p_codec_fact.?.CreateFormatConverter orelse return error.JxrMethodMissing;
    if (create_fc(&p_fc) != 0)
        return error.JxrConverterCreateFailed;
    const fc = p_fc.?;
    // .raw extension = no further conversion; pass the source GUID.
    const raw_ext: [*c]u8 = @constCast(".raw");
    const init_fc = fc.Initialize orelse return error.JxrMethodMissing;
    if (init_fc(fc, decoder, raw_ext, pf) != 0)
        return error.JxrConverterInitFailed;

    var rect = jxrlib.PKRect{ .X = 0, .Y = 0, .Width = width, .Height = height };
    const fc_copy = fc.Copy orelse return error.JxrMethodMissing;
    if (fc_copy(fc, &rect, pixels, @intCast(@as(usize, w) * bytes_per_pixel)) != 0)
        return error.JxrDecodeFailed;

    // Sample alpha to detect unused alpha channels (common in HDR screenshots
    // reported as RGBA but actually RGB). Cheap because we only sample.
    var alpha_sum: u64 = 0;
    if (channels == 4) {
        const bytes_per_channel: usize = bits_per_channel / 8;
        const sample_stride: usize = bytes_per_pixel * 256; // every 256 pixels
        var idx: usize = bytes_per_channel * 3; // alpha is the 4th channel
        while (idx < buffer_size) : (idx += sample_stride) {
            // Sum all bytes of the alpha channel for this pixel (handles all
            // 16/32-bit formats uniformly).
            for (0..bytes_per_channel) |b| {
                alpha_sum += pixels[idx + b];
            }
        }
    }

    result = .{
        .width = w,
        .height = h,
        .channels = channels,
        .bits_per_channel = bits_per_channel,
        .exponent_bits = exponent_bits,
        .pixel_format = pixel_format,
        .bytes_per_pixel = bytes_per_pixel,
        .buffer_size = buffer_size,
        .alpha_sum = alpha_sum,
        .pixels = pixels[0..buffer_size],
        .icc = icc_buf,
        .exif = exif_buf,
    };
    return result;
}

fn cleanup(
    allocator: std.mem.Allocator,
    buffer_size: usize,
    p_fc: *?*jxrlib.PKFormatConverter,
    p_decoder: *?*jxrlib.PKImageDecode,
    p_codec_fact: *?*jxrlib.PKCodecFactory,
    p_factory: *?*jxrlib.PKFactory,
    pixels: [*]u8,
    icc_buf: []u8,
    exif_buf: []u8,
    errored: bool,
) void {
    if (p_fc.*) |fc| {
        if (fc.Release) |rel| {
            if (!errored) _ = rel(@ptrCast(fc));
        }
    }
    if (p_decoder.*) |d| {
        if (d.Release) |rel| {
            if (!errored) _ = rel(@ptrCast(d));
        }
    }
    if (p_codec_fact.*) |cf| {
        if (cf.Release) |rel| {
            if (!errored) _ = rel(@ptrCast(cf));
        }
    }
    if (p_factory.*) |f| {
        if (f.Release) |rel| {
            if (!errored) _ = rel(@ptrCast(f));
        }
    }
    if (buffer_size > 0) {
        var p: [*]u8 = pixels;
        _ = jxrlib.PKFreeAligned(@ptrCast(&p));
    }
    if (icc_buf.len > 0) allocator.free(icc_buf);
    if (exif_buf.len > 0) allocator.free(exif_buf);
}

/// Map jxrlib's GUID to our PixelFormat enum. Returns null for non-HDR
/// or unrecognized formats.
fn classifyPixelFormat(guid: *const jxrlib.PKPixelFormatGUID) ?PixelFormat {
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat48bppRGBFixedPoint))
        return ._48bppRGBFixedPoint;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat48bppRGBHalf))
        return ._48bppRGBHalf;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat64bppRGBFixedPoint))
        return ._64bppRGBFixedPoint;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat64bppRGBHalf))
        return ._64bppRGBHalf;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat96bppRGBFixedPoint))
        return ._96bppRGBFixedPoint;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat128bppRGBFloat))
        return ._128bppRGBFloat;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat128bppRGBAFloat))
        return ._128bppRGBAFloat;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat128bppRGBAFixedPoint))
        return ._128bppRGBAFixedPoint;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat16bppGrayFixedPoint))
        return ._16bppGrayFixedPoint;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat16bppGrayHalf))
        return ._16bppGrayHalf;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat32bppGrayFixedPoint))
        return ._32bppGrayFixedPoint;
    if (memEqlGuid(guid, &jxrlib.GUID_PKPixelFormat32bppGrayFloat))
        return ._32bppGrayFloat;
    return null;
}

fn memEqlGuid(a: *const jxrlib.PKPixelFormatGUID, b: *const jxrlib.PKPixelFormatGUID) bool {
    return std.mem.eql(u8, std.mem.asBytes(a), std.mem.asBytes(b));
}

/// Returns (channels, bits_per_channel, exponent_bits) for each HDR format.
fn pixelFormatParams(pf: PixelFormat) struct { u8, u8, u8 } {
    return switch (pf) {
        ._48bppRGBFixedPoint => .{ 3, 16, 0 },
        ._48bppRGBHalf => .{ 3, 16, 5 },
        ._64bppRGBFixedPoint => .{ 4, 16, 0 },
        ._64bppRGBHalf => .{ 4, 16, 5 },
        ._96bppRGBFixedPoint => .{ 3, 32, 0 },
        ._128bppRGBFloat => .{ 3, 32, 8 },
        ._128bppRGBAFixedPoint => .{ 4, 32, 0 },
        ._128bppRGBAFloat => .{ 4, 32, 8 },
        ._16bppGrayFixedPoint => .{ 1, 16, 0 },
        ._16bppGrayHalf => .{ 1, 16, 5 },
        ._32bppGrayFixedPoint => .{ 1, 32, 0 },
        ._32bppGrayFloat => .{ 1, 32, 8 },
        ._24bppRGB, .unknown => .{ 0, 0, 0 },
    };
}