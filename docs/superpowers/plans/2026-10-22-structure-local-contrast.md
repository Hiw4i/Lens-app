# Structure Local Contrast Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace the current sharpening-like `Structure` adjustment with a professional local-contrast (base/detail) control: an edge-preserving guided-filter base, a parabolic midtone mask `4*L*(1-L)`, and a hue-preserving application of the detail map, identical in the GPU preview and the CPU export, on a bipolar -100..+100 slider.

**Architecture:** One shared pure-Dart module computes the guided-filter coefficient maps (`a`, `b`) from the source luma; the export path uses its float maps directly, the preview path packs them into an RGBA8888 texture that the fragment shader samples as a 5th image sampler. The stage itself is a short formula mirrored 1:1 in GLSL and in Dart.

**Tech Stack:** Flutter 3.47.7 / Dart 3.13.5, Flutter runtime-effect fragment shader (SkSL), `package:image` ^4.2.0, `flutter_test`.

**Spec:** `docs/superpowers/specs/2026-10-22-structure-local-contrast-design.md`

## Global Constraints

- No new dependencies. No native code (C++/Rust/FFI). `package:image` stays the only pixel library.
- `lib/features/imaging/structure/structure_filter.dart` is PURE Dart: no `dart:ui`, no `package:flutter` imports, no `package:lens` imports that pull in Flutter. It must be safe to run inside `Isolate.run`.
- The preview stays on the GPU (`ui.FragmentShader`); the export stays the pure-Dart isolate pipeline in `lens_cpu.dart`.
- The structure stage stays between shadows/highlights and the LUT in BOTH paths.
- The stage must be an EXACT no-op at amount 0 (multiplier exactly 1.0).
- Uniform layout is append-only: float slot 8 stays `uStructure` (now signed -1..1), the new image sampler is slot 4, and NO existing slot may move. The legacy uniform vector lengths (9/10/19/32/37/47) must keep grading exactly as before.
- The shader stays valid Flutter runtime-effect SkSL: no `textureLod`, no dynamic loops, no `discard`.
- Code comments and doc comments are written in English (the codebase convention).
- Tests live flat in `test/` and use `flutter_test`'s `test()`/`group()`.

## Review Focus

Five input classes the spec implies that no task's happy-path test exercises. Each one gets a test in the task that owns the code.

1. A photo SMALLER than the preview bound (<= 1080 px): `PreviewCache.previewBytes` returns the ORIGINAL bytes untouched, so the maps must be built from the original at the photo's own dimensions - no upscaling, no misalignment. (Task 4)
2. The square-cropped filter thumbs (`squareCrop: true`): the maps must be cropped with the SAME centred square `PreviewCache.squarePreviewBytes` crops, or the structure lands on the wrong part of the thumb. (Task 4)
3. A source the engine cannot decode (HEIC, corrupt file): the preview must fall back to the CPU image, never a crash and never a black frame. (Task 4)
4. Near-black and near-white pixels: the parabolic mask must be ~0 there, the exponent must stay clamped, and no channel may invert or clip to garbage. (Task 1 and Task 2)
5. The structure slider dragged while the maps are still being computed: the preview must show the UN-structured photo through the neutral stub, never a stale or misaligned base. (Task 4)

---

### Task 1: The shared structure module (guided filter + stage math)

**Files:**
- Create: `lib/features/imaging/structure/structure_filter.dart`
- Test: `test/structure_filter_test.dart`

