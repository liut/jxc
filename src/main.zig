// jxc — HDR JXR (and WDP/HDP) to JPEG XL converter.
//
// Modes:
//   jxc <input.jxr>           <output.jxl>      single file
//   jxc <input-dir/>          <output-dir/>     batch (recursive)
//
// HDR is non-negotiable; SDR-only files are rejected (R1, plan Phase 3).

const std = @import("std");
const jxr = @import("jxr.zig");
const jxl = @import("jxl.zig");
const batch = @import("batch.zig");

const usage =
    \\jxc — HDR JXR (and WDP/HDP) to JPEG XL converter
    \\
    \\Usage:
    \\  jxc <input.jxr>  <output.jxl>      single file
    \\  jxc <input-dir/> <output-dir/>     batch (recursive)
    \\
    \\HDR is non-negotiable. SDR-only files will be rejected.
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
    if (args.len != 3) {
        try stderr_writer.writeAll(usage);
        try stderr_writer.flush();
        std.process.exit(2);
    }

    const input_path = args[1];
    const output_path = args[2];

    // Detect file vs directory by trying to open the path as a directory.
    // If it succeeds → batch mode. If it fails → treat as single file.
    if (std.Io.Dir.cwd().openDir(io, input_path, .{})) |_| {
        const summary = batch.run(input_path, output_path, io, init.arena.allocator(), stdout_writer, stderr_writer) catch |err| {
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

        try stdout_writer.print("{s}: {d}x{d} {d}bpc exp={d} ch={d} icc={d}B\n", .{
            input_path,
            decoded.width,
            decoded.height,
            decoded.bits_per_channel,
            decoded.exponent_bits,
            decoded.channels,
            decoded.icc.len,
        });
        try stdout_writer.flush();

        jxl.encode(decoded, output_path, init.arena.allocator()) catch |err| {
            try stderr_writer.print("error: encode failed for {s}: {s}\n", .{ output_path, @errorName(err) });
            try stderr_writer.flush();
            std.process.exit(1);
        };

        try stdout_writer.print("{s}: ok\n", .{output_path});
        try stdout_writer.flush();
    }
}