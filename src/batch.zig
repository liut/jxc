// src/batch.zig — directory walk + per-file conversion for batch mode.
//
// Walks an input directory recursively, filters by supported extensions
// (.jxr, .wdp, .hdp), converts each file to a corresponding .jxl file in
// the output directory, logs per-file status, and prints a summary at end.
//
// Per-file failures and skips do NOT abort the batch (R6).
//
// Safe defaults:
//   - If output_path is the same as input_dir, files are converted in place;
//     .jxl files are written next to their .jxr source.
//   - Existing output files are NOT overwritten. The file is skipped with a
//     warning, counted separately in the summary.

const std = @import("std");
const jxr = @import("jxr.zig");
const jxl = @import("jxl.zig");

const SUPPORTED_EXTS = [_][]const u8{ ".jxr", ".wdp", ".hdp" };

const FileResult = enum {
    success,
    failed,
    skipped,
};

pub const BatchSummary = struct {
    total: usize,
    succeeded: usize,
    failed: usize,
    skipped: usize,
    failed_paths: [][]const u8,
    skipped_paths: [][]const u8,
};

pub fn run(
    input_dir: []const u8,
    output_dir: []const u8,
    distance: f32,
    target: jxl.Target,
    io: std.Io,
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) !BatchSummary {
    var failed_paths: std.ArrayList([]const u8) = .empty;
    defer failed_paths.deinit(allocator);
    var skipped_paths: std.ArrayList([]const u8) = .empty;
    defer skipped_paths.deinit(allocator);

    var total: usize = 0;
    var succeeded: usize = 0;
    var failed: usize = 0;
    var skipped: usize = 0;

    var candidates: std.ArrayList([]u8) = .empty;
    defer {
        for (candidates.items) |p| allocator.free(p);
        candidates.deinit(allocator);
    }
    try collectCandidates(io, input_dir, allocator, &candidates);

    // Ensure output directory exists. Skip mkdir if input == output (in-place).
    if (!std.mem.eql(u8, input_dir, output_dir)) {
        var out_path_z = try allocator.allocSentinel(u8, output_dir.len, 0);
        defer allocator.free(out_path_z);
        @memcpy(out_path_z[0..output_dir.len], output_dir);
        const mkdir_result = std.c.mkdir(out_path_z.ptr, 0o755);
        if (mkdir_result != 0) {
            const err = std.c.errno(mkdir_result);
            if (err != std.c.E.EXIST) {
                stderr_writer.print("error: cannot create output dir {s}: errno={d}\n", .{ output_dir, @intFromEnum(err) }) catch {};
                stderr_writer.flush() catch {};
                return error.MakeDirFailed;
            }
        }
    }

    for (candidates.items) |rel_path| {
        total += 1;
        const input_path = try std.fs.path.join(allocator, &[_][]const u8{ input_dir, rel_path });
        defer allocator.free(input_path);
        const output_path = try std.fs.path.join(allocator, &[_][]const u8{ output_dir, rel_path });
        defer allocator.free(output_path);

        const renamed = try rewriteExtToJxl(allocator, output_path);
        defer allocator.free(renamed);

        // Skip if output already exists.
        if (std.Io.Dir.cwd().statFile(io, renamed, .{})) |_| {
            skipped += 1;
            const dup = try allocator.dupe(u8, renamed);
            errdefer allocator.free(dup);
            try skipped_paths.append(allocator, dup);
            stderr_writer.print("{s}: skip (exists): {s}\n", .{ input_path, renamed }) catch {};
            stderr_writer.flush() catch {};
            continue;
        } else |_| {
            // Doesn't exist — proceed.
        }

        const result = convertOne(input_path, renamed, distance, target, allocator, stdout_writer, stderr_writer);
        switch (result) {
            .success => succeeded += 1,
            .failed => {
                failed += 1;
                const dup = try allocator.dupe(u8, input_path);
                errdefer allocator.free(dup);
                try failed_paths.append(allocator, dup);
            },
            .skipped => unreachable, // handled above before convertOne
        }
    }

    try stdout_writer.print("--- {d} processed: {d} succeeded, {d} failed, {d} skipped ---\n", .{ total, succeeded, failed, skipped });
    if (failed > 0) {
        try stdout_writer.writeAll("Failed:\n");
        for (failed_paths.items) |p| {
            try stdout_writer.print("  {s}\n", .{p});
        }
    }
    if (skipped > 0) {
        try stdout_writer.writeAll("Skipped (already exist):\n");
        for (skipped_paths.items) |p| {
            try stdout_writer.print("  {s}\n", .{p});
        }
    }
    try stdout_writer.flush();

    return .{
        .total = total,
        .succeeded = succeeded,
        .failed = failed,
        .skipped = skipped,
        .failed_paths = failed_paths.items,
        .skipped_paths = skipped_paths.items,
    };
}

fn convertOne(
    input_path: []const u8,
    output_path: []const u8,
    distance: f32,
    target: jxl.Target,
    allocator: std.mem.Allocator,
    stdout_writer: *std.Io.Writer,
    stderr_writer: *std.Io.Writer,
) FileResult {
    const decoded = jxr.decode(input_path, allocator) catch |err| {
        stderr_writer.print("{s}: error: decode: {s}\n", .{ input_path, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .failed;
    };
    stdout_writer.print("{s}: {d}x{d} {d}bpc exp={d} ch={d} icc={d}B target={s}\n", .{
        input_path,
        decoded.width,
        decoded.height,
        decoded.bits_per_channel,
        decoded.exponent_bits,
        decoded.channels,
        decoded.icc.len,
        @tagName(target),
    }) catch {};
    stdout_writer.flush() catch {};

    jxl.encode(decoded, output_path, distance, target, allocator) catch |err| {
        stderr_writer.print("{s}: error: encode: {s}\n", .{ output_path, @errorName(err) }) catch {};
        stderr_writer.flush() catch {};
        return .failed;
    };

    stdout_writer.print("{s}: ok\n", .{output_path}) catch {};
    stdout_writer.flush() catch {};
    return .success;
}

fn rewriteExtToJxl(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    const basename = std.fs.path.basename(path);
    const ext = std.fs.path.extension(basename);
    const stem_len = basename.len - ext.len;
    const new_basename = try allocator.alloc(u8, stem_len + 4); // ".jxl"
    defer allocator.free(new_basename);
    @memcpy(new_basename[0..stem_len], basename[0..stem_len]);
    @memcpy(new_basename[stem_len..][0..4], ".jxl");

    const dir = std.fs.path.dirname(path) orelse ".";
    return try std.fs.path.join(allocator, &[_][]const u8{ dir, new_basename });
}

fn collectCandidates(io: std.Io, dir: []const u8, allocator: std.mem.Allocator, out: *std.ArrayList([]u8)) !void {
    var d = std.Io.Dir.cwd().openDir(io, dir, .{ .iterate = true }) catch |err| return err;
    defer d.close(io);

    var walker = try d.walk(allocator);
    defer walker.deinit();

    while (walker.next(io) catch null) |entry| {
        if (entry.kind != .file) continue;
        if (!hasSupportedExt(entry.path)) continue;
        const dup = try allocator.dupe(u8, entry.path);
        try out.append(allocator, dup);
    }
}

const _unused = std.Io.Dir.cwd;

fn hasSupportedExt(path: []const u8) bool {
    for (SUPPORTED_EXTS) |ext| {
        if (std.ascii.endsWithIgnoreCase(path, ext)) return true;
    }
    return false;
}