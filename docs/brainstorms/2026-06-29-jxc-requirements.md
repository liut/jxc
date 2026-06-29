---
date: 2026-06-29
topic: jxc
---

# jxc — HDR JXR to JXL Batch Converter

## Summary

jxc is a Zig CLI that batch-converts HDR JXR (and WDP/HDP) files to JPEG XL, shipping as a single statically-linked binary that runs on Windows, macOS, and Linux with no codec installation. Built for users with HDR JXR assets currently locked to Windows-only viewers who want cross-platform viewability through JXL's universal HDR support.

---

## Problem Frame

HDR JXR (and its WDP/HDP siblings) is the file format Windows uses for HDR desktop wallpapers. Outside Windows, the format is essentially a dead end: no good cross-platform viewer exists, and HDR JXR assets cannot be used on macOS or Linux without conversion.

The escape hatches that do exist are bad. ImageMagick's libjxr delegate has partial HDR support — it can fail outright or silently downconvert HDR to SDR. Microsoft tools are Windows-only. The result: a user with a folder of Windows HDR wallpapers has no clean way to use them anywhere else, and any round-trip that loses HDR color information defeats the point.

JPEG XL is the natural target format. JXL has first-class HDR support (PQ and HLG transfer functions, wide-gamut color spaces), is widely readable across all major platforms, and is the recommended migration path for HDR image archives.

The catch: the obvious library choice for decoding JXR — `4creators/jxrlib` — declares HDR pixel formats in its API (`48bppRGBFixedPoint`, `64bppRGBHalf`, `128bppRGBFloat`, etc.) but its real-world HDR decode behavior is unverified. That is the project's central risk and must be empirically confirmed before committing to the main CLI build.

---

## Actors

- A1. End user: has HDR JXR/WDP/HDP files they want to convert to JXL for cross-platform use; runs jxc on these files directly.
- A2. Project lead: runs the v0 verification step before starting the main CLI project; responsible for the go/no-go decision on the jxrlib decoder.

---

## Key Flows

- F1. Single-file conversion
  - **Trigger:** A1 invokes `jxc input.jxr output.jxl`
  - **Actors:** A1
  - **Steps:** Parse args → open input → jxrlib decodes to raw HDR pixels → preserve ICC profile and any EXIF → libjxl encodes to JXL with matching HDR color space → write output → report success
  - **Outcome:** Output JXL file exists, HDR pixel data preserved, ICC profile carried over
  - **Covered by:** R1, R2, R3, R11

- F2. Batch conversion (directory mode)
  - **Trigger:** A1 invokes `jxc input-dir/ output-dir/`
  - **Actors:** A1
  - **Steps:** Enumerate input files matching supported extensions → for each file: convert per F1 → on per-file failure, log the failure with its path and continue → at end, print summary (total / succeeded / failed / failed paths)
  - **Outcome:** All convertible files in the directory are converted; failures surfaced without aborting the batch
  - **Covered by:** R4, R5, R6, R11, R12

- F3. v0 HDR verification (pre-launch, blocking)
  - **Trigger:** A2 runs a small Zig program against a known HDR JXR test file before starting the main CLI
  - **Actors:** A2
  - **Steps:** Decode a 16bpp-fixed-point HDR JXR file via jxrlib → read raw pixels → assert bit depth and HDR pixel format → compare against expected values from a reference source
  - **Outcome:** Empirical confirmation that jxrlib decodes HDR end-to-end, OR a documented failure that triggers fallback planning (Approach C: Microsoft original ref impl, ffmpeg JXR decoder, or fork fix) before the main CLI project starts
  - **Covered by:** R10

---

## Requirements

**HDR fidelity**
- R1. Convert HDR JXR files (16bpp fixed point, half-float, and full-float pixel formats) to JXL while preserving HDR color fidelity end-to-end.
- R2. By default, preserve the source ICC profile in the output JXL so HDR color metadata (e.g., Rec.2020 + PQ transfer) survives the round trip. Strip is not a v1 option.
- R3. Accept all three JXR input extensions: `.jxr`, `.wdp`, `.hdp`.

**Input handling**
- R4. Accept input as either a single file path or a directory path.
- R5. When input is a directory, recursively scan for files matching the supported input extensions and convert each.
- R6. On per-file failure (corrupt input, decoder error, encoder error, I/O error), log the failure with the offending file path and continue processing remaining files; do not abort the batch.

**Distribution and runtime**
- R7. Ship as a single statically-linked binary per platform (Linux x86_64, macOS x86_64 + arm64, Windows x86_64) with no external codec or runtime dependency beyond the OS.
- R8. Run on Windows, macOS, and Linux without the user installing jxrlib, libjxl, or any other library.
- R9. jxrlib and libjxl are compiled from source as part of the build and linked statically into the binary (vendored build).

**Pre-launch validation**
- R10. Before the main CLI project starts, a v0 verification step empirically confirms that jxrlib can decode HDR JXR files end-to-end. If verification fails, the main project does not start; A2 revisits Approach C fallback options first.

**User feedback**
- R11. During batch conversion, print a one-line progress message per file (file path + success/failure).
- R12. At the end of batch conversion, print a summary: total files processed, successful count, failed count, and the list of failed file paths.

---

## Acceptance Examples