**Interfaces:**
- Consumes: nothing (first task).
- Produces:
  ```dart
  // lib/features/imaging/structure/structure_filter.dart
  const double kStructureRadiusFrac = 0.0075;   // radius = frac * min(w, h)
  const int kStructureRadiusMinPx = 2;
  const int kStructureRadiusMaxPx = 96;
  const int kStructureLowRadius = 2;             // guided radius in the LOW grid
  const int kStructureMaxSubsample = 16;
  const double kStructureEps = 0.01;
  const double kStructureGain = 2.5;
  const double kStructureDetailClamp = 1.0;      // clamp of dEV
  const double kStructureExponentClamp = 0.7;     // exponent -> multiplier [exp(-0.7), exp(0.7)] = [0.4966, 2.0138]

  class StructureGeometry {
    final int radius;      // full-res radius in px
    final int subsample;   // s
    final int lowRadius;   // r' in the low-res grid
  }
  StructureGeometry structureGeometryFor(int width, int height);

  class StructureMaps {
    final Float32List a;   // low-res coefficient map
    final Float32List b;   // low-res coefficient map
    final int width;       // low-res grid width
    final int height;      // low-res grid height
    final int sourceWidth; // full-res width the maps belong to
    final int sourceHeight;
  }
  StructureMaps computeStructureMapsFromRgb(
    Float32List rgb, int width, int height, {required double radius});
  StructureMaps computeStructureMapsFromRgba(
    Uint8List rgba, int width, int height, {required double radius});

  /// Bilinear base sample at full-res pixel (x, y). Texel-centre mapping,
  /// clamped edges - the SAME convention as the GPU's linear filter.
  double structureBaseAt(StructureMaps maps, int x, int y, double yraw);

  /// The stage formula, mirrored 1:1 in GLSL.
  double structureMultiplier({
    required double yraw,   // raw luma of the pixel
    required double q,      // base luma
    required double amount, // -1..1
  });

  /// Packs the maps for the preview texture: R = a (8 bit), G:B = b (16 bit
  /// big-endian), A = 255.
  Uint8List packStructureMaps(StructureMaps maps);
  ```

- [ ] **Step 1: Write the failing tests** in `test/structure_filter_test.dart`

  Synthetic helpers (mirroring the style of `test/lens_cpu_test.dart`): a
  `_flatImage` (uniform mid grey 0.5), a `_stepImage` (left half 0.25, right
  half 0.75, one hard vertical edge), a `_textureImage` (smooth band-limited
  noise around 0.5, amplitude ~0.08, e.g. `0.5 + 0.08*sin(x*0.7)*sin(y*0.5)`).

  Tests:
  - `geometry adapts the subsample ratio to the radius`:
    `structureGeometryFor(1080, 1440)` -> radius 8, subsample 4, lowRadius 2.
    `structureGeometryFor(3000, 4000)` -> radius 23, subsample 12, lowRadius 2.
    `structureGeometryFor(16, 16)` -> radius 2, subsample 1, lowRadius 2.
  - `flat image has no detail`: on `_flatImage` the base equals the luma, so
    `structureBaseAt(...)` is within 1e-3 of the luma for every pixel and
    `structureMultiplier(yraw: 0.5, q: 0.5, amount: 1.0)` is exactly 1.0.
  - `step edge is protected from halos`: on `_stepImage` the base at the edge
    pixels stays close to the pixel's own luma (the detail there is smaller
    than 25% of the step), while the detail on the flat sides is ~0.
  - `texture produces a non-zero detail map`: on `_textureImage` the base
    differs from the luma by at least 0.01 somewhere, and
    `structureMultiplier` with `amount: 1.0` is > 1.0 on the brighter half of
    the texture and < 1.0 on the darker half (the boost is symmetric around
    the base).
  - `midtone mask is parabolic`: `structureMultiplier` with `q: 0.0` and with
    `q: 1.0` returns exactly 1.0 for any amount; with `q: 0.5` the effect is
    maximal (the absolute multiplier deviation from 1.0 is larger than at
    `q: 0.25` for the same `dEV`).
  - `amount is signed`: the same `yraw`/`q` pair with `amount: -1.0` returns
    the reciprocal multiplier of `amount: 1.0` (within 1e-6).
  - `exponent is clamped`: a `dEV` of 5.0 (call
    `structureMultiplier(yraw: 0.9, q: 0.18, amount: 1.0)`) yields a
    multiplier inside `[exp(-0.7), exp(0.7)]` = `[0.4966, 2.0138]`.
  - `packed maps round-trip within the documented budget`: pack
    `computeStructureMapsFromRgb` of `_textureImage` and decode R (as `a`) and
    G:B (as 16-bit `b`); the decoded values must be within 1/255 of the float
    maps for `a` and within 2/65535 for `b`.
  - `rgba and rgb inputs agree`: `computeStructureMapsFromRgba` on the same
    pixels returns maps within 1/255 of `computeStructureMapsFromRgb`.
  - `the effect is resolution relative`: build the SAME band-limited texture
    pattern at 128x128 and at 512x512 (the pattern is a function of the
    normalised coordinate, so the texture scale is identical), compute the
    maps for both and compare the mean absolute multiplier deviation
    `|structureMultiplier(...) - 1|` over the pixels: the two means must be
    within 30% of each other (the radius is a fraction of the short side and
    the low-res radius is pinned, so the texture scale must NOT change with
    the resolution).

