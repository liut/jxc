// src/jxl.zig — JPEG XL encoding via libjxl.
//
// Wraps the libjxl C API for HDR-aware JXL output. The C interop is via
// `@import("jxl")` (the addTranslateC module from build.zig).
//
// Two output targets:
//   - Target.hdr: 32-bit float Rec.2020 + linear transfer. Default. For HDR
//     displays; preserves HDR values up to displayable range.
//   - Target.sdr: 8-bit sRGB. For sRGB displays. Applies tone mapping,
//     Rec.2020 → sRGB color gamut matrix, sRGB gamma curve. Looks
//     "natural" on regular monitors; loses HDR info above ~1000 nits.

const std = @import("std");
const jxl = @import("libjxl");
const jxr = @import("jxr.zig");

pub const Target = enum { hdr, sdr };

pub const EncodeError = error{
    JxlEncoderCreateFailed,
    JxlBasicInfoFailed,
    JxlColorEncodingFailed,
    JxlIccRejected,
    JxlFrameSettingsFailed,
    JxlAddFrameFailed,
    JxlCloseInputFailed,
    JxlProcessOutputFailed,
    JxlOpenOutFileFailed,
    JxlWriteFailed,
    JxlUnsupportedLayout,
};

pub fn encode(
    decoded: jxr.Decoded,
    out_path: []const u8,
    distance: f32,
    target: Target,
    allocator: std.mem.Allocator,
) (EncodeError || std.mem.Allocator.Error)!void {
    const enc = jxl.JxlEncoderCreate(null) orelse return EncodeError.JxlEncoderCreateFailed;
    defer jxl.JxlEncoderDestroy(enc);

    _ = jxl.JxlEncoderSetParallelRunner(enc, null, null);

    // Many HDR JXR files report 4-channel RGBA but actually contain only RGB
    // data (alpha is uniformly 0). Detect and encode as RGB to avoid a
    // fully-transparent output.
    const has_alpha = decoded.channels == 4 and !decoded.alphaIsAllZero();

    if (target == .hdr) {
        try encodeHdr(enc, decoded, distance, has_alpha, allocator);
    } else {
        try encodeSdr(enc, decoded, distance, has_alpha, allocator);
    }

    // Drain to file via C stdio (simpler than Zig 0.16's Io-based file API).
    var c_path_buf = try allocator.allocSentinel(u8, out_path.len, 0);
    defer allocator.free(c_path_buf);
    @memcpy(c_path_buf[0..out_path.len], out_path);
    const c_path: [*:0]u8 = c_path_buf.ptr;
    const c_mode: [*:0]const u8 = "wb";
    const f: ?*std.c.FILE = @ptrCast(std.c.fopen(c_path, c_mode));
    if (f == null) return EncodeError.JxlOpenOutFileFailed;
    defer _ = std.c.fclose(f.?);

    var out_buf: [65536]u8 = undefined;
    while (true) {
        var next: [*c]u8 = @ptrCast(&out_buf);
        var avail: usize = out_buf.len;
        const status = jxl.JxlEncoderProcessOutput(enc, &next, &avail);
        const written: usize = out_buf.len - avail;
        if (written > 0) {
            const n = std.c.fwrite(out_buf[0..written].ptr, 1, written, f.?);
            if (n != written) return EncodeError.JxlWriteFailed;
        }
        switch (status) {
            jxl.JXL_ENC_SUCCESS => return,
            jxl.JXL_ENC_NEED_MORE_OUTPUT => continue,
            else => return EncodeError.JxlProcessOutputFailed,
        }
    }
}