- AE1. **Covers R1, R2, R3.** Given a 16bpp-fixed-point HDR JXR file carrying a Rec.2020 + PQ ICC profile, when `jxc wallpaper.jxr wallpaper.jxl` is run, then `wallpaper.jxl` exists, its HDR pixel values match the source, and the same ICC profile is embedded in the output (verifiable via `exiftool` or equivalent metadata tool).
- AE2. **Covers R4, R5, R6.** Given a directory containing 100 HDR JXR files, 3 of which are corrupt, when `jxc in/ out/` is run, then 97 JXL files appear in `out/`, a final summary reports `100 processed, 97 succeeded, 3 failed`, and each of the 3 corrupt file paths appears in the failure list.
- AE3. **Covers R6.** Given a batch where file #47 fails to decode, when `jxc in/ out/` is run, then files #1 through #46 are converted, the failure of #47 is logged with its path, and files #48 through #100 continue processing.
- AE4. **Covers R7, R8.** Given a fresh OS install on each target platform with no development tools or codecs installed, when the compiled jxc binary is run with a directory of HDR JXR files as input, then it converts them all without prompting the user to install anything.
- AE5. **Covers R10.** Given v0 verification, when the Zig test program runs against a known HDR JXR test file, then it prints confirmation that jxrlib decoded the file correctly (pixel statistics match expected values, bit depth is preserved, no decoder errors).

---

## Success Criteria

- 100% of HDR JXR files in a representative real-world test set (e.g., Windows HDR wallpaper samples) convert successfully and are viewable as HDR in a cross-platform JXL viewer (e.g., Chrome, GIMP, geeqie).
- Converted JXL files preserve the source ICC profile (verifiable via metadata inspection).
- v0 verification step empirically confirms jxrlib HDR decode works before any CLI code is written; if verification fails, the project pauses and reopens the decoder choice before any further work.
- The compiled binary runs from a fresh OS install on each of the three target platforms with no library installation step.

---

## Scope Boundaries

- Editing, resizing, cropping, or filtering of images.
- Reverse conversion (JXL → JXR).
- Input formats other than JXR/WDP/HDP (no AVIF, HEIF, WebP, etc.).
- GUI (command-line interface only).
- Compression-quality or encoder-parameter tuning UI (libjxl defaults are used for v1).
- Network, cloud, or sync features.
- HDR verification GUI (v0 step is a CLI-only test program).
- SDR-only fallback path (HDR is non-negotiable for v1).
- ICC profile stripping as an explicit option (preservation is the only v1 behavior).

---

## Key Decisions

- **Language: Zig.** Best C/C++ interop for the chosen libraries (direct `@cImport` of jxrlib and libjxl), single static binary distribution, easy cross-compilation, and matches the project's existing workspace structure.
- **Build strategy: vendored static linking.** jxrlib and libjxl are compiled from source and linked statically into one binary. Dynamic linking was rejected because jxrlib has no good Windows package, which would break the cross-platform zero-install promise.
- **Pre-launch v0 verification is a project precondition, not a post-hoc check.** The real risk is not the library choice (jxrlib + libjxl is forced by the format requirements) but whether jxrlib's HDR decode path actually works. Verifying it first prevents the failure mode of writing the full CLI and only then discovering a decoder limitation that forces a redo.
- **ICC profile preservation is the v1 default and the only v1 behavior.** Stripping is not exposed as an option. This is what makes HDR round-trips visually correct.
- **Distribution scope: personal use + informal sharing.** No CI, no GitHub releases, no public release artifacts, but the binary must run on others' machines without setup. This keeps the build/packaging story simple while still meeting the cross-platform need.
- **HDR is non-negotiable for v1.** There is no SDR-only fallback path; the project exists specifically to handle HDR JXR files.

---

## Dependencies / Assumptions

- **jxrlib (4creators fork) integrates cleanly into Zig's build system** despite being a Makefile-based project. To be validated during planning.
- **libjxl exposes a stable C API** that Zig can `@cImport` directly. Generally well-supported per libjxl's design.
- **libjxl's HDR encoding path** (PQ/HLG transfer functions, wide gamut) is functional and produces HDR-correct output that matches the source JXR's color metadata.
- **Test HDR JXR files are available** for v0 verification (Windows HDR wallpapers from a Windows installation, or samples from a known source).
- **Licenses are compatible** with the chosen distribution scope: jxrlib is BSD-2-Clause, libjxl is BSD-3-Clause; both are permissive and compatible with each other and with informal redistribution.
- **Zig 0.14+ is available** on the development machine (assumption about the user's toolchain; to be confirmed during planning if uncertain).

---

## Outstanding Questions

### Resolve Before Planning

*(none — all blocking questions resolved during brainstorm)*

### Deferred to Planning

- **[Affects R9][Technical]** How to integrate jxrlib's Makefile-based build into Zig's `build.zig` — custom build step invoking `make`, or a wrapper that builds jxrlib separately and consumes the static lib.
- **[Affects R1, R2][Needs research]** libjxl API for setting HDR transfer function and embedding ICC profile from raw decoded pixels — confirm the API surface during planning.
- **[Affects R2][Technical]** Behavior for source JXR files without an ICC profile — default to Rec.709 / sRGB, error out, or warn and continue.
- **[Affects F2][Technical]** Threading model for batch mode — Zig `std.Thread` pool with a fixed worker count, or sequential. Depends on libjxl's threading safety guarantees.
- **[Affects R11][Technical]** Progress reporting format — simple per-file text line (matches R11 as written), or interactive progress bar via a TTY-aware approach.
- **[Affects R1][Needs research]** EXIF/XMP metadata preservation beyond ICC — confirm whether this is feasible and worth including in v1, or defer to v2.
- **[Affects R7][Technical]** Code signing for the Windows binary — required for some Windows versions to run an unsigned binary without SmartScreen warnings; determine if out-of-scope or needed.