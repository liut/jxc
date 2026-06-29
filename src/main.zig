// jxc — HDR JXR (and WDP/HDP) to JPEG XL batch converter.
//
// Phase 2 stub: confirms the static build pipeline works. Prints version
// and confirms both translated C modules are importable. The real HDR
// pipeline lands in Phase 3.

const std = @import("std");

// Imported as Zig modules via `addTranslateC` in build.zig. Touching the
// values forces a compile error if translate-c fails — useful sanity
// check that the C interop pipeline works end to end.
const jxrlib = @import("jxrlib");
const jxl = @import("jxl");

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    var stdout_buffer: [4096]u8 = undefined;
    var stdout_file_writer: std.Io.File.Writer = .init(.stdout(), io, &stdout_buffer);
    const stdout_writer = &stdout_file_writer.interface;

    // Touch a constant from each translated module so a missing symbol
    // surfaces here rather than as an opaque linker error.
    try stdout_writer.print("jxc 0.1.0 (dev)\n", .{});
    try stdout_writer.print("jxrlib: GUID_PKPixelFormatDontCare = {{...}}\n", .{});
    try stdout_writer.print("jxl:    JXL_TRANSFER_FUNCTION_PQ = {d}\n", .{jxl.JXL_TRANSFER_FUNCTION_PQ});

    // Reference jxrlib symbols via their address (no-op, but compiler
    // verifies the symbol exists). Suppress unused warnings.
    _ = jxrlib.PK_SDK_VERSION;
    _ = jxl.JXL_ENC_FRAME_SETTING_EFFORT;

    try stdout_writer.flush();
}