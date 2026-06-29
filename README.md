# jxc — HDR JXR (and WDP/HDP) to JPEG XL batch converter

A Zig CLI that batch-converts HDR JPEG XR files to JPEG XL by statically
linking [`4creators/jxrlib`](https://github.com/4creators/jxrlib) (JXR
decoder) and [`libjxl`](https://github.com/libjxl/libjxl) (JXL encoder).
Single binary, runs on Windows / macOS / Linux.

## Why

HDR JXR (`.jxr`, `.wdp`, `.hdp`) is the format Windows uses for HDR
desktop wallpapers. It is essentially unreadable on macOS or Linux, and
existing escape hatches (ImageMagick + libjxr) silently downconvert HDR
to SDR via the TIFF intermediate. jxc preserves HDR end-to-end by:

- Decoding the JXR via jxrlib with the source pixel format preserved
  (16-bit fixed-point, 16-bit half-float, or 32-bit full-float per channel).
- Embedding the source ICC profile in the JXL output when present.
- Falling back to Rec.2020 + PQ color encoding when no ICC is present
  (common for Windows HDR screenshots).
- Lossless JXL encoding for v1 (no quantization artifacts).

## Build

Requires Zig 0.16+, a C/C++ toolchain, CMake, and Make.

```sh
zig build                 # debug
zig build -Doptimize=ReleaseFast
./zig-out/bin/jxc --help
```

The build orchestrates jxrlib (`make`) and libjxl (CMake) as build
steps, then statically links the resulting `.a` archives into a single
executable via `addTranslateC` + `addObjectFile`.

Convenience steps:

```sh
zig build build-jxrlib    # build only the vendored jxrlib
zig build build-libjxl    # build only the vendored libjxl
zig build run             # build + run with arguments
```

## Usage

```sh
# Single file
jxc input.jxr output.jxl

# Batch (recursive directory walk)
jxc /path/to/jxr/dir/ /path/to/jxl/out/
```

Per-file output:

```
/path/to/file.jxr: 3840x2160 32bpc exp=8 ch=4 icc=0B
/path/to/file.jxl: ok
```

Batch summary:

```
--- 3 processed, 2 succeeded, 1 failed ---
Failed:
  /path/to/corrupt.jxr
```

Per-file failures do **not** abort the batch (R6 in the requirements doc).

## Supported input formats

| Input pixel format                       | Width × Height × Channels × Bits |
|------------------------------------------|-----------------------------------|
| `48bppRGBFixedPoint` (16-bit int RGB)    | any × any × 3 × 16                |
| `48bppRGBHalf` (16-bit half-float RGB)   | any × any × 3 × 16                |
| `64bppRGBFixedPoint` (RGBA, 16-bit int) | any × any × 4 × 16                |
| `64bppRGBHalf` (RGBA, 16-bit half-flt)  | any × any × 4 × 16                |
| `128bppRGBFloat` (32-bit float RGB)     | any × any × 3 × 32                |
| `128bppRGBAFloat` (32-bit float RGBA)   | any × any × 4 × 32                |
| Gray variants of the above               | (ch=1)                            |

The 32-bit integer HDR formats (`96bppRGBFixedPoint`,
`128bppRGBAFixedPoint`) are decoded but not currently encoded — libjxl
has no `UINT32` pixel type. These would need a float pre-conversion
step in a future version.

## Verified against

```
$ ./jxc /Users/liutao/Downloads/FINAL\ FANTASY\ VII\ REMAKE\ Screenshot\ *.jxr /tmp/ff7.jxl
.../FINAL FANTASY VII REMAKE Screenshot 2026.06.28 - 22.28.49.83.jxr: 3840x2160 32bpc exp=8 ch=4 icc=0B
/tmp/ff7.jxl: ok

$ file /tmp/ff7.jxl
/tmp/ff7.jxl: JPEG XL container
```

Source: 3840×2160 HDR JXR, 128bppRGBAFloat (32-bit float per channel),
no embedded ICC, 28.8 MB. Output: 59.8 MB lossless HDR JXL (Rec.2020 +
PQ color via fallback).

## Requirements

The binary links the vendored C libraries statically, but transitively
depends on these **system** shared libraries on the dev build:

- `libbrotlienc`, `libbrotlidec`, `libbrotlicommon` (brotli)
- `liblcms2` (lcms2)
- `libhwy` (highway)
- `libSystem` / glibc (OS-provided, always present)

On macOS these are installed by Homebrew (`brew install brotli lcms2 highway`).
On Linux they're in standard distro packages (e.g. `apt install libbrotli-dev
liblcms2-dev libhwy-dev`). On Windows via MSYS2: `pacman -S mingw-w64-x86_64-brotli
mingw-w64-x86_64-lcms2 mingw-w64-x86_64-hwy`.

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

### libjxl

- **`deps.sh`**: removed `set -e` so the testdata download failure
  doesn't abort (testdata is unused since we disable `BUILD_TESTING`).

These patches are minimal and document the upstream bugs we're working
around. They could be submitted upstream or replaced with fork tracking.

## HDR verification (v0 step)

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
├── README.md                            ← you are here
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

## License

MIT — see `LICENSE`.

Vendored libraries retain their own licenses:

- `4creators/jxrlib`: BSD-2-Clause
- `libjxl`: BSD-3-Clause