// jxc — HDR JXR (and WDP/HDP) to JPEG XL converter.
//
// Modes:
//   jxc <input.jxr>           <output.jxl>               single file (lossless)
//   jxc --distance <f> ...                                  same with quality knob
//   jxc <input-dir/>          <output-dir/>              batch
//
// --distance <float>:
//   1.0   libjxl "visually lossless" HDR (default; safe compression)
//   0.0   lossless HDR (preserves pixels byte-for-byte; pass --distance 0.0)
//   2.0+  increasingly lossy (smaller still)
//   Higher values produce smaller files but with HDR quality loss.

const std = @import("std");
const jxr = @import("jxr.zig");
const jxl = @import("jxl.zig");
const batch = @import("batch.zig");

const usage =
    \\jxc — HDR JXR (and WDP/HDP) to JPEG XL converter
    \\
    \\Usage:
    \\  jxc [--distance <float>] <input.jxr>  <output.jxl>
    \\  jxc [--distance <float>] <input-dir/> <output-dir/>
    \\
    \\--distance controls HDR quality (libjxl Butteraugli distance):
    \\  0.0   lossless (default; preserves pixels byte-for-byte)
    \\  1.0   visually lossless (smaller, still HDR)
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

    // Parse args: optional --distance <f> before positional input/output.
    var distance: f32 = 1.0;
    var positional_start: usize = 1;
    if (args.len >= 4 and std.mem.eql(u8, args[1], "--distance")) {
        distance = std.fmt.parseFloat(f32, args[2]) catch {
            try stderr_writer.print("error: invalid --distance value: {s}\n", .{args[2]});
            try stderr_writer.flush();
            std.process.exit(2);
        };
        if (distance < 0.0) distance = 0.0;
        positional_start = 3;
    }

    if (args.len != positional_start + 2) {
        try stderr_writer.writeAll(usage);
        try stderr_writer.flush();
        std.process.exit(2);
    }

    const input_path = args[positional_start];
    const output_path = args[positional_start + 1];

    if (distance > 0.0) {
        try stdout_writer.print("quality: distance={d}\n", .{distance});
        try stdout_writer.flush();
    }

    if (std.Io.Dir.cwd().openDir(io, input_path, .{})) |_| {
        const summary = batch.run(input_path, output_path, distance, io, init.arena.allocator(), stdout_writer, stderr_writer) catch |err| {
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

        jxl.encode(decoded, output_path, distance, init.arena.allocator()) catch |err| {
            try stderr_writer.print("error: encode failed for {s}: {s}\n", .{ output_path, @errorName(err) });
            try stderr_writer.flush();
            std.process.exit(1);
        };

        try stdout_writer.print("{s}: ok\n", .{output_path});
        try stdout_writer.flush();
    }
}