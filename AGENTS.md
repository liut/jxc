# AGENTS.md

Notes for AI coding agents and contributors working on jxc itself.
End-user docs (what jxc does, how to run it) live in [README.md](./README.md).

## Build orchestration

`build.zig` orchestrates jxrlib (`make`) and libjxl (CMake) as build
steps, then statically links the resulting `.a` archives into a single
executable via `addTranslateC` + `addObjectFile`:

- `addTranslateC` translates the C umbrella headers
  (`src/c/jxrlib_umbrella.h`, `src/c/libjxl_umbrella.h`) into Zig modules.
- `addObjectFile` statically links the prebuilt archives from
  `vendor/jxrlib/build/` and `vendor/libjxl/build/`.

Convenience build steps:

```sh
zig build build-jxrlib    # build only the vendored jxrlib
zig build build-libjxl    # build only the vendored libjxl
zig build run             # build + run with arguments
```

## System build dependencies

The binary links the vendored C libraries statically, but transitively
depends on these **system** shared libraries on the dev build:

- `libbrotlienc`, `libbrotlidec`, `libbrotlicommon` (brotli)
- `liblcms2` (lcms2)
- `libhwy` (highway)
- `libSystem` / glibc (OS-provided, always present)

Install per platform:

- macOS — Homebrew: `brew install brotli lcms2 highway`
- Linux — distro packages: `apt install libbrotli-dev liblcms2-dev libhwy-dev`
- Windows — MSYS2: `pacman -S mingw-w64-x86_64-brotli mingw-w64-x86_64-lcms2 mingw-w64-x86_64-highway`

For a truly static distribution (zero runtime deps), re-vendor brotli,
highway, and lcms2 into `vendor/libjxl/third_party/` and rebuild with the
default flags (drop `JPEGXL_FORCE_SYSTEM_*=ON`). Not implemented yet —
documented as Phase 5 of the plan.

## Vendored source modifications

The 4creators/jxrlib HEAD (commit `f752187`) and libjxl v0.11.2 are
patched locally for build compatibility:

### jxrlib

- **`Makefile` line 68**: added `-fPIC` unconditionally and
  `-Wno-error=implicit-function-declaration -Wno-implicit-function-declaration`.
  Modern macOS Clang treats K&R-style implicit declarations as errors.
- **`jxrgluelib/JXRGlueJxr.c` `FreeDescMetadata`**: removed `assert(FALSE)`
  on unhandled DPKVT types. Real Windows HDR JXR files commonly use
  DPKVT_UI1/BOOL/etc. for descriptive metadata; the original assert
  crashed the decoder on Release.
- **`jxrgluelib/JXRMeta.h` lines 30-54**: added empty-macro fallbacks for
  the 6 SAL tokens jxrlib uses (`__in`, `__out`, `__in_ecount`,
  `__out_ecount`, `__in_win`, `__out_win`) when compiling with non-MSVC
  (GCC, Clang, MinGW). The 4creators fork removed the bundled
  `<windowsmediaphoto.h>` that originally pulled in MSVC's `<sal.h>`, and
  `JXRMeta.h:31`'s `#ifndef WIN32` guard means `wmspecstring.h` is also
  skipped on Windows — so on MinGW, no SAL definitions are in scope at
  all. The fallback block is placed at the top of the header so it
  covers every translation unit that includes `JXRGlue.h`.

### libjxl

- **`deps.sh`**: removed `set -e` so the testdata download failure
  doesn't abort (testdata is unused since we disable `BUILD_TESTING`).

These patches are minimal and document the upstream bugs we're working
around. They could be submitted upstream or replaced with fork tracking.

## v0 verification (HDR decode)

Before the main project was built, a small C program verified that
jxrlib could decode HDR JXR files end-to-end. See `tools/v0_README.md`
and `tools/v0_output.txt` for the verification artifacts.

```sh
make -C vendor/jxrlib clean all
cc -D__ANSI__ -DDISABLE_PERF_MEASUREMENT \
   -Ivendor/jxrlib/common/include -Ivendor/jxrlib/image/sys -Ivendor/jxrlib/jxrgluelib \
   -Wno-error=implicit-function-declaration -Wno-implicit-function-declaration \
   -o tools/v0_decode_test tools/v0_decode_test.c \
   vendor/jxrlib/build/libjxrglue.a vendor/jxrlib/build/libjpegxr.a -lm

./tools/v0_decode_test /path/to/test.jxr
```

## Project layout

```
jxc/
├── README.md                            ← end-user docs
├── AGENTS.md                            ← this file
├── LICENSE                              ← MIT
├── build.zig                            ← build orchestration
├── build.zig.zon                        ← Zig package metadata
├── src/
│   ├── main.zig                         ← CLI entry, mode dispatch
│   ├── jxr.zig                          ← JXR decode via jxrlib
│   ├── jxl.zig                          ← JXL encode via libjxl
│   ├── batch.zig                        ← directory walk + per-file handling
│   └── c/
│       ├── jxrlib_umbrella.h            ← for addTranslateC
│       └── libjxl_umbrella.h            ← for addTranslateC
├── tools/
│   ├── v0_decode_test.c                 ← R10 verification program
│   ├── v0_output.txt                    ← captured output
│   └── v0_README.md                     ← v0 docs
├── vendor/
│   ├── jxrlib/                          ← 4creators fork @ f752187 (patched)
│   └── libjxl/                          ← libjxl v0.11.2 (patched)
└── docs/
    ├── brainstorms/                     ← brainstorm docs
    └── plans/                           ← implementation plan
```