- [ ] **Step 2: Run the test to verify it fails**

  Run: `flutter test test/structure_filter_test.dart`
  Expected: FAIL - "Target of URI hasn't been generated" / undefined
  `structure_filter.dart` import.

- [ ] **Step 3: Implement `structure_filter.dart`**

  Algorithm (from the spec, section 3):
  - `structureGeometryFor(width, height)`:
    `radius = (kStructureRadiusFrac * min(width, height)).round().clamp(kStructureRadiusMinPx, kStructureRadiusMaxPx)`;
    `subsample = (radius / kStructureLowRadius).round().clamp(1, kStructureMaxSubsample)`;
    `lowRadius = (radius / subsample).round().clamp(1, radius)`.
  - Low-res luma: box-average the source luma into a `ceil(width/s) x
    ceil(height/s)` grid (partition the source exactly like
    `_downsampleLumaBox` in `lens_cpu.dart:1132`, luma folded in on the fly -
    no full-res luma buffer). For the RGBA input, luma uses the same rec.709
    weights on the 0..1 bytes.
  - Guided filter on the low-res luma `Ylow` with radius `lowRadius`:
    `mY = box(Ylow)`, `mYY = box(Ylow^2)`, `var = max(mYY - mY*mY, 0)`,
    `a0 = var / (var + eps)`, `b0 = mY * (1 - a0)`, then `a = box(a0)`,
    `b = box(b0)`. The box filter is separable with sliding-window sums
    (O(N), radius independent) and clamped edges.
  - `structureBaseAt(maps, x, y, yraw)`: bilinear sample of `a` and `b` at the
    low-res coordinate of the full-res pixel, using the texel-centre mapping
    `fx = (x + 0.5) * maps.width / maps.sourceWidth - 0.5` (clamped edges),
    then `q = a * yraw + b`.
  - `structureMultiplier`: `q = q.clamp(0,1)`;
    `dEV = (max(yraw,1e-3)/max(q,1e-3)).ln().clamp(-kStructureDetailClamp, kStructureDetailClamp)`;
    `mask = 4*q*(1-q)`; `e = (amount*kStructureGain*mask*dEV).clamp(-kStructureExponentClamp, kStructureExponentClamp)`;
    return `exp(e)`.
  - `packStructureMaps`: RGBA8888, `R = round(a*255)`, `G = (b16 >> 8)`, `B = b16 & 255`
    with `b16 = round(b*65535)`, `A = 255`.

- [ ] **Step 4: Run the test to verify it passes**

  Run: `flutter test test/structure_filter_test.dart`
  Expected: PASS (all tests).

- [ ] **Step 5: Run the analyzer**

  Run: `flutter analyze`
  Expected: no new issues (`flutter analyze` reports only issues; the repo
  starts clean).

- [ ] **Step 6: Commit**

  ```bash
  git add lib/features/imaging/structure/structure_filter.dart test/structure_filter_test.dart
  git commit -m "feat(structure): guided-filter base/detail module with parabolic midtone mask"
  ```

  NOTE: this checkout is NOT a git repository (see the spec). If `git` is
  unavailable, skip the commit step and say so in the final report.

---

### Task 2: The CPU export uses the shared module

**Files:**
- Modify: `lib/features/imaging/pipeline/lens_cpu.dart:253-271` (constants),
  `:747-753` (the blur buffer), `:956-976` (the structure stage), `:1240-1279`
  (`_boxBlurLumaFromRgb` - delete)
- Test: `test/lens_cpu_test.dart`

**Interfaces:**
- Consumes: `structureGeometryFor`, `computeStructureMapsFromRgb`,
  `structureBaseAt`, `structureMultiplier` from Task 1's
  `structure_filter.dart`.
- Produces: no new public API. `applyLensGrade` now reads `uniforms[8]` as a
  SIGNED amount (`-1..1` instead of `0..1`).

