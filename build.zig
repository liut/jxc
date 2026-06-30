// build.zig — jxc (HDR JXR → JXL batch converter)
//
// Builds jxc as a single statically-linked binary that runs on Windows,
// macOS, and Linux with no codec installation required.
//
// Vendored C libraries:
//   - 4creators/jxrlib (Makefile-based, JPEG XR codec)
//   - libjxl v0.11.2 (CMake-based, JPEG XL codec with HDR support)
//
// The pipeline:
//   1. jxrlib build step  → vendor/jxrlib/build/lib{jpegxr,jxrglue}.a
//   2. libjxl build step → vendor/libjxl/build/lib/libjxl*.a
//   3. addTranslateC for each umbrella header → Zig modules "jxrlib" / "jxl"
//   4. addExecutable → statically links all .a archives + system brotli/lcms2

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});

    // ─────────────────────────────────────────────────────────────────────
    // Step 1: build jxrlib via its patched Makefile.
    //
    // The vendored Makefile is patched (see Phase 1 commit) to:
    //   - force -fPIC (so the .a works with Zig's linker)
    //   - suppress implicit-function-declaration errors (modern Clang is
    //     stricter than the 2017 code expects)
    //
    // The Makefile target that produces both archives is the default `all`.
    // ─────────────────────────────────────────────────────────────────────
    const jxrlib_make = b.addSystemCommand(&.{
        "make", "-j4", "-C", "vendor/jxrlib",
    });
    jxrlib_make.setEnvironmentVariable("CC", "cc");

    const jxrlib_include_paths = &[_]std.Build.LazyPath{
        b.path("vendor/jxrlib/common/include"),
        b.path("vendor/jxrlib/image/sys"),
        b.path("vendor/jxrlib/jxrgluelib"),
    };
    const jxrlib_archive_paths = [_]std.Build.LazyPath{
        b.path("vendor/jxrlib/build/libjpegxr.a"),
        b.path("vendor/jxrlib/build/libjxrglue.a"),
    };

    // ─────────────────────────────────────────────────────────────────────
    // Step 2: build libjxl via CMake (configure + build).
    //
    // The CMake configure step is split from the build step so that the
    // build step can depend on it without re-running configure when nothing
    // has changed. The configure uses flags from the plan (Phase 2.3):
    //   - BUILD_SHARED_LIBS=OFF (produce .a)
    //   - BUILD_TESTING=OFF (skip gtest)
    //   - JPEGXL_ENABLE_FUZZERS/TOOLS/BENCHMARK/EXAMPLES/VIEWERS/PLUGINS=
    //     DOXYGEN/MANPAGES/JNI/SKCMS/SJPEG = OFF (minimal build)
    //   - JPEGXL_FORCE_SYSTEM_BROTLI/HWY/LCMS2 = ON (use MacPorts libs)
    //   - JPEGXL_BUNDLE_LIBPNG = OFF
    // ─────────────────────────────────────────────────────────────────────
    const libjxl_configure = b.addSystemCommand(&.{
        "cmake",
        "-S", "vendor/libjxl",
        "-B", "vendor/libjxl/build",
        "-DCMAKE_BUILD_TYPE=Release",
        "-DBUILD_SHARED_LIBS=OFF",
        "-DBUILD_TESTING=OFF",
        "-DJPEGXL_ENABLE_FUZZERS=OFF",
        "-DJPEGXL_ENABLE_TOOLS=OFF",
        "-DJPEGXL_ENABLE_BENCHMARK=OFF",
        "-DJPEGXL_ENABLE_EXAMPLES=OFF",
        "-DJPEGXL_ENABLE_VIEWERS=OFF",
        "-DJPEGXL_ENABLE_PLUGINS=OFF",
        "-DJPEGXL_ENABLE_DOXYGEN=OFF",
        "-DJPEGXL_ENABLE_MANPAGES=OFF",
        "-DJPEGXL_ENABLE_JNI=OFF",
        "-DJPEGXL_ENABLE_SKCMS=OFF",
        "-DJPEGXL_ENABLE_SJPEG=OFF",
        "-DJPEGXL_FORCE_SYSTEM_BROTLI=ON",
        "-DJPEGXL_FORCE_SYSTEM_HWY=ON",
        "-DJPEGXL_FORCE_SYSTEM_LCMS2=ON",
        "-DJPEGXL_BUNDLE_LIBPNG=OFF",
    });

    const libjxl_build = b.addSystemCommand(&.{
        "cmake", "--build", "vendor/libjxl/build", "-j4",
    });
    libjxl_build.step.dependOn(&libjxl_configure.step);

    const libjxl_include_paths = &[_]std.Build.LazyPath{
        b.path("vendor/libjxl/lib/include"),
        b.path("vendor/libjxl/build/lib/include"),
    };
    const libjxl_archive_paths = [_]std.Build.LazyPath{
        b.path("vendor/libjxl/build/lib/libjxl.a"),
        b.path("vendor/libjxl/build/lib/libjxl_cms.a"),
        b.path("vendor/libjxl/build/lib/libjxl_threads.a"),
    };

    // ─────────────────────────────────────────────────────────────────────
    // Step 3: translate the C headers into Zig modules.
    //
    // The umbrella headers in src/c/ include only what we use. The translate-c
    // step caches output based on input hashes; changes to the umbrella or to
    // the vendored headers trigger re-translation automatically.
    //
    // We pass the vendored include paths explicitly so translate-c finds the
    // headers (some use `<winspecstring.h>`-style angle-bracket includes that
    // resolve via the include search path, not relative paths).
    // ─────────────────────────────────────────────────────────────────────
    const jxrlib_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/jxrlib_umbrella.h"),
        .target = target,
        .optimize = optimize,
    });
    jxrlib_translate.step.dependOn(&jxrlib_make.step);
    inline for (jxrlib_include_paths) |p| jxrlib_translate.addIncludePath(p);
    jxrlib_translate.addIncludePath(b.path("vendor/libjxl/lib/include")); // for compat headers
    // jxrlib's public headers use `__ANSI__` to gate `FAR` macro expansion.
    // The vendored Makefile defines this; we mirror it here for translate-c.
    jxrlib_translate.defineCMacro("__ANSI__", "1");
    jxrlib_translate.defineCMacro("DISABLE_PERF_MEASUREMENT", "1");

    const libjxl_translate = b.addTranslateC(.{
        .root_source_file = b.path("src/c/libjxl_umbrella.h"),
        .target = target,
        .optimize = optimize,
    });
    libjxl_translate.step.dependOn(&libjxl_build.step);
    inline for (libjxl_include_paths) |p| libjxl_translate.addIncludePath(p);

    // ─────────────────────────────────────────────────────────────────────
    // Step 4: build the jxc executable.
    // ─────────────────────────────────────────────────────────────────────
    const exe = b.addExecutable(.{
        .name = "jxc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .link_libcpp = true,
            .imports = &.{
                .{ .name = "jxrlib", .module = jxrlib_translate.createModule() },
                .{ .name = "libjxl", .module = libjxl_translate.createModule() },
            },
        }),
    });

    // Statically link the vendored .a archives.
    const root_mod = exe.root_module;
    inline for (jxrlib_archive_paths) |p| root_mod.addObjectFile(p);
    inline for (libjxl_archive_paths) |p| root_mod.addObjectFile(p);

    // libjxl has transitive dependencies on brotli + lcms2 + hwy (system libs
    // in this dev build; Phase 5 will switch to vendored copies for true
    // static distribution).
    root_mod.linkSystemLibrary("brotlienc", .{});
    root_mod.linkSystemLibrary("brotlidec", .{});
    root_mod.linkSystemLibrary("brotlicommon", .{});
    root_mod.linkSystemLibrary("lcms2", .{});
    root_mod.linkSystemLibrary("hwy", .{});

    b.installArtifact(exe);

    // ─────────────────────────────────────────────────────────────────────
    // Top-level steps.
    // ─────────────────────────────────────────────────────────────────────
    const run_step = b.step("run", "Run jxc");
    const run_cmd = b.addRunArtifact(exe);
    run_step.dependOn(&run_cmd.step);
    run_cmd.step.dependOn(b.getInstallStep());
    if (b.args) |args| run_cmd.addArgs(args);

    const test_step = b.step("test", "Run tests (none yet)");
    _ = test_step;

    // Convenience steps for the C library builds (so devs can iterate on
    // just one library without paying for both).
    const build_jxrlib = b.step("build-jxrlib", "Build vendored jxrlib only");
    build_jxrlib.dependOn(&jxrlib_make.step);

    const build_libjxl = b.step("build-libjxl", "Build vendored libjxl only");
    build_libjxl.dependOn(&libjxl_build.step);
}