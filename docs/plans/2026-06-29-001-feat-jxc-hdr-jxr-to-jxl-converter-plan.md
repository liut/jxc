---
title: feat: Add HDR JXR to JXL batch converter (jxc)
type: feat
status: active
date: 2026-06-29
origin: docs/brainstorms/2026-06-29-jxc-requirements.md
---

# feat: Add HDR JXR to JXL batch converter (jxc)

## Overview

jxc is a Zig CLI that batch-converts HDR JXR files to JPEG XL by statically linking `4creators/jxrlib` (JXR decoder) and `libjxl` (JXL encoder) into a single binary that runs on Windows, macOS, and Linux with no codec installation. The project is gated on a v0 verification step that empirically confirms jxrlib's HDR decode path works before the main pipeline is built — that is the project's defining constraint and central risk.

---

## Problem Statement

HDR JXR (and its WDP/HDP siblings) is the file format Windows uses for HDR desktop wallpapers. Outside Windows, the format is essentially unreadable. Existing escape hatches are broken: ImageMagick's libjxr delegate silently downconverts HDR to SDR via its TIFF intermediate, and Microsoft tools are Windows-only. As a result, users with HDR JXR asset collections cannot use them on macOS or Linux without losing HDR fidelity.

Converting to JPEG XL is the natural fix. JXL has first-class HDR support (PQ/HLG transfer functions, wide gamut) and is widely readable cross-platform. The catch: the obvious library for decoding JXR — `4creators/jxrlib` — declares HDR pixel formats in its API but its real-world HDR decode behavior is unverified and the upstream is frozen at a 2017 spec snapshot. No public project combines jxrlib and libjxl in a single binary's call graph today, and ImageMagick's delegate path confirms the gap (HDR is lost on that path).

jxc fills that gap by combining jxrlib + libjxl in a single CLI pipeline that preserves the source pixel format and ICC profile, end to end.

---

## Proposed Solution

Build a Zig 0.16.0 CLI whose `build.zig` vendors both libraries via `addSystemCommand` (make for jxrlib, CMake for libjxl), translates their public C headers via `addTranslateC` + umbrella headers, and statically links the resulting `.a` archives into a single executable. The HDR conversion pipeline is: jxrlib decodes JXR → raw HDR pixels (with ICC + EXIF extracted) → libjxl encodes JXL with the same ICC embedded and `uses_original_profile = JXL_TRUE`. v0 verification of jxrlib's HDR decode path is a hard precondition before the main pipeline is built.

Per-host native build of the C libraries (one machine per target OS) is the chosen distribution strategy because the project scope is "personal use + informal sharing" — no CI matrix, no cross-compilation of C code.

---

## Technical Approach

### Architecture

```
┌──────────────────────────────────────────────────────────────────┐
│                         jxc (Zig binary)                         │
│                                                                  │
│   src/main.zig          CLI entry, arg parsing, mode dispatch    │
│         │                                                        │
│         ▼                                                        │
│   src/batch.zig         Directory iteration, error aggregation   │
│         │                                                        │
│         ▼                                                        │
│   src/jxr.zig ──► @import("jxrlib") ──► 4creators/jxrlib (.a)    │
│       (decode)    JXRGlue.h                                       │
│                                                                  │
│         │ raw HDR pixels + ICC + EXIF                            │
│         ▼                                                        │
│   src/jxl.zig ──► @import("jxl") ─────► libjxl (.a)              │
│       (encode)    jxl/encode.h                                    │
│                                                                  │
└──────────────────────────────────────────────────────────────────┘

Build pipeline (build.zig):
  1. make -C vendor/jxrlib SHARED=1           → vendor/jxrlib/build/lib{jpegxr,jxrglue}.a
  2. cmake configure + build vendor/libjxl    → 7 static archives (jxl + threads + hwy + brotli*)
  3. addTranslateC on each umbrella header    → Zig modules "jxrlib" and "jxl"
  4. addObjectFile for all .a archives        → exe links them statically
  5. link_libc + link_libcpp = true           → C + C++ runtime
```

### Implementation Phases

#### Phase 1: v0 HDR verification (R10, BLOCKING PRECONDITION)

**Goal:** Empirically confirm `4creators/jxrlib` actually decodes HDR JXR files end-to-end. If this phase fails, the main project does not start — we revisit Approach C (Microsoft original ref impl / ffmpeg `libavcodec` JXR / fork fix) before writing any CLI code.

**Tasks:**
1. Vendor `4creators/jxrlib` at HEAD `f752187`:
   - `git clone https://github.com/4creators/jxrlib.git vendor/jxrlib` (or submodule).
2. Build on dev host:
   - `make -C vendor/jxrlib SHARED=1` (the `SHARED=1` flag forces `-fPIC` — see Risks below for why this matters).
   - Confirm `vendor/jxrlib/build/libjpegxr.a` and `vendor/jxrlib/build/libjxrglue.a` exist.