- [ ] **Step 1: Write the failing tests** in `test/lens_cpu_test.dart`

  - `structure 0 is byte-identical to no structure`: grade the same PNG twice,
    once with `LensParams()` and once with `LensParams(structure: 0)`, and
    compare the decoded pixels byte for byte (expect 0 differing pixels).
  - `structure +100 increases the local contrast of a texture`: build a
    64x64 band-limited texture image (amplitude ~0.08 around mid grey, the
    same `_textureImage` shape as Task 1), grade it with
    `LensParams(structure: 100)` and with `LensParams()`, and assert that the
    standard deviation of the luma around the local mean grows
    (`structuredStd > flatStd * 1.05`).
  - `structure -100 decreases the local contrast of a texture`: the same image,
    `LensParams(structure: -100)` -> `softStd < flatStd * 0.95`.
  - `structure does not boost hard edges (it is not sharpening)`: a 64x64
    image with ONE hard vertical edge (0.25 -> 0.75) -> the mean absolute
    difference across the edge changes by less than 3/255 for
    `structure: 100` (the guided filter keeps the edge in the base).
  - REWRITE the existing test `structure 0 vs 100 differ on high-frequency
    image`: the 16x16 checkerboard is a hard-edge pattern, and the new
    algorithm deliberately does NOT boost edges, so that test's premise is
    void. Replace it with the texture-based assertion above (keep the test
    name pattern of the file).

- [ ] **Step 2: Run the test to verify it fails**

  Run: `flutter test test/lens_cpu_test.dart`
  Expected: FAIL - the new assertions fail against the old box-blur
  implementation (the old one boosts edges and its negative direction does not
  exist).

- [ ] **Step 3: Implement the export stage**

  In `applyLensGrade`:
  - `final double structureAmt = uniforms[8].clamp(-1.0, 1.0);` (signed).
  - Replace the `blurLuma` buffer with:
    ```dart
    StructureMaps? structureMaps;
    if (structureAmt != 0.0) {
      final StructureGeometry geo = structureGeometryFor(w, h);
      structureMaps = computeStructureMapsFromRgb(src, w, h, radius: geo.radius);
    }
    ```
  - In the per-pixel loop, replace the old structure block with:
    ```dart
    if (structureMaps != null) {
      final double rawLuma = 0.299 * rr + 0.587 * gg + 0.114 * bb;
      final double q = structureBaseAt(structureMaps, x, y, rawLuma);
      final double mult = structureMultiplier(
        yraw: rawLuma, q: q, amount: structureAmt);
      r *= mult; g *= mult; b *= mult;
    }
    ```
    (the loop must expose `x` and `y`; if the loop is index-based (`p`), derive
    `x = p % w`, `y = p ~/ w`).
  - Delete `_boxBlurLumaFromRgb` and `kLensStructureBlurRadius`; keep
    `kLensStructureDetailClamp` only if still referenced, otherwise delete it
    and document the new constants in the file header.
  - Update the file header docs (stage order + the "Known divergences"
    section): the structure stage is now the guided-filter base/detail with a
    parabolic mask, the preview/export blur divergence note is replaced by
    the "same filter, quantised maps" note.

- [ ] **Step 4: Run the test to verify it passes**

  Run: `flutter test test/lens_cpu_test.dart`
  Expected: PASS.

- [ ] **Step 5: Run the whole suite and the analyzer**

  Run: `flutter test && flutter analyze`
  Expected: all tests pass, no analyzer issues.

- [ ] **Step 6: Commit**

  ```bash
  git add lib/features/imaging/pipeline/lens_cpu.dart test/lens_cpu_test.dart
  git commit -m "feat(structure): export path uses the guided-filter base/detail stage"
  ```

---

### Task 3: The fragment shader stage

**Files:**
- Modify: `shaders/lens_filter.frag` (the sampler block `:108-111`, the uniform
  docs `:9-12`, the structure stage `:553-574`)

