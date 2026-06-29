// src/jxl.zig — JPEG XL encoding via libjxl.
//
// Wraps the libjxl C API for HDR-aware JXL output. The C interop is via
// `@import("jxl")` (the addTranslateC module from build.zig).
//
// One call: `encode(decoded, out_path, allocator) !void` produces a
// JXL file from a previously-decoded `jxr.Decoded`.

const std = @import("std");
const jxl = @import("libjxl");
const jxr = @import("jxr.zig");

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

pub fn encode(decoded: jxr.Decoded, out_path: []const u8, allocator: std.mem.Allocator) (EncodeError || std.mem.Allocator.Error)!void {
    const enc = jxl.JxlEncoderCreate(null) orelse return EncodeError.JxlEncoderCreateFailed;
    defer jxl.JxlEncoderDestroy(enc);

    // Single-threaded for v1; threading is a v2 concern.
    _ = jxl.JxlEncoderSetParallelRunner(enc, null, null);

    // Build JxlBasicInfo.
    var info: jxl.JxlBasicInfo = std.mem.zeroes(jxl.JxlBasicInfo);
    jxl.JxlEncoderInitBasicInfo(&info);
    info.xsize = decoded.width;
    info.ysize = decoded.height;
    info.bits_per_sample = decoded.bits_per_channel;
    info.exponent_bits_per_sample = decoded.exponent_bits;
    info.num_color_channels = if (decoded.channels <= 3) 3 else 3; // always 3 for RGB family
    if (decoded.channels == 4) {
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

    // Color metadata. ICC preferred (R2); fall back to Rec.2020 + PQ.
    if (decoded.icc.len > 0) {
        if (jxl.JxlEncoderSetICCProfile(
            enc,
            @as([*c]const u8, decoded.icc.ptr) orelse unreachable,
            @intCast(decoded.icc.len),
        ) != jxl.JXL_ENC_SUCCESS) {
            // Some Windows HDR ICC profiles are non-conformant and libjxl rejects them.
            // Fall through to the Rec.2020 + PQ default.
            try setFallbackColorEncoding(enc);
        }
    } else {
        try setFallbackColorEncoding(enc);
    }

    // Lossless frame preserves pixel values exactly (no quantization).
    const fs = jxl.JxlEncoderFrameSettingsCreate(enc, null) orelse return EncodeError.JxlFrameSettingsFailed;
    if (jxl.JxlEncoderSetFrameLossless(fs, jxl.JXL_TRUE) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlFrameSettingsFailed;

    // JxlPixelFormat must match the source pixel layout byte-for-byte.
    // We support the common HDR pixel types: 16-bit integer, 16-bit half-float,
    // 32-bit full float. The rare 32-bit-integer fixed-point (s31.32) HDR
    // format is rejected at decode time for v1 — libjxl has no UINT32 pixel type.
    var pix_fmt: jxl.JxlPixelFormat = std.mem.zeroes(jxl.JxlPixelFormat);
    pix_fmt.num_channels = decoded.channels;
    pix_fmt.data_type = switch (decoded.exponent_bits) {
        0 => if (decoded.bits_per_channel == 16) jxl.JXL_TYPE_UINT16 else return EncodeError.JxlUnsupportedLayout,
        5 => jxl.JXL_TYPE_FLOAT16,
        8 => jxl.JXL_TYPE_FLOAT,
        else => return EncodeError.JxlUnsupportedLayout,
    };
    pix_fmt.endianness = jxl.JXL_NATIVE_ENDIAN;
    pix_fmt.@"align" = 0;

    const pixel_ptr: ?*const anyopaque = @ptrCast(decoded.pixels.ptr);
    if (jxl.JxlEncoderAddImageFrame(fs, &pix_fmt, pixel_ptr, decoded.buffer_size) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlAddFrameFailed;
    jxl.JxlEncoderCloseInput(enc);

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

/// Default Rec.2020 + PQ color encoding for HDR sources without an ICC profile.
fn setFallbackColorEncoding(enc: *jxl.JxlEncoder) EncodeError!void {
    var color: jxl.JxlColorEncoding = std.mem.zeroes(jxl.JxlColorEncoding);
    color.color_space = jxl.JXL_COLOR_SPACE_RGB;
    color.white_point = jxl.JXL_WHITE_POINT_D65;
    color.primaries = jxl.JXL_PRIMARIES_2100;
    color.transfer_function = jxl.JXL_TRANSFER_FUNCTION_PQ;
    color.rendering_intent = jxl.JXL_RENDERING_INTENT_RELATIVE;
    if (jxl.JxlEncoderSetColorEncoding(enc, &color) != jxl.JXL_ENC_SUCCESS)
        return EncodeError.JxlColorEncodingFailed;
}