# Structure as real local contrast (base/detail separation)

Status: draft for approval. No Git repository exists in this checkout; edits and
validation happen in place.

## 1. Problem

`Structure` is currently NOT a structure/texture control:

- GPU preview (`shaders/lens_filter.frag:553-574`): a 4-tap 1-pixel cross blur of
  the RAW source in RGB, `detail = clamp(raw - blur, ±0.2)`, masked by a
  double-smoothstep midtone window, added to the graded pixel.
- CPU export (`lib/features/imaging/pipeline/lens_cpu.dart:747-753, 956-976`):
  a 5x5 (radius 2) separable BOX blur of the RAW luma, `detail =
  clamp(rawLuma - blurLuma, ±0.2)`, same midtone window, added equally to R, G
  and B.

Three defects follow from that:

1. The radius is 1-2 pixels, so the effect operates on pixel edges only. That
   is sharpening, not structure. Capture One's Structure slider explicitly
   works on the SMALLER scale (fine texture: foliage, fabric, crumbs), while
   Clarity works on larger transitions; Adobe's Texture slider targets a
   frequency band, not edges. Neither is a 1-2 px high-pass.
2. The blur is a plain box/gaussian, not edge preserving, so it produces
   halos around strong edges and doubles contrast there.
3. Preview and export use different kernels and different channels (RGB cross
   vs luma box) and different radii, so the exported file does not look like
   the preview.

The user asked for the professional definition: a local-contrast / base-detail
decomposition on the luminance channel, with an edge-preserving blur
(guided/bilateral), a parabolic midtone mask `4 * L * (1 - L)`, and the result
returned into the original colour range.

## 2. Reference behaviour (research)

- Capture One (Clarity tool): Clarity = larger-scale local contrast,
  Structure = smaller-scale texture; both work on brightness, both can be
  negative (softening).
- Adobe (Lightroom/Camera Raw): Clarity uses a bilateral filter approximating
  a 5-10 px radius difference; Texture (patent 11,423,649) splits the image
  into frequency bands with an adaptive sigma scaled by the image resolution.
- darktable: local contrast is computed on the L channel of Lab only, via a
  local laplacian or a bilateral grid, and its scene-referred module boosts
  the EV difference between the smoothed and the local luminance (values > 1
  enhance features) - i.e. the effect is multiplicative, not additive.
- He & Sun, Guided Filter (ECCV 2010) and Fast Guided Filter (2015): the
  reference edge-preserving decomposition `detail = I - guidedFilter(I)`, O(N),
  no halos, no gradient reversal. Fast Guided Filter subsamples and upsamples
  the smoothed coefficient maps.

## 3. Algorithm (identical in preview and export)

Stage position is unchanged: after shadows/highlights, before the LUT, applied
to the GRADED pixel. The base/detail map is derived from the RAW source (as
today), so it is computed once per photo and never recomputed while a slider
moves.

Per pixel:

```
Yraw = 0.299*Rraw + 0.587*Graw + 0.114*Braw      // RAW source luma
q    = clamp(a(x,y) * Yraw + b(x,y), 0, 1)        // edge-preserving BASE
dEV  = clamp(ln(max(Yraw,1e-3) / max(q,1e-3)), -1, 1)   // local log-contrast
M    = 4 * q * (1 - q)                            // parabolic midtone mask
E    = clamp(amount * GAIN * M * dEV, -0.7, 0.7)  // signed exponent
RGB' = RGB_graded * exp(E)                        // back into the colour range
```

Why this shape:

- `q` comes from a GUIDED FILTER (self-guided, `p = I = Yraw`), so it follows
  strong edges (the local linear model keeps them) and flattens texture. The
  detail map therefore contains texture, not edges: no halos, no edge
  sharpening, no gradient reversal.
- `dEV` in log space makes the boost EXPOSURE INDEPENDENT (darktable's
  principle): the same texture in shadow and in light is boosted by the same
  relative amount, and the grade applied before the stage is not broken.
