// jxc — HDR JXR (and WDP/HDP) to JPEG XL converter.
//
// Modes:
//   jxc <input.jxr>           <output.jxl>               single file
//   jxc <input.jxr>                                       single file, output = <input>.jxl
//   jxc <input-dir/>          <output-dir/>              batch
//   jxc <input-dir/>                                      batch, output = input-dir (in-place)
//
// Safe defaults:
//   - If output is omitted: single-file uses <input-stem>.jxl; batch uses
//     input-dir as output-dir (so batch can convert in-place).
//   - Existing output files are NOT overwritten. Skipped with a warning.
//
// Default is SDR (8-bit sRGB). Add --hdr to preserve Rec.2020 + linear HDR
// values for HDR-capable displays/viewers. Without --hdr, HDR source pixels
// are tone-mapped into the sRGB display range, which is what most monitors
// and image viewers expect.

const std = @import("std");
const jxr = @import("jxr.zig");
const jxl = @import("jxl.zig");
const batch = @import("batch.zig");

const usage =
    \\jxc — HDR JXR (and WDP/HDP) to JPEG XL converter
    \\
    \\Usage:
    \\  jxc [--hdr] [--distance <float>] <input.jxr>  [<output.jxl>]
    \\  jxc [--hdr] [--distance <float>] <input-dir/> [<output-dir/>]
    \\
    \\If output is omitted:
    \\  single file → <input>.jxl in same directory
    \\  batch       → output-dir = input-dir (in-place conversion)
    \\
    \\Existing output files are skipped (not overwritten).
    \\
    \\Default: 8-bit sRGB output. HDR source pixels are tone-mapped into the
    \\sRGB display range, so the result opens correctly in every image viewer.
    \\
    \\--hdr: preserve full HDR (Rec.2020 primaries + linear transfer, 32-bit
    \\       float). For HDR-capable displays/viewers only. Without color
    \\       management, viewers on sRGB displays render this as
    \\       over-saturated and slightly off in color.
    \\
    \\--distance controls quality (libjxl Butteraugli distance):
    \\  1.0   visually lossless (default)
    \\  0.0   lossless (pixel-byte-exact)
    \\  2.0+  lower quality, smaller files
    \\
;

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_writer_obj: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_writer_obj.interface;

    var stderr_buffer: [4096]u8 = undefined;
    var stderr_writer_obj: std.Io.File.Writer = .init(.stderr(), io, &stderr_buffer);
    const stderr_writer = &stderr_writer_obj.interface;

    const args = try init.minimal.args.toSlice(init.arena.allocator());

    // Parse optional flags before positional input/output.
    var distance: f32 = 1.0;
    var target: jxl.Target = .sdr;
    var positional_start: usize = 1;
    while (positional_start < args.len) {
        if (std.mem.eql(u8, args[positional_start], "--distance")) {
            if (positional_start + 1 >= args.len) {
                try stderr_writer.writeAll("error: --distance requires a value\n");
                try stderr_writer.flush();
                std.process.exit(2);
            }
            distance = std.fmt.parseFloat(f32, args[positional_start + 1]) catch {
                try stderr_writer.print("error: invalid --distance value: {s}\n", .{args[positional_start + 1]});
                try stderr_writer.flush();
                std.process.exit(2);
            };
            if (distance < 0.0) distance = 0.0;
            positional_start += 2;
        } else if (std.mem.eql(u8, args[positional_start], "--hdr")) {
            target = .hdr;
            positional_start += 1;
        } else {
            break;
        }
    }

    if (args.len != positional_start + 1 and args.len != positional_start + 2) {
        try stderr_writer.writeAll(usage);
        try stderr_writer.flush();
        std.process.exit(2);
    }

    const input_path = args[positional_start];
    const output_path = if (args.len == positional_start + 2)
        args[positional_start + 1]
    else
        try defaultOutputPath(init.arena.allocator(), io, input_path);

    if (distance > 0.0) {
        try stdout_writer.print("quality: distance={d}\n", .{distance});
        try stdout_writer.flush();
    }

    if (std.Io.Dir.cwd().openDir(io, input_path, .{})) |_| {
        const summary = batch.run(input_path, output_path, distance, target, io, init.arena.allocator(), stdout_writer, stderr_writer) catch |err| {
            try stderr_writer.print("error: batch failed: {s}\n", .{@errorName(err)});
            try stderr_writer.flush();
            std.process.exit(1);
        };
        std.process.exit(if (summary.failed == 0) 0 else 1);
    } else |_| {
        const decoded = jxr.decode(input_path, init.arena.allocator()) catch |err| {
            try stderr_writer.print("error: decode failed for {s}: {s}\n", .{ input_path, @errorName(err) });
            try stderr_writer.flush();
            std.process.exit(1);
        };

        try stdout_writer.print("{s}: {d}x{d} {d}bpc exp={d} ch={d} icc={d}B target={s}\n", .{
            input_path,
            decoded.width,
            decoded.height,
            decoded.bits_per_channel,
            decoded.exponent_bits,
            decoded.channels,
            decoded.icc.len,
            @tagName(target),
        });
        try stdout_writer.flush();

        jxl.encode(decoded, output_path, distance, target, init.arena.allocator()) catch |err| {
            try stderr_writer.print("error: encode failed for {s}: {s}\n", .{ output_path, @errorName(err) });
            try stderr_writer.flush();
            std.process.exit(1);
        };

        try stdout_writer.print("{s}: ok\n", .{output_path});
        try stdout_writer.flush();
    }
}

/// Default output path when not specified:
///   single file: <input-stem>.jxl in same directory
///   directory: returns the input path itself (caller uses for in-place conversion)
fn defaultOutputPath(allocator: std.mem.Allocator, io: std.Io, input: []const u8) ![]u8 {
    // Detect directory vs file: try to open as dir.
    if (std.Io.Dir.cwd().openDir(io, input, .{})) |_| {
        // Directory input → batch mode uses input as output dir.
        return try allocator.dupe(u8, input);
    } else |_| {
        // File input → strip extension, append .jxl.
        const ext = std.fs.path.extension(input);
        const stem_len = input.len - ext.len;
        const out = try allocator.alloc(u8, stem_len + 4);
        @memcpy(out[0..stem_len], input[0..stem_len]);
        @memcpy(out[stem_len..][0..4], ".jxl");
        return out;
    }
}