3. Obtain a known HDR JXR test file:
   - Easiest source: a Windows HDR desktop wallpaper (`.jpg`/`.jxr` in `C:\Windows\Web\Wallpaper\HDR\` or saved from `Personalize → Desktop Background → Windows Spotlight HDR`).
   - Confirm via `file input.jxr` that it reports "JPEG XR" data; size should be a few MB.
4. Write a small C program `tools/v0_decode_test.c`:
   - Include `JXRGlue.h`.
   - Open the test file via `PKCodecFactory::CreateDecoderFromFile`.
   - Read `GetSize` (width, height), `GetPixelFormat` (GUID), `GetColorContext` (ICC bytes, size).
   - Set up `PKFormatConverter` with **the source pixel format directly** (`PixelFormatLookup(LOOKUP_FORWARD)` may rewrite the GUID to a non-HDR preferred format — verify after `Initialize` that the source GUID is preserved).
   - Allocate output buffer via `PKAllocAligned` (not `malloc` — SIMD alignment matters for some HDR formats).
   - Copy pixels, dump stats: width/height, pixel format GUID as string, ICC size + first 16 bytes hex, pixel mean/min/max for one channel.
5. Compile and run against the test file.
6. Verify three things:
   - File decodes (no error).
   - Pixel format is HDR: one of `GUID_PKPixelFormat48bppRGBFixedPoint`, `GUID_PKPixelFormat48bppRGBHalf`, `GUID_PKPixelFormat96bppRGBFixedPoint`, `GUID_PKPixelFormat128bppRGBFloat` (or 64bpp half/float variants with alpha).
   - ICC profile is non-empty and has a sane size (> 100 bytes — Windows HDR ICCs are typically a few KB).
7. Save outputs: `tools/v0_decode_test.c`, the test file (or a 1-2 sample of test files), and a `tools/v0_output.txt` capturing the expected stats.

**Exit criteria:** v0 verification produces a confirmed HDR decode with non-empty ICC. If the pixel format comes back as a non-HDR GUID (e.g., `48bppRGB` integer), or decode errors out, or ICC is empty: **STOP**. Document the failure mode and revisit fallback options before proceeding.

**Estimated effort:** 2-4 hours.

---

#### Phase 2: Vendor libjxl + `build.zig` static linking

**Goal:** A `build.zig` that produces a jxc binary that statically links jxrlib and libjxl. Stub `src/main.zig` that just prints a version string. Build cleanly on the dev host.

**Tasks:**
1. `zig init` to bootstrap project structure (`build.zig`, `build.zig.zon`, `src/root.zig` → rename to `src/main.zig`).
2. Vendor `libjxl`:
   - `git clone --depth 1 --branch v0.11.2 https://github.com/libjxl/libjxl.git vendor/libjxl` (pin to a specific release for reproducibility).
3. Write `src/c/jxrlib_umbrella.h`:
   ```c
   #include <JXRGlue.h>
   #include <JXRMeta.h>
   ```
4. Write `src/c/libjxl_umbrella.h`:
   ```c
   #include <jxl/encode.h>
   #include <jxl/codestream_header.h>
   #include <jxl/color_encoding.h>
   #include <jxl/types.h>
   #include <jxl/parallel_runner.h>
   #include <jxl/thread_parallel_runner.h>
   ```
5. In `build.zig`:
   - `b.addSystemCommand(&.{ "make", "-C", "vendor/jxrlib", "SHARED=1" })` — produces `.a` archives.
   - `b.addSystemCommand` for CMake configure:
     ```
     cmake -S vendor/libjxl -B vendor/libjxl/build
       -DCMAKE_BUILD_TYPE=Release
       -DBUILD_SHARED_LIBS=OFF
       -DBUILD_TESTING=OFF
       -DJPEGXL_ENABLE_FUZZERS=OFF
       -DJPEGXL_ENABLE_TOOLS=OFF
       -DJPEGXL_ENABLE_BENCHMARK=OFF
       -DJPEGXL_ENABLE_EXAMPLES=OFF
       -DJPEGXL_ENABLE_VIEWERS=OFF
       -DJPEGXL_ENABLE_PLUGINS=OFF
       -DJPEGXL_ENABLE_DOXYGEN=OFF
       -DJPEGXL_ENABLE_MANPAGES=OFF
       -DJPEGXL_ENABLE_JNI=OFF
     ```
   - `b.addSystemCommand(&.{ "cmake", "--build", "vendor/libjxl/build", "-j" })` chained after configure.
   - `b.addTranslateC` for each umbrella header with `addIncludePath` for the vendored include dirs. Mark them `dependOn` the relevant C lib build step so cache invalidation works.
   - `b.addExecutable` with `root_module.link_libc = true` and `root_module.link_libcpp = true` (libjxl needs the C++ runtime).
   - `addObjectFile` for all 8 static archives:
     - `vendor/jxrlib/build/libjpegxr.a`
     - `vendor/jxrlib/build/libjxrglue.a`
     - `vendor/libjxl/build/lib/libjxl.a`
     - `vendor/libjxl/build/lib/libjxl_cms.a`
     - `vendor/libjxl/build/lib/jxl_threads/libjxl_threads.a` (path may vary — verify after first build)
     - `vendor/libjxl/build/third_party/highway/libhwy.a`
     - `vendor/libjxl/build/third_party/brotli/libbrotlienc.a`
     - `vendor/libjxl/build/third_party/brotli/libbrotlidec.a`
     - `vendor/libjxl/build/third_party/brotli/libbrotlicommon.a`
6. Replace `src/main.zig` with a stub that imports both translated modules and prints `jxc 0.1.0`:
   ```zig
   const std = @import("std");
   const jxrlib = @import("jxrlib");
   const jxl = @import("jxl");
   pub fn main() !void {
       _ = jxrlib;
       _ = jxl;
       std.debug.print("jxc 0.1.0\n", .{});
   }
   ```
7. `zig build` and confirm the binary runs and prints the version string. Verify with `nm` or `otool -L` that libc/libstdc++ are the only dynamic deps.

**Exit criteria:** Clean build, version-printing binary runs, no unresolved symbols.

**Estimated effort:** 4-8 hours.

---

#### Phase 3: HDR conversion pipeline (single file)

**Goal:** `jxc input.jxr output.jxl` produces a viewable HDR JXL with the source ICC preserved.

**Tasks:**
1. Implement `src/jxr.zig`:
   - Wrap `PKFactory`/`PKCodecFactory`/`PKImageDecode`/`PKFormatConverter` lifecycle.
   - Read width/height, pixel format GUID, ICC bytes (two-call pattern: `GetColorContext(NULL, &size)` then `GetColorContext(buf, &size)`).
   - Optional: read EXIF via `GetEXIFMetadata_WMP` (two-call pattern). Remember the **4-byte TIFF header offset quirk**: when passing to libjxl's `JxlEncoderAddBox("Exif", ...)`, prepend 4 zero bytes if the source EXIF doesn't already have a TIFF offset header.
   - Build a `src/pixel_format.zig` mapping table from jxrlib GUIDs to `{ num_channels, data_type, bits_per_sample, exponent_bits_per_sample }` for libjxl (see Risks / decision table).
   - Use `GUID_PKPixelFormatDontCare` for the format converter's output to preserve the source format (do **not** let `PixelFormatLookup` rewrite the GUID).
   - Allocate the pixel buffer via a Zig wrapper around `PKAllocAligned` (declared in JXRGlue.h) — do not use Zig's general-purpose allocator here, SIMD alignment matters for some platforms.
2. Implement `src/jxl.zig`:
   - `JxlEncoderCreate(NULL)` + `JxlEncoderSetParallelRunner(enc, NULL, NULL)` (single-threaded for v1; threading is a v2 concern).
   - Build `JxlBasicInfo`:
     - `xsize`, `ysize` from jxrlib.
     - `bits_per_sample` per the mapping table.
     - `exponent_bits_per_sample` per the mapping table (0 for fixed-point, 5 for half-float, 8 for full-float).
     - `num_color_channels = 3` (or `1` for gray).
     - `num_extra_channels = 1` (with appropriate `alpha_bits`/`alpha_exponent_bits`) if source had alpha.
     - `uses_original_profile = JXL_TRUE`.
     - `intensity_target = 0` (let libjxl infer from encoding).
   - If ICC was extracted: `JxlEncoderSetICCProfile(enc, icc_ptr, icc_size)`. **Fallback path**: if libjxl returns `JXL_ENC_ERR_BAD_INPUT` (some Windows HDR ICC profiles are non-conformant), construct a `JxlColorEncoding` with `JXL_PRIMARIES_2100`, `JXL_TRANSFER_FUNCTION_PQ`, `JXL_WHITE_POINT_D65`, `JXL_RENDERING_INTENT_RELATIVE`, and call `JxlEncoderSetColorEncoding` instead.
   - `JxlEncoderFrameSettingsCreate(enc, NULL)` + `JxlEncoderSetFrameLossless(fs, JXL_TRUE)` (lossless HDR for v1 — preserves the source bytes exactly).
   - `JxlPixelFormat { .num_channels = N, .data_type = JxlDataType, .endianness = JXL_LITTLE_ENDIAN, .align = 0 }`.
   - `JxlEncoderAddImageFrame(fs, &pf, pixel_buf, pixel_buf_size)`.
   - `JxlEncoderCloseInput(enc)` + drain via `JxlEncoderProcessOutput` in a loop writing chunks to a `std.fs.File` writer.
   - Cleanup.
3. Wire `src/main.zig`:
   - Parse args: reject if `argc != 3`; print usage and exit non-zero.
   - Single-file mode: open input, run jxr.zig → run jxl.zig → close.
   - On any jxrlib error: print `error: decode failed: <path>: <zig error name>` to stderr, exit non-zero.
4. Test against the v0 test file plus 1-2 additional HDR JXR samples spanning different pixel formats (16bpp fixed point, half-float, full-float) if available.
5. Verify outputs:
   - File exists, non-empty.
   - Open in Chrome (`chrome://flags/#jpeg-xl` if needed) or GIMP — image renders with HDR.
   - `exiftool output.jxl` shows ICC profile present and matching size of source (within 0-2 bytes; libjxl may normalize).

**Exit criteria:** AE1 from origin doc passes. All three target HDR pixel formats work (or document which ones do not, per Approach C fallback).

**Estimated effort:** 6-12 hours.

---

#### Phase 4: Batch mode (directory)

**Goal:** `jxc input-dir/ output-dir/` recursively converts all `.jxr`/`.wdp`/`.hdp` files, logging per-file result and emitting a summary.

**Tasks:**
1. Add `src/batch.zig`:
   - `std.fs.cwd().openDir(input_dir, .{ .iterate = true })`.
   - Walk with `dir.iterate()` recursively (or use `std.fs.walk`).
   - Filter by extension (case-insensitive: `.jxr`, `.wdp`, `.hdp`).
   - For each file: compute output path (`output_dir/<basename>.jxl`), call single-file conversion logic.
   - On success: print `<input>: ok`, increment success counter.
   - On failure: print `<input>: error: <message>` to stderr, add path to failed list, increment failure counter. **Do not abort the batch** (R6).
   - At end: print `--- <total> processed, <ok> succeeded, <fail> failed ---`. If `fail > 0`, print `Failed:` followed by each failed path on its own line.
2. Update `src/main.zig` arg parsing:
   - `jxc input output` where input is a file → single-file mode (Phase 3).
   - `jxc input-dir output-dir` where input is a directory → batch mode.
   - Detect via `std.fs.cwd().statFile(input)` and switch on the kind.
3. Test against AE2 (100-file directory with 3 corrupt files) and AE3 (mid-batch failure) from the origin doc.

**Exit criteria:** AE2, AE3 pass.

**Estimated effort:** 4-6 hours.

---

#### Phase 5: Per-platform builds + README + distribution

**Goal:** Three platform binaries ready for personal use + informal sharing. README documents the build.

**Tasks:**
1. **macOS (primary dev host):** Already building. Confirm ReleaseFast build produces a working binary. Test with a real HDR JXR file.
2. **Linux:** If a Linux host (or VM) is available, build there. Otherwise document expected command:
   ```
   zig build -Dtarget=x86_64-linux-gnu -Doptimize=ReleaseFast
   ```
   Test on a Linux host before sharing.
3. **Windows:** Two options, try in order:
   - **Option A (preferred):** Build on Windows via MSYS2/UCRT64 with Zig installed. Run `zig build -Dtarget=x86_64-windows-gnu`. Note: MinGW static linking has known quirks; if linkage errors arise, check the v0 step's Windows test result and consider whether `zig cc` cross-compile from macOS is viable (see Risks).
   - **Option B (fallback):** Attempt `zig build -Dtarget=x86_64-windows-gnu` from macOS host, passing `zig cc` as the C/C++ compiler to CMake. This may or may not work for libjxl (CMake + `zig cc` is documented to work for many projects but not all). If it fails, document the Windows requirement as "must build on Windows" in README.
4. Write `README.md`:
   - One-line project description (HDR JXR → JXL, cross-platform, single binary).
   - HDR verification status (link to `tools/v0_output.txt` from Phase 1).
   - Supported input extensions: `.jxr`, `.wdp`, `.hdp`.
   - Supported HDR pixel formats (confirmed by v0).
   - Build commands per platform.
   - Usage examples:
     ```
     jxc input.jxr output.jxl
     jxc input-dir/ output-dir/
     ```
   - Limitations: no SDR-only mode, no quality tuning, single-threaded.
   - License.
5. Write `LICENSE` (MIT recommended for personal CLI tool — permissive, compatible with both vendored libraries' BSD-2 / BSD-3 licenses).
6. Write `.gitignore` (standard Zig template — `.zig-cache/`, `zig-out/`, `zig-pkg/`, plus `vendor/` if submodules, plus the typical `.DS_Store`).
7. Decide on git submodule vs. plain `vendor/` directory:
   - **Submodules:** reproducible, explicit. Downside: receivers of the binary don't need them, but the source repo does.
   - **Plain vendor/:** simpler for the user; downside: harder to update.
   - Recommendation: submodules (matches what `4creators/jxrlib` and `libjxl` upstream expect for their own builds, and keeps `git diff` clean).

**Exit criteria:** `jxc --version` works on each of the three target platforms via the documented build command. README accurate.

**Estimated effort:** 4-8 hours.

---

## Alternative Approaches Considered

- **Dynamic linking (Approach B from brainstorm):** Rejected. `jxrlib` has no good Windows package; dynamic linking would break the cross-platform zero-install promise (R7–R9).
- **Cross-compiling the C libraries from one host (via `zig cc`):** Considered but not chosen as the default. Per-host native build is simpler and more reliable for a personal project without CI. Could be revisited if Windows-host access is impossible.
- **Microsoft original `JXRDecApp` + ImageMagick pipeline:** Rejected — ImageMagick's JXR delegate silently downconverts HDR to SDR (confirmed by reading `delegates.xml.in` and `JxrDecApp.c`); does not meet R1.
- **Rust with `cxx` bindings:** Considered but rejected — Zig was chosen for `@cImport`/translate-c simplicity, native cross-compilation, and matching the workspace's existing Zig footprint. No Rust project bundles both jxrlib and libjxl today; Zig is no worse off.
- **Go with `cgo`:** Rejected — distribution size and lack of good JXR bindings.
- **Python with `imagecodecs`:** Rejected — distribution story for a CLI is bad (PyInstaller overhead), and `imagecodecs` does not preserve HDR through its decode path.

---

## System-Wide Impact

### Interaction Graph

The jxc pipeline is a straight-through data flow with no callbacks or observers:

1. CLI arg parse → `src/main.zig` dispatches to `single.zig` or `batch.zig`.
2. `batch.zig` walks filesystem → for each file, calls `single.zig`.
3. `single.zig` calls `jxr.zig` (decode) → `jxl.zig` (encode) → file write.
4. Inside jxrlib: `PKCodecFactory` → `PKImageDecode` → `PKFormatConverter` (linear synchronous chain, no user callbacks).
5. Inside libjxl: `JxlEncoder` → `JxlBasicInfo` setup → `JxlEncoderAddImageFrame` → drain loop. Parallel runner is `NULL` for v1 (single-threaded).

No event subscriptions, no middleware, no observers. Tracing is via `std.log.debug` for development and stderr for user-facing errors.

### Error & Failure Propagation

| Failure source | Error class | Handling |
|---|---|---|
| File not found / permission | `error.FileNotFound`, `error.AccessDenied` | Print to stderr, exit non-zero (single-file mode). In batch: log + skip. |
| jxrlib decode returns `WMP_errFail` | `error.JxrDecodeFailed` | Same as above. |
| jxrlib reports non-HDR pixel format | `error.UnsupportedPixelFormat` | Print detected format GUID, suggest manual tool (TBD). Skip in batch. |
| ICC extraction returns 0 bytes | (not an error) | Skip `JxlEncoderSetICCProfile`, fall through to `JxlColorEncoding` with Rec.2020+PQ if it was an HDR-format file. |
| libjxl `JXL_ENC_ERR_BAD_INPUT` on ICC | `error.JxlIccRejected` | Construct `JxlColorEncoding` with explicit Rec.2020 + PQ, retry via `JxlEncoderSetColorEncoding`. If that also fails, abort file with `error.JxlEncodeFailed`. |
| libjxl `JXL_ENC_ERR_*` other | `error.JxlEncodeFailed` | Print, skip in batch. |
| Output file not writable | `error.FileNotFound`, etc. | Same as input. |
| OOM during buffer allocation | `error.OutOfMemory` | Propagate as fatal; exit non-zero (no partial-batch semantics for OOM). |

No retries. The C library APIs do not document retry semantics for decode/encode failures, and per-file failures in batch mode are intentional skip-and-report (R6).

### State Lifecycle Risks

No persistent state. No database, no temp files, no caches. The only state during execution is the in-memory pixel buffer, allocated once per file and freed after the JXL encode completes. If jxc is killed mid-file, no partial state is left behind. If killed mid-batch, files already written are valid JXL (each is atomic from the perspective of the writer).

No orphan rows, no stale caches, no cleanup mechanisms needed.

### API Surface Parity

Single CLI surface with two modes (file, directory) and one shared conversion pipeline. No subcommands, no global flags besides `-h/--help` (suggested for v1) and `-V/--version`. No HTTP API, no library API. Internal Zig modules (`jxr.zig`, `jxl.zig`, `batch.zig`, `pixel_format.zig`) are not exposed as a library for v1 — they are private to the binary.

### Integration Test Scenarios

End-to-end tests (will live in `tests/` as `zig build test` integration, or a manual test script in `tools/`):

1. **v0 round-trip:** Decode a known HDR JXR via `jxrlib` → re-encode via `libjxl` → confirm pixel buffer is byte-identical (lossless frame setting, `uses_original_profile = JXL_TRUE`).
2. **ICC preservation:** Decode JXR with Rec.2020 + PQ ICC → encode JXL → extract ICC from JXL → confirm size and header bytes match (within 0-2 byte delta).
3. **AE1 from origin doc:** Specific known HDR JXR file → specific expected JXL output (visual + ICC verification).
4. **AE2 / AE3 from origin doc:** 100-file batch with 3 corrupt inputs → 97 succeed, summary correct, no abort.
5. **AE4 from origin doc:** Binary on a fresh OS install (docker container with no dev tools) → runs without setup.
6. **Cross-platform binary smoke:** Build on macOS, run on Linux via a Linux VM/container (or document expected run).
7. **EXIF round-trip (if implemented):** JXR with EXIF → JXL with same EXIF (with the 4-byte TIFF offset quirk handled).

---

## Acceptance Criteria

### Functional Requirements

- [ ] **AC1 (R1):** v0 verification confirms `4creators/jxrlib` decodes at least one HDR pixel format (16bpp fixed point, half-float, or full-float) end-to-end. Captured in `tools/v0_output.txt`.
- [ ] **AC2 (R2):** Single-file `jxc input.jxr output.jxl` produces a JXL whose ICC profile matches the source ICC (size + first 16 bytes hex match). Verifiable via `exiftool` or equivalent.
- [ ] **AC3 (R3):** Input accepts `.jxr`, `.wdp`, `.hdp` extensions.
- [ ] **AC4 (R4, R5):** `jxc input-dir/ output-dir/` recursively converts all files matching the supported extensions.
- [ ] **AC5 (R6):** Per-file failure does not abort the batch; failed paths are listed in the final summary.
- [ ] **AC6 (R7, R8):** The compiled binary runs on Windows, macOS, and Linux with no library installation.
- [ ] **AC7 (R9):** `build.zig` builds jxrlib via `make SHARED=1` and libjxl via CMake with the flags listed in Phase 2, then statically links both into a single binary.
- [ ] **AC8 (R10):** v0 verification output is committed before the main pipeline is built.
- [ ] **AC9 (R11):** Per-file progress line during batch: `<path>: ok` or `<path>: error: <message>`.
- [ ] **AC10 (R12):** Final batch summary: `--- <N> processed, <OK> succeeded, <FAIL> failed ---` plus a `Failed:` list when `FAIL > 0`.

### Non-Functional Requirements

- [ ] **NFR1:** Convert a 4K (3840×2160) HDR JXR file in under 5 seconds on a 2020+ MacBook Pro.
- [ ] **NFR2:** Peak memory under 200MB for a 4K HDR image (one buffer in memory at a time).
- [ ] **NFR3:** Single-binary size under 30MB per platform (ReleaseFast).
- [ ] **NFR4:** Build time (incremental, no C lib rebuild): under 10 seconds. Build time (clean, with C lib rebuild): under 5 minutes on a 2020+ MacBook Pro.

### Quality Gates

- [ ] All 5 Acceptance Examples from origin doc pass on the dev host (macOS).
- [ ] At least 3 of the 5 AEs verified on Linux and Windows builds.
- [ ] No `TODO`/`FIXME`/`XXX` left in the production code paths (lib code only).
- [ ] `zig build test` passes (any unit tests written; integration tests live in `tools/` as standalone scripts).
- [ ] README is accurate (build commands actually work on each documented platform).

---

## Success Metrics

- 100% of HDR JXR files in a representative Windows HDR wallpaper sample convert successfully to viewable HDR JXL.
- Converted JXL files preserve the source ICC profile (verifiable via `exiftool`).
- v0 verification step confirms jxrlib HDR decode works before any CLI code is written.
- The compiled binary runs from a fresh OS install on each of the three target platforms with no library installation step.
- A known-person recipient can run the binary on their machine after the README's build instructions.

---

## Dependencies & Prerequisites

**Tooling:**
- Zig 0.16.0+ (verified installed at `/opt/local/bin/zig` on dev host).
- A C toolchain on each build host:
  - macOS: Xcode Command Line Tools (clang, ar, ranlib).
  - Linux: gcc or clang.
  - Windows: MSYS2/UCRT64 with `make` and a working gcc (MinGW).
- CMake (for libjxl build; available via `brew install cmake` on macOS, `apt install cmake` on Linux, MSYS2 package on Windows).
- `git` for vendoring.

**Test data:**
- At least one HDR JXR file (Windows HDR wallpaper, sourced from a Windows installation or downloaded). Ideally one sample per supported HDR pixel format.

**Vendored source (pinned):**
- `4creators/jxrlib` at HEAD `f752187` (or whatever is HEAD at plan-execution time).
- `libjxl` at tag `v0.11.2`.

**Licenses:**
- `4creators/jxrlib` is BSD-2-Clause.
- `libjxl` is BSD-3-Clause.
- Both are permissive and compatible with each other and with jxc's own license (MIT recommended).

---

## Risk Analysis & Mitigation

| Risk | Probability | Impact | Mitigation |
|---|---|---|---|
| **v0 verification fails (jxrlib HDR decode broken)** | Medium | High — blocks main project | Phase 1 is structured to detect this fast. Fallback: Approach C (Microsoft original / ffmpeg / fork fix). Stop and revisit before Phase 2. |
| **jxrlib default Makefile omits `-fPIC` on macOS** | High (if missed) | Medium — linker errors / runtime crashes | Phase 2 explicitly passes `SHARED=1` to force `-fPIC`. |
| **`PixelFormatLookup(LOOKUP_FORWARD)` rewrites HDR GUID to SDR** | Medium | High — HDR silently lost | Phase 3 v0 explicitly verifies the GUID after Initialize; skip `PixelFormatLookup` if it changes the GUID. |
| **`zig cc` cannot cross-compile libjxl for Windows from macOS** | Medium | Medium — Windows build must happen on Windows host | Phase 5 Option A: build on Windows via MSYS2. Document the requirement in README if cross-compile fails. |
| **Windows HDR JXR ICC profile is non-conformant; libjxl rejects it** | Medium (reported in some Windows HDR wallpapers) | Medium — file fails to encode | Phase 3 fallback: construct `JxlColorEncoding` with explicit Rec.2020 + PQ. |
| **EXIF round-trip needs 4-byte TIFF offset prepended** | High if EXIF is implemented | Low — wrong EXIF in output | Phase 3 documents the quirk; prepend 4 zero bytes when needed. |
| **Static link order matters for libjxl + brotli + hwy** | Low (with `-Wl,--start-group` equivalent) | Medium — linker errors | Phase 2 lists all 8 archives in dependency order. If errors arise, wrap in a `Step` that emits a `-Wl,--start-group ... -Wl,--end-group` linker flag via the Zig build API. |
| **Output binary too large** | Low | Low | If > 30MB, strip with `strip zig-out/bin/jxc` post-build. Investigate `JPEGXL_ENABLE_SKCMS=OFF` if lcms2 is the bulk. |
| **Per-host build requires three machines** | Inherent | Inherent | Documented in README as "build per platform, share binaries." Acceptable for personal-use scope. |

---

## Resource Requirements

- **Time:** ~20-40 hours of focused work over 1-2 weeks (single contributor).
- **Storage:** ~500MB for vendored source (`libjxl` is ~300MB with git history; `jxrlib` is small; build artifacts add ~1GB transient).
- **Hardware access:** macOS dev machine (have), Linux host (need access to a VM, container, or physical machine), Windows host (need MSYS2 environment on Windows).
- **No external services:** No CI, no registry, no API keys, no telemetry.

---

## Future Considerations (Out of v1 Scope)

- SDR-only fallback path (for non-HDR JXR files — currently the project intentionally errors).
- Lossy compression mode with quality knob (`JxlEncoderSetFrameDistance(fs, 1.0)` etc.).
- Recursive glob patterns (`jxc "input/**/*.jxr" out/`).
- Watch-folder mode (auto-convert on file add).
- Multi-threaded batch via Zig `std.Thread.Pool` and libjxl's parallel runner.
- GUI viewer (Windows-only via WIC, or cross-platform via libjxl + a UI framework).
- Publishing the project on GitHub with full CI matrix (zmdr's `.github/workflows/release.yml` is a template, but deferred per distribution scope).
- JPEG XR encoding (JXL → JXR) — explicitly out of scope per origin doc.
- Other input formats (AVIF, HEIF, WebP) — explicitly out of scope.
- Documenting the jxrlib+libjxl pattern in `docs/solutions/` so future Zig projects in the workspace can reuse the build.zig idiom (via `/ce:compound`).

---

## Documentation Plan

- **`README.md`:** Project overview, HDR verification status (link to `tools/v0_output.txt`), supported input extensions and pixel formats, build commands per platform (macOS / Linux / Windows), usage examples, limitations, license.
- **`LICENSE`:** MIT (recommended for personal CLI tool; compatible with both vendored libraries).
- **Inline doc comments:** On public functions in `src/jxr.zig`, `src/jxl.zig`, `src/batch.zig` (Zig's doc-comment syntax `///`). Not used for `src/main.zig` (trivial).
- **No formal docs site, no Sphinx, no mkdocs.** The scope is "personal use + informal sharing" — README is sufficient.
- **`tools/v0_decode_test.c` + `tools/v0_output.txt`:** Captured evidence from Phase 1, referenced from README.

---

## Sources & References

### Origin

- **Origin document:** [docs/brainstorms/2026-06-29-jxc-requirements.md](../brainstorms/2026-06-29-jxc-requirements.md) — the WHAT behind this plan. Key decisions carried forward:
  - Language: Zig (best C interop, single static binary, matches workspace)
  - Build strategy: vendored static linking (rejected dynamic because jxrlib has no good Windows package)
  - v0 verification step is a hard precondition (R10)
  - ICC profile preservation is the only v1 behavior (no strip option)
  - Distribution scope: personal use + informal sharing (no CI, no public release)
  - HDR is non-negotiable (no SDR-only fallback path)

### External References

**Zig 0.16:**
- [Zig 0.16.0 release notes](https://ziglang.org/download/0.16.0/release-notes.html) — `@cImport` deprecation, `addTranslateC` guidance
- [Build system reference](https://ziglang.org/learn/build-system/) — standard `target`/`optimize` options
- [Tracking issue: @cImport moving to build system](https://github.com/ziglang/zig/issues/20630)
- Real-world `addTranslateC` examples:
  - [apache/opendal/bindings/zig/build.zig](https://github.com/apache/opendal/blob/main/bindings/zig/build.zig)
  - [nDimensional/zig-sqlite/build.zig](https://github.com/nDimensional/zig-sqlite)
  - [jedisct1/libsodium/build.zig](https://github.com/jedisct1/libsodium)
- Real-world `addSystemCommand` + `addObjectFile` examples:
  - [lucascompython/particle-simulation-2d/build.zig](https://github.com/lucascompython/particle-simulation-2d) (closest to jxrlib pattern)
  - [unicorn-engine/unicorn/build.zig](https://github.com/unicorn-engine/unicorn)

**Cross-compilation:**
- [Stack Overflow Q&A with Loris Cro (Zig cross-compile)](https://stackoverflow.blog/2023/10/02/no-surprises-on-any-system-q-and-a-with-loris-cro-of-zig/)
- [MinGW vs MSVC for Windows targets](https://ziggit.dev/t/cross-compiling-for-windows-what-is-the-difference-between-gnu-and-msvc/6692)
- [MSVC from Linux feasibility](https://ziggit.dev/t/can-i-link-binaries-produced-using-msvc-to-zig-executable-targeting-gnu/9448)

**libjxl:**
- [libjxl repository](https://github.com/libjxl/libjxl) — latest release v0.11.2 (2026-02-10)
- [Main CMakeLists.txt](https://github.com/libjxl/libjxl/blob/main/CMakeLists.txt)
- [lib/CMakeLists.txt](https://github.com/libjxl/libjxl/blob/main/lib/CMakeLists.txt)
- [Encoder API: jxl/encode.h](https://github.com/libjxl/libjxl/blob/main/lib/include/jxl/encode.h)
- [Codestream header: jxl/codestream_header.h](https://github.com/libjxl/libjxl/blob/main/lib/include/jxl/codestream_header.h)
- [Color encoding: jxl/color_encoding.h](https://github.com/libjxl/libjxl/blob/main/lib/include/jxl/color_encoding.h)
- [Types: jxl/types.h](https://github.com/libjxl/libjxl/blob/main/lib/include/jxl/types.h)
- [Parallel runner: jxl/parallel_runner.h](https://github.com/libjxl/libjxl/blob/main/lib/include/jxl/parallel_runner.h)
- [Reference encoder CLI: cjxl_main.cc](https://github.com/libjxl/libjxl/blob/main/tools/cjxl_main.cc)
- [C++ extras encoder: jxl.cc](https://github.com/libjxl/libjxl/blob/main/lib/extras/enc/jxl.cc)
- [Static linking gotcha (issue #2851)](https://github.com/libjxl/libjxl/issues/2851)

**4creators/jxrlib:**
- [4creators/jxrlib repository](https://github.com/4creators/jxrlib) — HEAD `f752187`, last tag v2019.10.9
- [JXRGlue.h](https://github.com/4creators/jxrlib/blob/master/jxrgluelib/JXRGlue.h)
- [JXRGlue.c](https://github.com/4creators/jxrlib/blob/master/jxrgluelib/JXRGlue.c)
- [JXRMeta.h](https://github.com/4creators/jxrlib/blob/master/jxrgluelib/JXRMeta.h)
- [Makefile](https://github.com/4creators/jxrlib/blob/master/Makefile)
- [JxrDecApp.c (reference CLI)](https://github.com/4creators/jxrlib/blob/master/jxrencoderdecoder/JxrDecApp.c)
- [Ubuntu JxrDecApp manpage](https://manpages.ubuntu.com/manpages/noble/man1/JxrDecApp.1.html)
- Alternative fork: [topalex/jxrlib-static](https://github.com/topalex/jxrlib-static) — has CMake shim (only relevant if Makefile integration becomes a blocker)

**ImageMagick comparison:**
- [delegates.xml.in](https://github.com/ImageMagick/ImageMagick/blob/main/config/delegates.xml.in) — confirms JXR delegate silently downconverts HDR to SDR

### Internal References

None — jxc is greenfield, no prior code in the project to cross-reference.

### Related Work

- No public project combines `4creators/jxrlib` and `libjxl` in a single binary's call graph today. jxc is among the first.
- [`dyang886/Universal-Converter`](https://github.com/dyang886/Universal-Converter) uses both libraries via ImageMagick delegates (separate CLI calls), not as a single pipeline — different design, doesn't preserve HDR.