- `E * dEV` scales the local log-contrast symmetrically around the base, so a
  positive amount increases local contrast and a negative amount softens the
  texture while keeping the edges (Capture One's negative Structure).
- `M = 4*q*(1-q)` is the requested parabolic midtone mask: exactly 0 at black
  and at white, 1 at middle grey. It is computed from the BASE luma `q`, not
  from the graded pixel, so the mask does not flicker with the texture itself.
- The stage multiplies the GRADED RGB by `exp(E)`. This is a hue- and
  saturation-preserving scale (the "hue-preserving brightness scale" used by
  professional clarity tools): the luma of the pixel scales by the same factor
  while the channel RATIOS - and therefore hue and saturation - are
  untouched. The current code adds the detail equally to R, G and B, which
  changes the balance between luma and chroma (desaturates).
- `q` is clamped to [0,1] before the mask: the guided filter's local linear
  model is unbounded and can return q slightly outside the range near a hard
  edge, which would make the parabolic mask negative and FLIP the sign of the
  effect there.
- The exponent is clamped to [-0.7, 0.7] (multiplier in
  `[exp(-0.7), exp(0.7)]` = [0.4966, 2.0138], i.e. about [0.5, 2.0]) so that a
  pathological input can never blow a pixel out.
- At `amount = 0` the multiplier is exactly `exp(0) = 1`, so the stage is an
  exact no-op (the export path skips it entirely).

### 3.1 Guided filter (the base layer)

Self-guided filter computed on a subsampled luma grid (Fast Guided Filter):

```
Ylow   = boxDownsample(Yraw, s)                  // luma at 1/s resolution
mY     = boxFilter(Ylow,   r/s)                  // sliding-window box, O(N)
mYY    = boxFilter(Ylow^2, r/s)
var    = max(mYY - mY*mY, 0)
a0     = var / (var + eps)                       // eps = kStructureEps
b0     = mY * (1 - a0)
a      = boxFilter(a0, r/s)
b      = boxFilter(b0, r/s)
```

At full resolution `a` and `b` are sampled bilinearly and `q = a*Yraw + b`.
The subsampled coefficients are exactly what Fast Guided Filter upsamples, so
the preview and the export run the SAME filter.

### 3.2 Parameters

| Constant | Value | Meaning |
| --- | --- | --- |
| `kStructureRadiusFrac` | 0.0075 | radius = frac * min(w, h), so the texture scale is identical at any resolution (Adobe scales its sigma by resolution too). 1080 px -> 8 px, 3000 px -> 23 px (22.5 rounds away from zero). Clamped to [2, 96]. |
| `kStructureLowRadius` | 2 | The guided filter's radius in the LOW-RES grid. The subsample ratio is derived from it: `s = clamp(round(r / 2), 1, 16)`, so the low-res radius is always ~2 texels. This is what makes the preview and the export run the SAME transfer function: at 1080 px s = 4, at 3000 px s = 12, and the effective window is 5 low-res texels = 1.85%-2.0% of the frame. |
| `kStructureEps` | 0.01 | Guided-filter regularisation. Large enough that a strong edge keeps its contrast in the base (no halo), small enough that texture falls into the detail map. |
| `kStructureGain` | 2.5 | Slider 100 -> the local log-contrast is multiplied by about `exp(2.5 * M * dEV)`; for a typical texture (|dEV| ~ 0.15, M ~ 0.9) that is ~1.4x, i.e. ~40% more local contrast. Tunable constant. |
| `kStructureDetailClamp` | 1.0 | Clamp of `dEV` (natural-log units) before it enters the exponent. |

`amount` is SIGNED: the slider is bipolar, -100..+100.

### 3.3 Radius consistency between preview and export

The preview raster is at most 1080 px on the long side and the export runs on
the full-resolution file. Because the radius is a fraction of the short side
AND the low-res radius is pinned to ~2 texels, both operate on the SAME
relative texture scale and with the SAME filter transfer function.

## 4. Module layout

New:

- `lib/features/imaging/structure/structure_filter.dart` - pure Dart (no
  Flutter imports, isolate-safe). Contains:
  - `StructureMaps` (the low-res `a`/`b` planes, their size, the subsample
    ratio and the full-res size they belong to);
  - `computeStructureMaps(...)` (guided filter over an RGB or luma plane);
  - `sampleStructureBase(...)` (the ONE bilinear sampling convention, shared
    by the export path and mirrored 1:1 in GLSL: texel-centre mapping
    `fx = (x + 0.5) * lw / w - 0.5`, clamped edges);
  - `packStructureMaps(...)` (packs the maps for the preview texture);
  - the constants listed above.
- `lib/features/imaging/cache/structure_cache.dart` - mirrors `PreviewCache`:
  LRU map keyed by (content hash, target size, square flag) -> the packed
  texture bytes. The guided filter runs in `Isolate.run` so the UI thread
  never blocks.

Changed:

- `shaders/lens_filter.frag` - new sampler `uStructureMaps` (slot 4) and a
  rewritten structure stage; `uStructure` becomes signed.
- `lib/features/imaging/widgets/shader_preview.dart` - binds slot 4, keeps
  the 1x1 neutral stub until the real maps arrive.
- `lib/features/imaging/pipeline/lens_cpu.dart` - the structure stage uses the
  shared module; the old 5x5 box luma blur is deleted.
- `lib/features/imaging/pipeline/lens_pipeline.dart` - `structureNormalized`
  clamps to -1..1 instead of 0..1.
- `lib/features/adjust/cards/structure/structure_card.dart` - range -100..100
  (the base class then enables neutral snap).
- `lib/features/editor/logic/editor_state.dart` - `setStructure` clamps
  -100..100.
- `lib/features/adjust/adjust_state.dart` - doc comment.

## 5. Preview path (GPU)

The base layer does NOT depend on any slider value, so it is computed once per
photo and uploaded as a texture.

### 5.1 Which pixels the base is computed from

The preview display raster is a JPEG q88 RE-ENCODE of the downscaled source
(`PreviewCache._downscale`). Re-encoding injects fresh 8x8 DCT blocking, which
is exactly the kind of high-frequency content the detail map amplifies - so
computing the base from that raster would make the preview visibly blockier
than the export.

Therefore the base is computed from the ORIGINAL source bytes, decoded by the
engine directly to the preview's dimensions (no JPEG round trip):

1. The preview raster's dimensions are known (the decoded `ui.Image`).
2. `StructureCache.mapsFor(sourceBytes, targetW, targetH, square: ...)`
   decodes the source with `ui.instantiateImageCodec(sourceBytes,
   targetWidth: targetW, targetHeight: targetH)` (engine-side downscale, no
   re-encode), reads the RGBA bytes, and for the square thumbs crops the same
   centred square that `PreviewCache.squarePreviewBytes` crops.
3. The RGBA bytes go to an isolate that computes the luma, the guided filter
   and the packed maps.

If the source cannot be decoded (HEIC, corrupt file), the cache falls back to
the preview raster bytes, and if that fails too, the neutral 1x1 stub stays
bound (the stage is a no-op).

Geometry: the maps are sampled by UV, so they stay aligned with the display
even though the base raster may have a different pixel size than the preview
raster (the UV mapping is resolution independent).

### 5.2 Texture format

`a` and `b` are stored in one RGBA8888 texture:

- R = `a` (8 bit). Its quantisation contributes `da * Yraw` to q, i.e. an error
  proportional to the local deviation, not to q - negligible (< 0.5%).
- G, B = `b` as a 16-bit big-endian pair. `b` enters q ABSOLUTELY, so an 8-bit
  `b` would inject a 1/255 error into q, which is a 4% relative error at
  q = 0.1 (deep shadow) - that would show up as smooth contour banding in the
  shadows. 16 bits bring it to ~1.5e-5.
- A = 255.

The GPU filters the texture linearly. Filtering the two bytes of the 16-bit
pair separately is exact except at the byte-wrap positions (1/256 of the
range), where the error is bounded by 0.4% of the value - below 1 LSB of the
final image.

### 5.3 Shader stage (replacing lines 553-574)

```glsl
uniform sampler2D uStructureMaps;   // slot 4: R = a, G:B = b (16 bit)

float sAmt = clamp(uStructure, -1.0, 1.0);
if (abs(sAmt) > 1e-4) {
  float rawL = dot(raw, vec3(0.299, 0.587, 0.114));
  vec4 mt = texture(uStructureMaps, uv);
  float a = mt.r;
  float b = (mt.g * 255.0 * 256.0 + mt.b * 255.0) / 65535.0;
  float q = clamp(a * rawL + b, 0.0, 1.0);
  float dEV = clamp(log(max(rawL, 1e-3) / max(q, 1e-3)), -1.0, 1.0);
  float midMask = 4.0 * q * (1.0 - q);
  float e = clamp(sAmt * kStructureGain * midMask * dEV, -0.7, 0.7);
  graded *= exp(e);
}
```

`raw` is the RAW source (`texture(uImage, uv)`), `graded` is the graded pixel
at the current stage position.

**Neutral stub**: while the maps are still being computed, sampler 4 holds a
cached 1x1 texture with R = 255 (a = 1), G = 0, B = 0 (b = 0). Then
`q = rawLuma`, `dEV = 0` -> the exponent is 0 -> the stage is an EXACT no-op.
The preview never shows a wrong frame, it simply shows the un-structured
image for a few frames after opening a photo.

## 6. Export path (CPU)

In `applyLensGrade`:

- When `structureAmt != 0`, compute the maps from the RAW `src` RGB with the
  shared module - two low-res float planes, no full-res luma buffer is needed
  (the downsample reads the RGB directly). At 12 MP (4000x3000) the radius is
  23 px, s = 12 and the low grid is 334x250, so the planes are ~0.33 MB each
  (float32), versus the 96 MB the old full-res box blur needed.
- In the per-pixel loop, sample `a`/`b` bilinearly (the shared convention),
  form `q`, `dEV`, `M` and the exponent, and multiply the graded pixel.
- The old `_boxBlurLumaFromRgb` helper and `kLensStructureBlurRadius` are
  deleted.

Speed: the extra per-pixel work is one bilinear fetch of two floats, one
`log`, one `exp` and a handful of multiplies. The `log`/`exp` pair over 12 MP
in Dart is the main cost; if profiling shows it matters, both can be replaced
by a mirrored rational approximation in Dart and GLSL.

## 7. Preview / export parity

- Same filter, same constants, same sampling convention, same formula.
- The preview maps are quantised (8-bit `a`, 16-bit `b`); the export keeps
  floats. The induced error in q is below 1 LSB of the final image.
- The preview base is built from the source downscaled to the preview's
  dimensions, the export base from the full-resolution source: the preview
  cannot show texture finer than its own resolution. This is inherent to every
  stage in the app and is documented, like the existing blur/LUT/rays
  divergences.
- The radius is resolution-relative and the low-res radius is pinned, so the
  texture SCALE and the filter transfer function match.

## 8. UI changes

- `StructureCard`: `min = -100`, `max = 100`. The shared slider then snaps to
  the neutral 0 (the base class enables neutral snap for bipolar cards).
- Negative values soften the texture (Capture One Structure negative).
- Presets keep their values (`punchy` 30, `muted` 10) and stay valid on a
  bipolar slider.
- `LensParams.structureNormalized` -> `(structure / 100).clamp(-1.0, 1.0)`.
- `editor_state.setStructure` clamps to -100..100.

## 9. Tests

New unit tests for the shared module:

- guided filter on a synthetic STEP image: the base follows the step (no
  halo), the detail map is ~0 on flat areas and small at the edge;
- guided filter on a synthetic TEXTURE image: the detail map is non-zero and
  proportional to the texture;
- the parabolic mask: 0 in black, 0 in white, ~1 at middle grey;
- the mask never goes negative when the guided filter overshoots;
- signed amount: +100 increases the local contrast of a texture, -100
  decreases it, 0 is an exact no-op;
- the maps are resolution-relative: the same synthetic texture scaled to two
  resolutions produces the same relative effect;
- the packed texture round-trip stays within the documented 1-LSB budget;
- a tiny image (16x16) must not degenerate: the subsample ratio adapts.

Updated tests:

- `test/first_open_hardening_test.dart`: `structureNormalized` clamps to
  -1..1; `setStructure(-150)` clamps to -100.
- `test/lens_cpu_test.dart`: the existing "structure 0 vs 100 differ" test
  keeps working; a new test asserts that structure 0 is byte-identical to no
  structure at all, and that a negative amount reduces the local contrast of a
  synthetic texture.

No GPU test exists in this project (the preview path is not covered by widget
tests), so the shader parity is maintained by mirroring the formula 1:1 and
by keeping the constants in one documented place.

## 10. Non-goals

- No new "Clarity" slider (large-scale local contrast) and no "Scale" slider:
  the radius is automatic, as decided.
- No scene-referred / linear-light processing: the pipeline stays in the
  display-referred space it already uses.
- No native (C++/Rust/FFI) code.
- The base layer is still computed from the RAW source, so the structure does
  not react to later grading changes. Changing that would require recomputing
  the base on every grade tick, which is out of scope.

## 11. Resolved review questions

These came out of a builder review of the first draft; each is answered above.

1. **Low-res window radius < 1 texel** (degenerate variance collapse, and
   preview/export landing in different regimes) -> the subsample ratio is
   derived from the radius (`s = round(r / 2)`), so the low-res radius is
   always ~2 texels and tiny images fall back to s = 1.
2. **8-bit quantisation of the maps** -> `b` is stored as 16 bit, `a` as 8 bit;
   the error budget is documented (below 1 LSB).
3. **Base computed from the q88 preview raster** (double compression amplified)
   -> the base is computed from the ORIGINAL source, downscaled by the engine,
   with a fallback to the preview raster.
4. **The `Yg2 / Yg` ratio form** (would darken near-black pixels even at
   amount 0) -> the stage multiplies the graded RGB by `exp(E)` directly.
5. **Mixed log/stop units and an unbounded exponent** -> `dEV` is in natural
   log units everywhere, the exponent is clamped to [-0.7, 0.7] (multiplier in
   [exp(-0.7), exp(0.7)] = [0.4966, 2.0138]) and the constants are stated in
   the table.
6. **`q` outside [0,1] flipping the sign of the mask** -> `q` is clamped to
   [0,1] before the mask and the log.

## 12. Open items

None: the slider range, the preview strategy and the radius policy were
decided with the user (bipolar slider, shared base via a 5th sampler,
automatic resolution-relative radius).