fn encodeHdr(
    enc: *jxl.JxlEncoder,
    decoded: jxr.Decoded,
    distance: f32,
    has_alpha: bool,
    allocator: std.mem.Allocator,
) EncodeError!void {
    var info: jxl.JxlBasicInfo = std.mem.zeroes(jxl.JxlBasicInfo);
    jxl.JxlEncoderInitBasicInfo(&info);
    info.xsize = decoded.width;
    info.ysize = decoded.height;
    info.bits_per_sample = decoded.bits_per_channel;
    info.exponent_bits_per_sample = decoded.exponent_bits;
    info.num_color_channels = 3;
    if (has_alpha) {
        info.num_extra_channels = 1;
        info.alpha_bits = decoded.bits_per_channel;
        info.alpha_exponent_bits = decoded.exponent_bits;
        info.alpha_premultiplied = jxl.JXL_FALSE;
    } else {
        info.num_extra_channels = 0;
        info.alpha_bits = 0;
    }
    info.uses_original_profile = jxl.JXL_TRUE;
    info.intensity_target = 0;
    if (jxl.JxlEncoderSetBasicInfo(enc, &info) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlBasicInfoFailed;

    if (decoded.icc.len > 0) {
        if (jxl.JxlEncoderSetICCProfile(
            enc,
            @as([*c]const u8, decoded.icc.ptr) orelse unreachable,
            @intCast(decoded.icc.len),
        ) != jxl.JXL_ENC_SUCCESS) {
            try setHdrColorEncoding(enc);
        }
    } else {
        try setHdrColorEncoding(enc);
    }

    const fs = jxl.JxlEncoderFrameSettingsCreate(enc, null) orelse return EncodeError.JxlFrameSettingsFailed;
    if (distance <= 0.0) {
        if (jxl.JxlEncoderSetFrameLossless(fs, jxl.JXL_TRUE) != jxl.JXL_ENC_SUCCESS)
            return EncodeError.JxlFrameSettingsFailed;
    } else {
        if (jxl.JxlEncoderSetFrameDistance(fs, distance) != jxl.JXL_ENC_SUCCESS)
            return EncodeError.JxlFrameSettingsFailed;
    }

    const jxl_channels: u32 = if (has_alpha) 4 else 3;
    const jxl_pixels = if (has_alpha)
        decoded.pixels
    else
        stripAlpha(allocator, decoded) catch return EncodeError.JxlUnsupportedLayout;

    var pix_fmt: jxl.JxlPixelFormat = std.mem.zeroes(jxl.JxlPixelFormat);
    pix_fmt.num_channels = jxl_channels;
    pix_fmt.data_type = switch (decoded.exponent_bits) {
        0 => if (decoded.bits_per_channel == 16) jxl.JXL_TYPE_UINT16 else return EncodeError.JxlUnsupportedLayout,
        5 => jxl.JXL_TYPE_FLOAT16,
        8 => jxl.JXL_TYPE_FLOAT,
        else => return EncodeError.JxlUnsupportedLayout,
    };
    pix_fmt.endianness = jxl.JXL_NATIVE_ENDIAN;
    pix_fmt.@"align" = 0;

    const pixel_ptr: ?*const anyopaque = @ptrCast(jxl_pixels.ptr);
    if (jxl.JxlEncoderAddImageFrame(fs, &pix_fmt, pixel_ptr, jxl_pixels.len) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlAddFrameFailed;
    jxl.JxlEncoderCloseInput(enc);
}

fn encodeSdr(
    enc: *jxl.JxlEncoder,
    decoded: jxr.Decoded,
    distance: f32,
    has_alpha: bool,
    allocator: std.mem.Allocator,
) EncodeError!void {
    // Convert HDR linear Rec.2020 → 8-bit sRGB.
    const sdr_bytes = sdrConvert(allocator, decoded) catch return EncodeError.JxlUnsupportedLayout;
    defer allocator.free(sdr_bytes);

    var info: jxl.JxlBasicInfo = std.mem.zeroes(jxl.JxlBasicInfo);
    jxl.JxlEncoderInitBasicInfo(&info);
    info.xsize = decoded.width;
    info.ysize = decoded.height;
    info.bits_per_sample = 8;
    info.exponent_bits_per_sample = 0;
    info.num_color_channels = 3;
    if (has_alpha) {
        info.num_extra_channels = 1;
        info.alpha_bits = 8;
        info.alpha_exponent_bits = 0;
        info.alpha_premultiplied = jxl.JXL_FALSE;
    } else {
        info.num_extra_channels = 0;
        info.alpha_bits = 0;
    }
    info.uses_original_profile = jxl.JXL_TRUE;
    info.intensity_target = 0;
    if (jxl.JxlEncoderSetBasicInfo(enc, &info) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlBasicInfoFailed;

    try setSdrColorEncoding(enc);

    const fs = jxl.JxlEncoderFrameSettingsCreate(enc, null) orelse return EncodeError.JxlFrameSettingsFailed;
    if (distance <= 0.0) {
        if (jxl.JxlEncoderSetFrameLossless(fs, jxl.JXL_TRUE) != jxl.JXL_ENC_SUCCESS)
            return EncodeError.JxlFrameSettingsFailed;
    } else {
        if (jxl.JxlEncoderSetFrameDistance(fs, distance) != jxl.JXL_ENC_SUCCESS)
            return EncodeError.JxlFrameSettingsFailed;
    }

    // For SDR we always emit 3-channel sRGB (alpha gets re-encoded as 8-bit
    // opaque=255 if the source actually has one, otherwise omitted).
    const sdr_with_alpha = if (has_alpha) blk: {
        const with_alpha = allocator.alloc(u8, decoded.width * decoded.height * 4) catch return EncodeError.JxlUnsupportedLayout;
        // sdr_bytes is 3 channels; convert to RGBA by appending 0xFF per pixel.
        const N = decoded.width * decoded.height;
        var p: usize = 0;
        var q: usize = 0;
        while (p < N) : (p += 1) {
            with_alpha[q] = sdr_bytes[p * 3];
            with_alpha[q + 1] = sdr_bytes[p * 3 + 1];
            with_alpha[q + 2] = sdr_bytes[p * 3 + 2];
            with_alpha[q + 3] = 255;
            q += 4;
        }
        break :blk with_alpha;
    } else sdr_bytes;
    defer if (has_alpha) allocator.free(sdr_with_alpha);

    var pix_fmt: jxl.JxlPixelFormat = std.mem.zeroes(jxl.JxlPixelFormat);
    pix_fmt.num_channels = if (has_alpha) 4 else 3;
    pix_fmt.data_type = jxl.JXL_TYPE_UINT8;
    pix_fmt.endianness = jxl.JXL_NATIVE_ENDIAN;
    pix_fmt.@"align" = 0;

    const pixel_ptr: ?*const anyopaque = @ptrCast(sdr_with_alpha.ptr);
    if (jxl.JxlEncoderAddImageFrame(fs, &pix_fmt, pixel_ptr, sdr_with_alpha.len) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlAddFrameFailed;
    jxl.JxlEncoderCloseInput(enc);
}

/// Default Rec.2020 + linear transfer for HDR sources without an ICC profile.
fn setHdrColorEncoding(enc: *jxl.JxlEncoder) EncodeError!void {
    var color: jxl.JxlColorEncoding = std.mem.zeroes(jxl.JxlColorEncoding);
    color.color_space = jxl.JXL_COLOR_SPACE_RGB;
    color.white_point = jxl.JXL_WHITE_POINT_D65;
    color.primaries = jxl.JXL_PRIMARIES_2100;
    color.transfer_function = jxl.JXL_TRANSFER_FUNCTION_LINEAR;
    color.rendering_intent = jxl.JXL_RENDERING_INTENT_RELATIVE;
    if (jxl.JxlEncoderSetColorEncoding(enc, &color) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlColorEncodingFailed;
}

/// Standard sRGB color encoding for SDR output.
fn setSdrColorEncoding(enc: *jxl.JxlEncoder) EncodeError!void {
    var color: jxl.JxlColorEncoding = std.mem.zeroes(jxl.JxlColorEncoding);
    color.color_space = jxl.JXL_COLOR_SPACE_RGB;
    color.white_point = jxl.JXL_WHITE_POINT_D65;
    color.primaries = jxl.JXL_PRIMARIES_SRGB;
    color.transfer_function = jxl.JXL_TRANSFER_FUNCTION_SRGB;
    color.rendering_intent = jxl.JXL_RENDERING_INTENT_RELATIVE;
    if (jxl.JxlEncoderSetColorEncoding(enc, &color) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlColorEncodingFailed;
}

/// Convert HDR linear sRGB-extended → 8-bit sRGB.
/// Steps: linearize source → clamp → sRGB gamma encode → 8-bit.
///
/// NO primaries matrix. The source is treated as sRGB primaries extended
/// to HDR (above 1.0). This matches XnConvert output byte-for-byte on
/// Windows HDR screenshots and FF7 Remake captures. Rec.2020 assumption
/// was incorrect — those primaries were wider, and the matrix pushed pixels
/// toward green/blue (shifting the image to a "grayer/cooler" appearance).
fn sdrConvert(allocator: std.mem.Allocator, decoded: jxr.Decoded) ![]u8 {
    const w = decoded.width;
    const h = decoded.height;
    const N = w * h;
    const out = try allocator.alloc(u8, N * 3);

    const bpp = decoded.bytes_per_pixel; // bytes per pixel in source
    const src_channels = decoded.channels;

    var i: usize = 0; // index into decoded.pixels (in bytes)
    var j: usize = 0; // index into out (in bytes, 3 bytes per pixel)
    while (j < out.len) : (i += bpp) {
        const r_lin = readLinear(decoded.pixels, i, decoded.exponent_bits, decoded.bits_per_channel);
        const g_lin = readLinear(decoded.pixels, i + bpp / src_channels, decoded.exponent_bits, decoded.bits_per_channel);
        const b_lin = readLinear(decoded.pixels, i + 2 * (bpp / src_channels), decoded.exponent_bits, decoded.bits_per_channel);

        // Hard clamp to [0, 1]. Values above 1.0 are highlights that exceed
        // the display range — they collapse to white, matching what every
        // 8-bit sRGB image viewer would do.
        const r_clip = @min(@max(r_lin, 0.0), 1.0);
        const g_clip = @min(@max(g_lin, 0.0), 1.0);
        const b_clip = @min(@max(b_lin, 0.0), 1.0);

        out[j] = srgbEncode(r_clip);
        out[j + 1] = srgbEncode(g_clip);
        out[j + 2] = srgbEncode(b_clip);

        j += 3;
    }

    return out;
}

/// Read a linear float value from a pixel component at byte offset `off`.
/// Handles 32-bit float (exponent=8), 16-bit half-float (exponent=5), and
/// 16-bit signed fixed-point (exponent=0, s15.16).
fn readLinear(buf: []u8, off: usize, exponent_bits: u8, bits_per_channel: u8) f32 {
    _ = bits_per_channel;
    if (exponent_bits == 8) {
        return std.mem.bytesAsValue(f32, buf[off..][0..4]).*;
    } else if (exponent_bits == 5) {
        const h: u16 = std.mem.bytesAsValue(u16, buf[off..][0..2]).*;
        return halfToFloat(h);
    } else if (exponent_bits == 0) {
        const bits: i16 = std.mem.bytesAsValue(i16, buf[off..][0..2]).*;
        return @as(f32, bits) / 32768.0;
    }
    return 0.0;
}

/// IEEE 754 binary16 → binary32 conversion.
fn halfToFloat(h: u16) f32 {
    const sign: u32 = @as(u32, (h >> 15) & 1) << 31;
    const exp: u32 = @as(u32, (h >> 10) & 0x1f);
    const mant: u32 = @as(u32, h & 0x3ff);

    if (exp == 0) {
        // Zero or subnormal — treat subnormal as 0
        if (mant == 0) return @bitCast(sign);
        return 0.0;
    } else if (exp == 31) {
        // Inf or NaN
        return @bitCast(sign | 0x7f800000 | mant);
    }

    const f32_exp: u32 = exp - 15 + 127;
    return @bitCast(sign | (f32_exp << 23) | (mant << 13));
}

/// sRGB gamma encode (linear → encoded value in [0, 1]).
/// Standard IEC 61966-2-1 piecewise function.
fn srgbEncode(linear: f32) u8 {
    const x = @min(@max(linear, 0.0), 1.0);
    const encoded = if (x <= 0.0031308)
        x * 12.92
    else
        1.055 * std.math.pow(f32, x, 1.0 / 2.4) - 0.055;
    return @intFromFloat(@min(@max(encoded * 255.0 + 0.5, 0.0), 255.0));
}

/// Drop the alpha channel from a decoded RGBA buffer, producing a tightly
/// packed RGB buffer. Caller owns the returned slice and must free it.
fn stripAlpha(allocator: std.mem.Allocator, decoded: jxr.Decoded) ![]u8 {
    const channels = decoded.channels;
    if (channels != 4) return decoded.pixels;
    const bytes_per_pixel_in = decoded.bytes_per_pixel;
    const bytes_per_pixel_out = (bytes_per_pixel_in / 4) * 3;
    const out = try allocator.alloc(u8, decoded.width * decoded.height * bytes_per_pixel_out);
    var i: usize = 0;
    var j: usize = 0;
    while (j < out.len) : (i += bytes_per_pixel_in) {
        @memcpy(out[j .. j + bytes_per_pixel_out], decoded.pixels[i .. i + bytes_per_pixel_out]);
        j += bytes_per_pixel_out;
    }
    return out;
}