**Interfaces:**
- Consumes: the sampler slot 4 texture, packed as R = `a` (8 bit), G:B = `b`
  (16 bit big-endian), A = 255 (Task 1's `packStructureMaps`).
- Produces: no new uniform slot for the maps (the sampler is slot 4). Float
  slot 8 (`uStructure`) becomes signed -1..1. NO other slot moves.

- [ ] **Step 1: Update the shader header comment** (the sampler list and the
  slot map) to document slot 4 and the signed structure amount.

- [ ] **Step 2: Declare the new sampler** immediately after `uniform sampler2D
  uBlurMask;` so it takes slot 4:
  ```glsl
  uniform sampler2D uStructureMaps;   // slot 4: R = a, G:B = b (16 bit)
  ```

- [ ] **Step 3: Replace the structure stage** (the current 4-tap cross blur
  block) with the mirrored formula:
  ```glsl
  float sAmt = clamp(uStructure, -1.0, 1.0);
  if (abs(sAmt) > 1e-4) {
    float rawL = dot(raw, vec3(0.299, 0.587, 0.114));
    vec4 mt = texture(uStructureMaps, uv);
    float a = mt.r;
    float b = (mt.g * 255.0 * 256.0 + mt.b * 255.0) / 65535.0;
    float q = clamp(a * rawL + b, 0.0, 1.0);
    float dEV = clamp(log(max(rawL, 1e-3) / max(q, 1e-3)),
                      -1.0, 1.0);
    float midMask = 4.0 * q * (1.0 - q);
    float e = clamp(sAmt * 2.5 * midMask * dEV, -0.7, 0.7);
    graded *= exp(e);
  }
  ```
  The literal constants must equal the Dart constants in Task 1
  (`kStructureGain` 2.5, `kStructureDetailClamp` 1.0,
  `kStructureExponentClamp` 0.7) - the shader cannot import them, so the
  comment above the block must state that they mirror the Dart constants.

- [ ] **Step 4: Verify the shader compiles**

  Run: `flutter test test/shader_compile_test.dart`
  Expected: PASS. The `.frag` asset is shipped verbatim (Flutter's build does
  NOT compile it), but the test engine DOES run the SkSL compiler, so this
  test is what catches a shader syntax/semantic error. A SkSL error fails the
  test with a message naming the offending line in
  `shaders/lens_filter.frag`.

- [ ] **Step 5: Run the analyzer and the suite**

  Run: `flutter test && flutter analyze`
  Expected: all pass.

- [ ] **Step 6: Commit**

  ```bash
  git add shaders/lens_filter.frag
  git commit -m "feat(structure): guided-filter structure stage in the preview shader"
  ```

---

### Task 4: The preview base texture (cache + sampler binding)

**Files:**
- Create: `lib/features/imaging/cache/structure_cache.dart`
- Modify: `lib/features/imaging/widgets/shader_preview.dart`
- Test: `test/structure_cache_test.dart`

**Interfaces:**
- Consumes: Task 1's `computeStructureMapsFromRgba`, `packStructureMaps`,
  `structureGeometryFor`.
- Produces:
  ```dart
  // lib/features/imaging/cache/structure_cache.dart
  class StructureCache {
    /// Packed RGBA8888 texture bytes (R = a, G:B = b) for the source scaled
    /// to [targetWidth] x [targetHeight]. Null when the source cannot be
    /// decoded.
    static Future<Uint8List?> mapsFor(
      Uint8List sourceBytes, {
      required int targetWidth,
      required int targetHeight,
      bool square = false,
    });
    /// The 1x1 NEUTRAL stub: a = 1, b = 0 -> q = luma -> dEV = 0 -> the
    /// stage is an exact no-op while the real maps are still computing.
    static Uint8List neutralStubBytes();
    static void clear();
    static int get length;   // for tests
  }
  ```
  The shader receives the bytes through `decodeImageFromPixels` (RGBA8888) and
  binds them as sampler slot 4.

- [ ] **Step 1: Write the failing tests** in `test/structure_cache_test.dart`

  - `maps are produced for a decodable source`: encode a 64x64 PNG with
    `package:image`, call `StructureCache.mapsFor(bytes, targetWidth: 64,
    targetHeight: 64)`; expect a non-null result whose length is
    `lw * lh * 4` with `lw = ceil(64 / subsample)`.
  - `the packed maps decode to sane coefficients`: decode the packed bytes
    and check that the R channel (a) is within [0, 1] after the 1/255
    dequantisation and that the G:B pair (b, 16 bit) is within [0, 1].
  - `an undecodable source returns null`: pass 12 random bytes that are not
    an image -> expect null (no throw).
  - `the cache is keyed by content`: two calls with the same bytes return the
    SAME `Uint8List` instance (cache hit), a third with different bytes does
    not.
  - `a square source is cropped to a centred square`: for a 64x32 source with
    `square: true` the returned texture is square (the packed length matches
    the square's low-res grid).
  - `a source smaller than the target keeps its own size`: a 32x32 source
    requested at 256x256 must return the packed length of the 32x32 grid (the
    engine does not upscale) - the maps stay aligned with the preview raster.
  - `the neutral stub is a no-op`: `StructureCache.neutralStubBytes()` must
    decode to a = 1.0 and b = 0.0, so `q = yraw` and `dEV = 0`.

- [ ] **Step 2: Run the test to verify it fails**

  Run: `flutter test test/structure_cache_test.dart`
  Expected: FAIL - `structure_cache.dart` does not exist.

- [ ] **Step 3: Implement `structure_cache.dart`**

  - LRU map keyed by `Object.hash(maxDim, contentHash, square)` with a small
    entry cap (8), mirroring `PreviewCache`'s structure and its stable content
    hash (byte length + FNV-1a over the head and tail).
  - `mapsFor`:
    1. `ui.instantiateImageCodec(sourceBytes, targetWidth: targetWidth,
       targetHeight: targetHeight)` -> frame -> `toByteData(rawRgba)`.
       If the source is SMALLER than the target the engine does not upscale,
       so the decoded size may be smaller - use the DECODED size, not the
       requested one.
    2. For `square: true`, crop the centred square of the decoded RGBA
       (side = min(w, h), offset = ((w-side)/2, (h-side)/2)) BEFORE the
       guided filter - the same crop `PreviewCache.squarePreviewBytes` makes.
    3. Run the guided filter in an isolate: `Isolate.run(() => ...)` over the
       RGBA bytes -> `computeStructureMapsFromRgba` -> `packStructureMaps`.
    4. Cache the packed bytes and return them.
  - Any decode failure returns null (the caller keeps the neutral stub).

- [ ] **Step 4: Bind slot 4 in `shader_preview.dart`**

  - Add a cached 1x1 NEUTRAL stub image built from
    `StructureCache.neutralStubBytes()` (R = 255, G = 0, B = 0, A = 255), like
    the existing `_whiteMaskImage()` helper but with the structure values.
  - The preview needs the SOURCE bytes and the preview raster's dimensions:
    `ShaderPreview` already receives `widget.imageBytes` (the original) and
    decodes the preview raster. Request the maps for the decoded preview
    dimensions (and `square: widget.squareCrop`).
  - Add the maps image to the `_ensureShader` / `_createShader` tuple and call
    `shader.setImageSampler(4, maps)` next to the existing binds.
  - The maps are computed ONCE per photo (they do not depend on any slider
    value), so a slider tick must NOT restart the request: keep the future
    stable like `_lutFor` / `_maskFor` do.
  - While the maps future is pending, the neutral stub stays bound -> the
    stage is an exact no-op and the preview shows the un-structured photo.

- [ ] **Step 5: Run the test to verify it passes**

  Run: `flutter test test/structure_cache_test.dart`
  Expected: PASS.

- [ ] **Step 6: Run the whole suite and the analyzer**

  Run: `flutter test && flutter analyze`
  Expected: all pass, no analyzer issues.

- [ ] **Step 7: Commit**

  ```bash
  git add lib/features/imaging/cache/structure_cache.dart lib/features/imaging/widgets/shader_preview.dart test/structure_cache_test.dart
  git commit -m "feat(structure): preview binds the guided-filter base texture as sampler 4"
  ```

---

### Task 5: The bipolar Structure slider

**Files:**
- Modify: `lib/features/adjust/cards/structure/structure_card.dart:20-22`
  (`min`/`max`), `lib/features/editor/logic/editor_state.dart:468-469`
  (`setStructure`), `lib/features/adjust/adjust_state.dart:4,27-28` (docs),
  `lib/features/imaging/pipeline/lens_pipeline.dart:18,156-158,359`
  (`structureNormalized` + docs), `lib/features/editor/logic/editor_params.dart:14,104`
  (docs), `lib/features/adjust/adjust_presets.dart:6` (docs)
- Test: `test/first_open_hardening_test.dart`

**Interfaces:**
- Consumes: nothing.
- Produces: `LensParams.structureNormalized` returns `(structure / 100).clamp(-1.0, 1.0)`.

- [ ] **Step 1: Write the failing tests** in `test/first_open_hardening_test.dart`

  - UPDATE `structureNormalized clamps 0..1` -> rename to
    `structureNormalized clamps -1..1`:
    `LensParams(structure: 250).structureNormalized == 1.0`,
    `LensParams(structure: -250).structureNormalized == -1.0`,
    `LensParams(structure: -10).structureNormalized == -0.1`.
  - ADD to the "setters clamp wild values" test:
    `setStructure(-150)` -> `adjust.structure == -100`,
    `setStructure(150)` -> `adjust.structure == 100`.

- [ ] **Step 2: Run the test to verify it fails**

  Run: `flutter test test/first_open_hardening_test.dart`
  Expected: FAIL - `structureNormalized` still clamps to 0..1 and
  `setStructure` still clamps to 0..100.

- [ ] **Step 3: Implement the bipolar range**

  - `structure_card.dart`: `min => -100`, `max => 100`; update the class doc
    ("Local contrast (clarity), -100..100; negative softens the texture").
    `snapToNeutral` becomes true automatically (the base class checks
    `min < 0 && max > 0`).
  - `editor_state.dart`: `setStructure` clamps to -100..100.
  - `lens_pipeline.dart`: `structureNormalized` clamps to -1..1; update the
    field docs (line 18 and 156-158) to say the amount is SIGNED -100..+100.
  - `adjust_state.dart`, `editor_params.dart`, `adjust_presets.dart`: update
    the doc comments that say "structure 0..100".
  - Preset values stay as they are (`punchy` 30, `muted` 10).

- [ ] **Step 4: Run the test to verify it passes**

  Run: `flutter test test/first_open_hardening_test.dart`
  Expected: PASS.

- [ ] **Step 5: Run the whole suite and the analyzer**

  Run: `flutter test && flutter analyze`
  Expected: all pass, no analyzer issues.

- [ ] **Step 6: Commit**

  ```bash
  git add lib/features/adjust lib/features/editor lib/features/imaging/pipeline/lens_pipeline.dart test/first_open_hardening_test.dart
  git commit -m "feat(structure): bipolar -100..100 slider with signed amount"
  ```

---

### Task 6: Pipeline documentation

**Files:**
- Modify: `lib/features/imaging/pipeline/lens_cpu.dart` (the file header, the
  stage-order list and the "Known divergences" section),
  `lib/features/imaging/pipeline/lens_pipeline.dart` (the header's parameter
  list and the slot map), `shaders/lens_filter.frag` (the header's stage-order
  comment)

**Interfaces:**
- Consumes: everything from Tasks 1-5.
- Produces: no code.

- [ ] **Step 1: Update the `lens_cpu.dart` header**: the stage order line
  ("structure detail add") becomes the guided-filter base/detail stage; the
  divergence bullet about "Structure blur: CPU uses a 5x5 box vs the preview's
  4-tap cross" is replaced by the new note (same filter, same constants, the
  preview's maps are quantised, the preview base is built from the source
  scaled to the preview size). Also update the memory paragraph: the structure
  stage now needs two LOW-res planes (~0.3 MB each at 12 MP with s = 12)
  instead of two full-res planes (96 MB).

- [ ] **Step 2: Update the `lens_pipeline.dart` header**: the parameter list
  entry for `structure` ("0..100") becomes "-100..+100, signed"; the slot map
  entry for slot 8 mentions the signed range.

- [ ] **Step 3: Update the `lens_filter.frag` header**: the stage-order comment
  mentions the guided-filter structure stage and the 5th sampler.

- [ ] **Step 4: Verify**

  Run: `flutter test && flutter analyze && flutter test test/shader_compile_test.dart`
  Expected: all tests pass, no analyzer issues, the shader compiles.

- [ ] **Step 5: Commit**

  ```bash
  git add lib/features/imaging/pipeline shaders/lens_filter.frag
  git commit -m "docs(structure): document the guided-filter structure pipeline"
  ```
