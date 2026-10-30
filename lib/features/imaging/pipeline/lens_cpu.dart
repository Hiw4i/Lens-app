import 'dart:math' as math;
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_apply.dart';
import 'package:lens/features/crop/crop_cpu.dart';
import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/filters/lut_definition.dart';
import 'package:lens/features/imaging/structure/structure_filter.dart';
import 'package:lens/features/rays/rays_math.dart';
import 'package:lens/features/selective/selective_mask.dart';

/// CPU export grade for Task 1.3 (Stage 1).
///
/// Pure-Dart pixel pipeline — this file imports `dart:*` and
/// `package:image` only (no Flutter, no Riverpod), so every top-level
/// function here is safe to run inside [Isolate.run].
///
/// Entry point is [applyLensGrade]. It takes the grade as a plain
/// `List<double>` in [LensParams.toUniforms] slot order
/// (exposure, contrast, saturation, temp, tint, shadows, highlights,
/// intensity, structureNormalized, filterStrength + the 9 Enhance slots
/// + the 13 Task 4.2 Selective slots + the 5 Task 6.2 Blur slots +
/// the 10 Task 7.2 Rays slots + the 8 derived auto-grade slots + the
/// built-in look — 56 total) plus the categorical [filterId] (`LensFilterId.index`, 0..8) as
/// a separate `int` instead of a [LensParams] instance on purpose:
/// `LensParams` lives in a library that transitively imports
/// `flutter_riverpod`, which must not be loaded in the export isolate.
/// Callers map via `params.toUniforms()` + `params.filterId` (see
/// `ExportService.export`).
///
/// The uniform vector is parsed by BLOCK, not by absolute index: the
/// derived auto-grade tail is APPENDED after the rays block, so every
/// historical prefix (the legacy 9/10/19/32/37 and the previous 47-slot
/// current layout) still points at exactly the same fields it always did.
/// A legacy vector therefore keeps grading byte-for-byte and the derived
/// stages simply stay neutral.
///
/// Formula parity with `shaders/lens_filter.frag` (Adjust v1 + Blur +
/// Enhance + LUT + Selective):
/// per-pixel order is blur FIRST (separable gaussian — 3x-box O(n)
/// approximation since Task 6.3b — of the raw source,
/// composited by the feathered/inverted subject mask weight
/// `t = clamp(m + (1 - s))`: `base = mix(blurred, raw, t)`) -> enhance
/// ([applyEnhancePixel] on the composite base: G-anchored WB mix,
/// auto-exposure gain, skin-gated tone curve with the highlight shoulder
/// and the S-curve, skin-gated dehaze push, shadow lift, vibrance and
/// saturation, split toning, and the built-in cinematic look)
/// -> exposure gain (pow(2, e)) -> highlight rolloff
/// (`expAmt = clamp(e,0,2)/2`, `hlRoll = smoothstep(0.7,1.0,luma)`,
/// `mix(g, g/(g+0.15)*1.15, expAmt*0.5*hlRoll)`) -> contrast around 0.5
/// -> saturation luma-mix -> temp/tint offsets
/// (`vec3(0.10,-0.02,-0.12)` / `vec3(0.04,-0.06,0.04)`) ->
/// shadows/highlights luma-masked `*0.6` (luma re-measured after WB)
/// -> structure local contrast (guided-filter base/detail, `exp(E)` scale
/// of the graded RGB) -> LUT trilinear sample mixed by
/// filterStrength -> selective local grade (exp gain + the SAME highlight
/// rolloff, then con, then sat — structure inside the mask skipped, like
/// the shader) mixed by `maskW * selStrength` -> rays shafts
/// (low-res 24-tap march of raw-scene luma toward the source, streak at
/// full resolution, screen-blended over the graded pixel via
/// [applyRaysPixel] — like the shader, AFTER selective so shafts lie over
/// the finished grade) -> intensity mix with raw
/// -> clamp -> crop + straighten (the same final framing transform the
/// preview draws) -> JPG q95.
/// The order (blur first, then selective after LUT, rays after selective,
/// before intensity) matches the shader 1:1; only the blur kernel, the
/// LUT interpolation, the rays march resolution and the structure maps'
/// quantisation / preview-size base differ (see divergences). Like the
/// shader, the structure base/detail maps and the
/// master mix read the RAW source (`raw` vs `base` split in the frag);
/// the rays march likewise gathers the RAW scene luma (taps `uImage`,
/// never the graded image).
///
/// Known divergences (documented, not bugs):
/// * Blur kernel: CPU uses a 3x-box approximation of the separable
///   gaussian (radius = `blurRadius * min(w,h)` clamped to
///   [kLensBlurRadiusPxMax], sigma = r*2/3 (the kernel the replaced
///   `img.gaussianBlur` used, so exports keep their spread), three
///   sliding-window box passes
///   with Kutskir box widths matching the gaussian variance) over RGB;
///   the preview shader uses a 7x7 true-gaussian gather at
///   sigma = 1.2*R/3 (see the frag), i.e. a TIGHTER kernel than the
///   CPU's. Same radius, same
///   feather/invert/composite math — visually close but NOT bit-identical.
///   The CPU kernel is the higher-quality reference (the preview taps are
///   a one-fragment approximation; two true passes are impossible there).
///   Extreme radii additionally clamp on CPU only (see the const docs).
/// * Blur without a mask (`blurMask256 == null` while blurMode != 0) is
///   NEUTRAL on CPU. The preview shader instead samples a cached 1x1
///   WHITE stub — which composites to raw as well (`m = 1` forces
///   `t = clamp(1 + (1 - s)) = 1`), i.e. both paths no-op, EXCEPT with
///   invert = 1, where the stub flips to an all-background full-frame
///   blur while the CPU stays neutral. Deliberate: a missing mask on
///   export means "no subject resolved" (the 256KB raster travels from the
///   UI via `ExportService`), so blurring the whole frame would be wrong.
///   The UI (Task 6.4) always binds a real mask when blur is active, so
///   the two paths agree in practice.
/// * Brush mode without a raster (`brush == null` while selMode is brush)
///   is NEUTRAL on CPU (mask weight 0 everywhere). The preview shader
///   instead samples a cached 1x1 WHITE stub, i.e. a full-frame grade.
///   Deliberate: a missing raster on export means "no brush strokes were
///   passed" (strokes travel as flat doubles and are rasterized in-isolate
///   by `ExportService`), so painting nothing must change nothing. The UI
///   (Task 4.5) always binds a real raster when brush mode is active, so
///   the two paths agree in practice.
/// * Structure: the SAME filter as the preview (`structure_filter.dart`:
///   the self-guided filter's low-res `a`/`b` maps, bilinear `q =
///   a*Yraw + b`, the parabolic midtone mask `4*q*(1-q)` and the signed
///   `exp(amount * GAIN * M * dEV)` scale of the graded RGB). The only
///   divergence is quantisation: the preview stores `a` at 8 bits and `b`
///   at 16 bits in the maps texture, the export keeps floats (q error
///   below 1 LSB), and the preview base comes from the SOURCE scaled to
///   the preview size while the export base comes from the full-res
///   source, so the preview cannot resolve texture finer than its own
///   raster (inherent to every stage here).
/// * LUT sampling: CPU does true trilinear interpolation of the N=16
///   coarse lattice (`LutTables.sampleLut`); the preview shader does
///   bilinear-between-slices on the N=64 8-bit atlas
///   (`applyLut` in the frag). Same grade function underneath, so the
///   looks match within ~1-2 LSB on smooth gradients; saturated,
///   high-curvature regions can diverge slightly more.
/// * Rays march resolution: the CPU marches on a box-downsampled luma
///   grid capped at [kLensRaysLowMaxDim] (long side) and bilinear-
///   upsamples ONLY the accum (low-frequency scene light); the streak is
///   angular (high-frequency) and is recomputed at FULL resolution per
///   pixel via `raysStreak(atan2, density)`. The preview shader marches
///   all 24 taps at full resolution with hardware-linear taps. Same
///   geometry (length * diagonal, eps-guarded normalize, decay-weighted
///   mean, screen blend), so the look matches in range and falloff but
///   individual shaft edges can differ slightly — compare ranges, never
///   bit-exact pixels (same caveat as the float64/float32 `sin`-hash
///   split documented in `rays_math.dart`).
/// * EXIF orientation: the `package:image` JPEG decoder bakes orientation
///   into pixels at decode time; for other formats with an EXIF
///   orientation flag an explicit guarded [img.bakeOrientation] is applied.
///   Formats `package:image` cannot decode (e.g. HEIC) throw
///   [LensCpuException].
/// * Output is always JPEG quality 95 (no alpha; transparent PNG sources
///   composite against black in the decoded RGB).
/// * CPU math is float64 vs the GPU's float32 — sub-LSB differences only.
///
/// Memory: source floats (3n) + blurred RGB copy (3n, only when the blur
/// stage is active — a full copy because the raw source must survive for
/// the structure maps and the master mix; the three box passes add one 3n
/// float scratch) + the structure coefficient maps (two low-res Float32
/// planes of
/// ceil(w/s)*ceil(h/s) texels, only when structure != 0: at 12MP with
/// s = 12 that is ~0.3MB each, i.e. well under 1MB for the pair instead
/// of the old 2n full-res luma blur, 96MB at 12MP; the filter's own
/// scratch is a handful of low-res Float64 planes (~0.64MB each at 12MP,
/// ~5-6MB while it runs, freed on return) +
/// decoded/out images (Uint8). Float32 peak is 6n = ~24 bytes/px without
/// the maps: ~24MB per 1MP, ~288MB transient at 12MP (4000x3000: src
/// 144MB + blurred 144MB). Blur alone adds +3n (~144MB at 12MP); the
/// 256x256 subject mask itself is 256KB. The rays stage adds at most two
/// lw*lh float buffers (downsampled luma + marched accum, long side capped
/// at [kLensRaysLowMaxDim] = 480: 2 * 480^2 * 4B ≈ 1.8MB worst case —
/// negligible next to the pipeline peak) plus O(w)/O(h)-free per-pixel
/// ALU (one bilinear upsample + one `raysStreak` per pixel). The LUT table
/// itself is 49KB
/// (N=16) and is generated once per filter id per isolate (see
/// [_lutCache]). Mobile OOM must be handled by the caller
/// ([ExportService] maps it to [ExportException]).
///
/// Speed (measured 1024x1024 PNG synthetic gradient, desktop; the
/// structure cost was re-measured after the Task 2 structure rework):
/// LUT gen (cold, N=16) 8ms once per id; grade-only 230-248ms;
/// structure +100 alone 347ms, i.e. ~+115ms/MP — the guided-filter maps
/// plus one `log`/`exp` pair per pixel, where the old 5x5 luma box blur
/// was ~noise at this size; the trilinear LUT stage costs ~240ms/MP
/// (structure +100 + cinematic measured 487ms before the rework).
/// Linear x11.45 extrapolation to 12MP (4000x3000,
/// pipeline is O(n)/px): grade-only ~2.8s, + ~2.9s for the trilinear LUT
/// stage (~240ms/MP), + ~1.4s for structure +100 (~115ms/MP), plus the JPG
/// encode. Blur
/// (Task 6.3b) is O(n) too: three sliding-window box passes (~36 cheap
/// ops/px total, radius-independent), measured ~110ms/MP at the 64px clamp
/// vs ~1600ms/MP for the naive O(n*r) separable gaussian it replaced
/// (129-tap kernel x2 passes x3 channels ≈ 774 mult-adds/px ≈ tens of
/// seconds at 12MP). Runs only with an active blur block AND a mask.
/// Rays (Task 7.3) is O(n) too: one O(n) box downsample of luma, a
/// 24-tap march on the ~230k-px low grid (~5.5M bilinear taps at 12MP,
/// resolution-independent), then one full-res pass (bilinear upsample +
/// `raysStreak` per pixel). Runs only with an armed rays block
/// (gate + strength); length <= 0 skips the low-res path entirely
/// (tap-free point glow, pure math per pixel).
const List<String> kLensUniformNames = <String>[
  'exposure',
  'contrast',
  'saturation',
  'temp',
  'tint',
  'shadows',
  'highlights',
  'intensity',
  'structure',
  'filterStrength',
  'enhR',
  'enhB',
  'enhBlack',
  'enhWhite',
  'enhDehaze',
  'enhHazeR',
  'enhHazeG',
  'enhHazeB',
  'enhanceStrength',
  // Task 4.2 Selective block (toUniforms indices 19..31 -> slots 21..33).
  // Applied by the CPU grade since Task 4.3 (selective stage after LUT,
  // before intensity, mirroring the frag). Mode 0 or strength 0 skips the
  // stage entirely, so identity stays an exact no-op by construction.
  'selMode',
  'selCx',
  'selCy',
  'selRadius',
  'selFeather',
  'selAngle',
  'selWidth',
  'selAspect',
  'selInvert',
  'selStrength',
  'selExp',
  'selCon',
  'selSat',
  // Task 6.2 Blur block (toUniforms indices 32..36 -> slots 34..38).
  // Applied on CPU since Task 6.3 FIRST (before enhance), mirroring the
  // frag stage order. Mode 0, radius 0, strength 0, or a null mask each
  // skip the stage bit-exact, so blur-neutral vectors stay exact no-ops
  // by construction (same philosophy as the selective mode-0 skip).
  'blurMode',
  'blurRadius',
  'blurFeather',
  'blurStrength',
  'blurInvert',
  // Task 7.2 Rays block (toUniforms indices 37..43 -> slots 39..45).
  // Applied on CPU since Task 7.3 AFTER selective and BEFORE the
  // intensity mix, mirroring the frag stage order. Gate off (rayOn < 0.5)
  // or zero strength skips the stage before any low-res work, so
  // rays-neutral vectors stay exact no-ops by construction (same
  // philosophy as the selective mode-0 skip): a rays-neutral 44-slot
  // vector grades byte-identical to its 37-slot prefix.
  'rayOn',
  'rayX',
  'rayY',
  'rayIntensity',
  'rayLength',
  'rayWarmth',
  'rayDensity',
  'rayMode',
  'rayAngle',
  'rayWidth',
  // Derived auto-grade tail (the professional 1-tap Enhance): the
  // auto-exposure gain, the Hermite S-curve contrast, the shadow lift,
  // the vibrance, the flat saturation, the split tone (shadows +
  // highlights) and the highlight shoulder. APPENDED at the end so every
  // historical uniform prefix keeps pointing at the same fields; all
  // neutral by default, so a legacy vector (or no analysis at all)
  // leaves them off.
  'enhExposure',
  'enhContrast',
  'enhShadowLift',
  'enhVibrance',
  'enhSaturation',
  'enhToneShadow',
  'enhToneHighlight',
  'enhHighlightRecover',
  // The built-in cinematic finish of the Enhance stage (30/100 at full
  // strength). Appended after the tail for the same reason.
  'enhLook',
];

/// Output JPEG quality for [applyLensGrade].
const int kLensExportJpegQuality = 95;

/// Blur gaussian radius clamp in pixels (Task 6.3).
///
/// `blurRadius` arrives as a fraction of min(w,h) (0..0.05, like the
/// shader); the CPU pixel radius is `(fraction * min(w,h)).round()` with a
/// floor of 1px for any positive fraction (the frag taps at any radius >
/// 0) and this ceiling. Rationale: a 12MP frame (min side 3000) at the max
/// 0.05 fraction asks for a 150px radius ≈ 9.3B mult-adds in naive
/// O(n*r) Dart — unbounded latency in the export isolate. The preview taps
/// at the unclamped radius, so extreme radii look slightly tighter on
/// export than in preview (documented divergence, same family as the
/// kernel approximation itself).
const int kLensBlurRadiusPxMax = 64;

/// Rays low-res march cap in pixels (Task 7.3).
///
/// The long side of the box-downsampled luma grid the 24-tap march runs
/// on. Rays gather low-frequency scene light, so marching at 480p and
/// upsampling only the accum is visually equivalent to a full-res march
/// (the angular streak — the only high-frequency term — is recomputed at
/// full resolution per pixel, never upsampled). Caps the march at
/// ~480*270*24 ≈ 3.1M taps (16:9) whatever the source size, and the two
/// low buffers at ~1.8MB (see the file-level memory note).
const int kLensRaysLowMaxDim = 480;

/// Rays march tap count (Task 7.3). Mirrors the frag `for (i < 24)` loop
/// literally (`t = i/24`, `accum += light * decay(t)/24`).
const int kLensRaysMarchSteps = 24;

/// Error thrown by [applyLensGrade] for undecodable/empty input.
/// Sendable (message-only) so it survives the isolate boundary.
class LensCpuException implements Exception {
  LensCpuException(this.message);
  final String message;

  @override
  String toString() => 'LensCpuException: $message';
}

/// GLSL `smoothstep` semantics: hermite interpolation of
/// `clamp((x - edge0) / (edge1 - edge0), 0, 1)`.
/// Degenerate `edge0 == edge1` returns 0.0 (GLSL leaves it undefined).
double lensSmoothstep(double edge0, double edge1, double x) {
  if (edge0 == edge1) return 0.0;
  final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

double _clamp01(double v) => v.clamp(0.0, 1.0);

/// Hyperbolic tangent (Dart's `dart:math` lacks it). Used by the
/// professional S-curve contrast.
double _tanh(double x) {
  final double e = math.exp(2.0 * x);
  return (e - 1.0) / (e + 1.0);
}

/// Per-isolate LUT cache: filter id -> coarse N=16 table (49KB each).
///
/// Lookup tables are generated inside the export isolate from the
/// categorical id (sending a ready `Float32List` across the isolate
/// boundary would copy ~1MB for an N=64 table; generating the N=16 table
/// in-isolate costs a few ms once and is then reused for every pixel).
/// A fresh isolate starts with an empty cache, so there is no cross-export
/// staleness by construction.
final Map<int, Float32List> _lutCache = <int, Float32List>{};

/// Returns the cached coarse LUT for [filterId], generating it on first use.
Float32List _lutFor(int filterId) => _lutCache.putIfAbsent(
  filterId,
  () => LutTables.generateLut(LensFilterId.values[filterId]),
);

/// Bilinear sample of a row-major `size x size` brush [mask] at normalized
/// uv ([u], [v]) in 0..1, clamped edges. Mirrors the GPU linear filtering
/// of the brush texture. Top-level for testability; pure (no Flutter).
double sampleBrushMask(Float32List mask, int size, double u, double v) {
  final double gx = u * size - 0.5;
  final double gy = v * size - 0.5;
  final int x0 = gx.floor();
  final int y0 = gy.floor();
  final double fx = gx - x0;
  final double fy = gy - y0;
  final int x0c = x0.clamp(0, size - 1);
  final int y0c = y0.clamp(0, size - 1);
  final int x1c = (x0 + 1).clamp(0, size - 1);
  final int y1c = (y0 + 1).clamp(0, size - 1);
  final double a = mask[y0c * size + x0c];
  final double b = mask[y0c * size + x1c];
  final double c = mask[y1c * size + x0c];
  final double d = mask[y1c * size + x1c];
  return ((a * (1.0 - fx) + b * fx) * (1.0 - fy) +
          (c * (1.0 - fx) + d * fx) * fy)
      .clamp(0.0, 1.0);
}

/// Applies the Lens Adjust + LUT + Selective grade on CPU.
///
/// [srcBytes] is any format `package:image` can decode.
/// [uniforms] must be 9, 10, 19, 32, 37, 47, 55, or 56 doubles in
/// [LensParams.toUniforms] order (see [kLensUniformNames]): the legacy
/// 9-slot form (pre-2.3, no filterStrength) defaults the LUT strength to
/// 1.0 when a non-none [filterId] is passed; the legacy 10-slot form
/// (2.3..3.1, no Enhance block) runs with the enhance stage skipped; the
/// legacy 19-slot form (3.2..4.1, no Selective block) runs with the
/// selective stage skipped; the legacy 32-slot form (4.2..6.1, no Blur
/// block and no Rays block) runs with the blur stage skipped; the legacy
/// 37-slot form (6.2..7.1, Blur block but no Rays block) runs with the
/// rays stage skipped; the current
/// 44-slot form carries the Task 3.2 Enhance analysis in indices 10..18, the Task 4.2
/// Selective block in indices 19..31 (selMode, selCx, selCy, selRadius,
/// selFeather, selAngle, selWidth, selAspect, selInvert, selStrength,
/// selExp, selCon, selSat) and the Task 6.2 Blur block in indices 32..36
/// (blurMode, blurRadius, blurFeather, blurStrength, blurInvert), applied
/// FIRST here since Task 6.3 (the raw background is blurred, then the
/// whole grade lands on the composite — portrait-mode order, like the
/// frag). The Task 7.2 Rays block in indices 37..43 (rayOn, rayX, rayY,
/// rayIntensity, rayLength, rayWarmth, rayDensity, rayMode, rayAngle,
/// rayWidth) is applied here since
/// Task 7.3 AFTER selective and BEFORE the intensity mix, like the frag.
/// A blur-active 44-slot vector
/// WITHOUT [blurMask256] still grades byte-identical to its 32-slot
/// prefix (null mask = neutral); a rays-neutral 44-slot vector (gate off
/// or zero strength) grades byte-identical to its 37-slot prefix
/// (gate/strength skip before any rays work, so parked garbage in the
/// remaining rays slots is tolerated).
/// Since Task 4.4 index 26
/// (selAspect) is IGNORED and recomputed as the decoded frame `w/h`
/// (aspectOverride — visual parity with the preview, whose painter writes
/// the paint size aspect into shader slot 28 every frame).
/// [filterId] is `LensFilterId.index` (0 = none, identity); out-of-range
/// values throw [LensCpuException]. Returns JPEG bytes (quality 95).
///
/// [brush] is the rasterized brush mask for selMode 3 (brush), as a record
/// `({Float32List mask, int size})` with a row-major `size x size` 0..1
/// mask (see `rasterizeBrushMask`); it is bilinear-sampled at the image uv
/// ([sampleBrushMask]). Ignored unless the 32-slot selective block selects
/// brush mode with non-zero strength. Brush mode with `brush == null`
/// grades nothing (neutral) — this deliberately differs from the preview
/// shader's 1x1 white stub (see the file-level divergences).
/// A shape mismatch (`mask.length != size * size`, `size <= 0`) in an
/// otherwise-active brush stage throws [LensCpuException].
///
/// [blurMask256] is the subject mask for blurMode 1/2 (auto ML / manual
/// raster): a row-major SQUARE 0..1 mask (1 = subject, stays sharp) at any
/// square resolution — production always passes 256x256 (`kSubjectMaskSize`:
/// the `BlurCache.get` output or the 6.4 manual raster, resolved by the UI
/// and copied across the isolate boundary once per export by
/// `ExportService`), bilinear-sampled at the image uv like the GPU linear
/// filter (see [sampleBrushMask]). Null (or an inactive blur block: mode
/// 0, radius 0, strength 0, legacy 32-slot vector) skips the stage
/// bit-exact. Mode != 0 WITHOUT a mask is likewise neutral — deliberately
/// NOT the preview's 1x1 white stub (see the file-level divergence note).
/// A non-square mask in an otherwise-active stage throws
/// [LensCpuException]; inactive stages ignore the mask entirely (like
/// mode-0 selective tolerates garbage slots).
///
/// Top-level so it can be referenced from `Isolate.run`.
///
/// [crop] is the optional crop + straighten geometry, applied AFTER the
/// grade. That order is what makes masks, rays and selective geometry agree
/// with the preview: the user places them in the source frame (the frame the
/// shader grades), and cropping is only a final framing transform. It rides
/// at the end of the optional POSITIONAL list on purpose: Dart allows either
/// an optional positional group or an optional named group, never both, and
/// appending a positional keeps every existing call site source-compatible.
Uint8List applyLensGrade(
  Uint8List srcBytes,
  List<double> uniforms, [
  int filterId = 0,
  ({Float32List mask, int size})? brush,
  Float32List? blurMask256,
  CropGeometry? crop,
]) {
  if (srcBytes.isEmpty) {
    throw LensCpuException('Empty source image.');
  }
  // The legacy 32-slot form (pre-6.2: selective but no blur block and no
  // rays block) is still accepted and runs with the blur AND rays stages
  // skipped — like a blur-neutral 32-slot vector (mode 0 / radius 0 /
  // strength 0 / null mask), which grades byte-identical to its 32-slot
  // prefix. The legacy 37-slot form (6.2..7.1: blur block but no rays
  // block) likewise runs with the rays stage skipped, byte-identical to
  // a rays-neutral 47-slot vector with the same 37-slot prefix. The
  // legacy 47-slot form (the previous current layout: the 9-slot Enhance
  // block) runs with the derived auto-grade tail neutral.
  if (uniforms.length != 9 &&
      uniforms.length != 10 &&
      uniforms.length != 19 &&
      uniforms.length != 32 &&
      uniforms.length != 37 &&
      uniforms.length != 47 &&
      uniforms.length != 55 &&
      uniforms.length != kLensUniformNames.length) {
    throw LensCpuException(
      'Expected 9 (legacy), 10 (legacy + filterStrength), 19 (legacy + '
      'enhance), 32 (legacy + selective), 37 (legacy + blur), 47 (legacy + '
      'rays), 55 (previous layout without the enhance look) or '
      '${kLensUniformNames.length} '
      'uniforms (LensParams.toUniforms order), got ${uniforms.length}.',
    );
  }
  if (filterId < 0 || filterId >= LensFilterId.values.length) {
    throw LensCpuException(
      'filterId must be 0..${LensFilterId.values.length - 1} '
      '(LensFilterId.index), got $filterId.',
    );
  }

  final double exposure = uniforms[0];
  final double contrast = uniforms[1];
  final double saturation = uniforms[2];
  final double temp = uniforms[3];
  final double tint = uniforms[4];
  final double shadows = uniforms[5];
  final double highlights = uniforms[6];
  final double intensity = uniforms[7].clamp(0.0, 1.0);
  final double structureAmt = uniforms[8].clamp(-1.0, 1.0);
  final double filterStrength = uniforms.length >= 10
      ? uniforms[9].clamp(0.0, 1.0)
      : 1.0;

  // Block layout. The derived auto-grade tail is APPENDED after the rays
  // block, so every historical uniform prefix (the legacy 9/10/19/32/37
  // and the previous 47-slot current layout) still points at exactly the
  // same fields it always did. A legacy vector therefore keeps grading
  // byte-for-byte and the derived stages simply stay neutral.
  final bool currentLayout =
      uniforms.length == 55 || uniforms.length == kLensUniformNames.length;
  final bool hasLook = uniforms.length == kLensUniformNames.length;
  final bool hasSelective =
      uniforms.length == 32 ||
      uniforms.length == 37 ||
      uniforms.length == 47 ||
      currentLayout;
  final bool hasBlur =
      uniforms.length == 37 || uniforms.length == 47 || currentLayout;
  final bool hasRays = uniforms.length == 47 || currentLayout;
  const int enhanceTailBase = 47;

  // Enhance block (uniforms[10..18] -> slots 12..20). Legacy
  // 9/10-slot vectors predate it and run with the stage skipped
  // (strength 0). [EnhanceAnalysis] is a pure value type, so building it
  // here costs nothing and keeps the isolate boundary Sendable-safe
  // (plain doubles in, no shared objects). The 19-slot legacy form
  // (pre-4.2) carries enhance but no selective block.
  EnhanceAnalysis enhance = EnhanceAnalysis.none;
  double enhanceStrength = 0.0;
  final bool hasEnhance =
      uniforms.length == 19 ||
      uniforms.length == 32 ||
      uniforms.length == 37 ||
      uniforms.length == 47 ||
      currentLayout;
  if (hasEnhance) {
    enhance = EnhanceAnalysis(
      wbGainR: uniforms[10],
      wbGainB: uniforms[11],
      blackPt: uniforms[12],
      whitePt: uniforms[13],
      dehaze: uniforms[14],
      hazeColor: (uniforms[15], uniforms[16], uniforms[17]),
      // The derived auto-grade tail only exists in the current layout; a
      // legacy block leaves every one of these neutral, which makes each
      // new stage an exact identity.
      exposureGain: currentLayout ? uniforms[enhanceTailBase] : 1.0,
      contrast: currentLayout ? uniforms[enhanceTailBase + 1] : 0.0,
      shadowLift: currentLayout ? uniforms[enhanceTailBase + 2] : 0.0,
      vibrance: currentLayout ? uniforms[enhanceTailBase + 3] : 0.0,
      saturation: currentLayout ? uniforms[enhanceTailBase + 4] : 0.0,
      toneShadow: currentLayout ? uniforms[enhanceTailBase + 5] : 0.0,
      toneHighlight: currentLayout ? uniforms[enhanceTailBase + 6] : 0.0,
      highlightRecover: currentLayout ? uniforms[enhanceTailBase + 7] : 0.0,
      // The built-in cinematic finish. A 55-slot vector predates it, so it
      // stays 0 there (exact identity, like every other appended stage).
      look: hasLook ? uniforms[enhanceTailBase + 8] : 0.0,
    );
    enhanceStrength = uniforms[18].clamp(0.0, 1.0);
  }
  // Enhance's own clarity boost, ADDED to the user's Structure slider and
  // run through the SAME guided-filter stage (local contrast, not a
  // sharpen). It is 0 whenever the enhance stage is off, so a neutral
  // vector stays a bit-exact no-op.
  final double structureAmtEff =
      (structureAmt + kEnhanceStructureBoost * enhanceStrength).clamp(
        -1.0,
        1.0,
      );
  // Task 4.2 Selective block (uniforms[19..31] -> slots 21..33), applied
  // since Task 4.3 AFTER the LUT and BEFORE the intensity mix, mirroring
  // the frag stage order. The mode test is range-based like the shader
  // (`< 0.5` off; analytic branches are evaluated per-pixel below):
  // mode < 0.5 or strength 0 skips the whole stage before any geometry is
  // built, so mode-0 vectors tolerate garbage in the remaining selective
  // slots (the shader likewise forces maskW to 0 when mode is off, which
  // also neutralizes a parked invert=1).
  // Task 4.4 aspect override: uniforms[26] (selAspect) is IGNORED here —
  // the ellipse aspect is always the decoded frame `w/h` (geometry is
  // built after decode below). The preview painter likewise overwrites
  // shader slot 28 with the paint size aspect every frame, so the radial
  // ellipse looks visually identical on preview and export despite
  // different resolutions (see the SelectiveState aspect contract in
  // `editor_state.dart`).
  double selModeRaw = 0.0;
  double selStrength = 0.0;
  if (hasSelective) {
    assert(uniforms[19] >= 0.0 && uniforms[19] <= 3.0);
    assert(uniforms[27] == 0.0 || uniforms[27] == 1.0);
    selModeRaw = uniforms[19];
    selStrength = uniforms[28].clamp(0.0, 1.0);
  }
  final bool useSelective = selModeRaw >= 0.5 && selStrength > 0.0;
  final bool selIsBrush = selModeRaw > 2.5;
  // `invert` is kept OUT of the geometry on purpose: the frag applies
  // `if (uSelInvert > 0.5) maskW = 1 - maskW` AFTER the mode-branch
  // selection (so it covers analytic AND brush AND the fractional cracks
  // at exactly 1.5/2.5, where no branch matches and maskW stays 0), and
  // only then forces maskW to 0 when mode is off. The per-pixel code below
  // repeats that order literally, so every double mode value — not just
  // the int 0..3 [LensParams] emits — matches the shader.
  // (Geometry used to be built here from uniforms[20..26]; since Task 4.4
  // it is built AFTER decode with aspect = w/h — see below.)
  // Guarded by useSelective (which implies a selective-carrying form):
  // legacy 9/10/19-slot vectors have no index 27 at all.
  final bool selInvert = useSelective && hasSelective && uniforms[27] > 0.5;
  if (useSelective &&
      selIsBrush &&
      brush != null &&
      (brush.size <= 0 || brush.mask.length != brush.size * brush.size)) {
    throw LensCpuException(
      'Brush mask must hold size*size floats '
      '(size=${brush.size}, len=${brush.mask.length}).',
    );
  }
  // Blur block (uniforms[32..36] -> slots 34..38), applied since
  // Task 6.3 FIRST (before enhance), mirroring the frag stage order. The
  // mode test mirrors the shader (`> 0.5` on — the frag reads the raw
  // float, not the int [LensParams] emits); radius/strength are clamped
  // like the shader; feather keeps the shader's raw `<= 0.0` hard-step
  // guard with a clamped smoothstep otherwise; invert is `> 0.5`.
  // Legacy 9/10/19/32-slot vectors predate the block and run with the
  // stage skipped (the 37/47-slot legacy forms carry it — see above).
  // A null mask is neutral (NOT the shader's white stub —
  // see the file-level divergence note), so only the fully-armed state
  // (active mode + positive radius/strength + a mask) builds the blur.
  final double blurModeRaw = hasBlur ? uniforms[32] : 0.0;
  final double blurRadius = hasBlur ? uniforms[33].clamp(0.0, 0.05) : 0.0;
  final double blurFeatherRaw = hasBlur ? uniforms[34] : 0.5;
  final double blurStrength = hasBlur ? uniforms[35].clamp(0.0, 1.0) : 0.0;
  final bool blurInvert = hasBlur && uniforms[36] > 0.5;
  final bool useBlur =
      blurModeRaw > 0.5 &&
      blurStrength > 0.0 &&
      blurRadius > 0.0 &&
      blurMask256 != null;
  // Guarded by useBlur (which implies a present mask): inactive stages
  // ignore the mask entirely, like mode-0 selective tolerates garbage.
  // Any square resolution is accepted (production always passes 256);
  // the side is derived — a non-square length cannot sample, so it throws.
  int blurSize = 0;
  if (useBlur) {
    final int len = blurMask256.length;
    final int side = math.sqrt(len).round();
    if (side <= 0 || side * side != len) {
      throw LensCpuException(
        'Blur mask must hold size*size floats (got len=$len).',
      );
    }
    blurSize = side;
  }
  // Rays block (uniforms[37..46] -> slots 39..48), applied since
  // Task 7.3 AFTER selective and BEFORE the intensity mix, mirroring the
  // frag stage order. The gate mirrors the shader (`> 0.5` on, then
  // intensity > 0): off or zero-strength skips before ANY low-res work, so
  // a parked gate tolerates garbage in the remaining rays slots (like
  // mode-0 blur tolerates a malformed mask). Legacy 9/10/19/32/37-slot
  // vectors predate the block and run with the stage skipped (the 47-slot
  // legacy form carries it — see above).
  // `rayX`/`rayY` pass through UNCLAMPED like the shader (an off-frame sun
  // keeps marching correctly); length/warmth/density clamp like the
  // shader; length <= 0 degrades to the tap-free point glow (no low-res
  // buffers at all — see below).
  final double rayOnRaw = hasRays ? uniforms[37] : 0.0;
  final double rayIntensity = hasRays ? uniforms[40].clamp(0.0, 1.0) : 0.0;
  final bool useRays = rayOnRaw > 0.5 && rayIntensity > 0.0;
  final double rayX = useRays ? uniforms[38] : 0.5;
  final double rayY = useRays ? uniforms[39] : 0.2;
  final double rayLength = useRays ? uniforms[41].clamp(0.0, 1.0) : 0.0;
  final double rayWarmth = useRays ? uniforms[42].clamp(0.0, 1.0) : 0.7;
  final double rayDensity = useRays ? uniforms[43].clamp(0.0, 1.0) : 0.5;
  final int rayMode = useRays ? uniforms[44].round().clamp(0, 1) : 0;
  final double rayAngle = useRays ? uniforms[45] : 0.0;
  final double rayWidth = useRays ? uniforms[46].clamp(0.0, 1.0) : 1.0;
  // Tint is position-independent: one mix per export, not per pixel.
  final (double, double, double) rayTint = useRays
      ? raysTint(rayWarmth)
      : (1.0, 0.98, 0.95);
  // Local grade constants (precomputed; the per-pixel math mirrors the
  // frag's selective block: gain + highlight rolloff -> con -> sat).
  final double selGain = math
      .pow(2.0, useSelective ? uniforms[29] : 0.0)
      .toDouble();
  final double selExpAmt =
      (useSelective ? uniforms[29] : 0.0).clamp(0.0, 2.0) / 2.0;
  final double selConK = 1.0 + (useSelective ? uniforms[30] : 0.0);
  final double selSatK = 1.0 + (useSelective ? uniforms[31] : 0.0);
  final bool useEnhance = enhanceStrength > 0.0;

  // LUT table is resolved (and generated) only when it can have an
  // effect: non-none id AND non-zero strength. `none` binds the identity
  // in the shader, so skipping here is exactly equivalent.
  final bool useLut = filterId != 0 && filterStrength > 0;
  final Float32List? lut = useLut ? _lutFor(filterId) : null;

  img.Image? decoded = img.decodeImage(srcBytes);
  if (decoded == null) {
    throw LensCpuException(
      'Unsupported image format (HEIC and some RAW/TIFF variants '
      'cannot be decoded by package:image).',
    );
  }
  // JPEG orientation is already baked by the decoder; other formats may
  // still carry the flag — bake it so export matches the preview.
  if (decoded.exif.imageIfd.hasOrientation &&
      decoded.exif.imageIfd.orientation != 1) {
    decoded = img.bakeOrientation(decoded);
  }

  // Grade runs on the FULL source frame. Every mask/geometry uniform is in
  // that frame (the preview grades the same pixels, then transforms them),
  // so cropping may only happen after the last pixel has been graded.
  final int w = decoded.width;
  final int h = decoded.height;
  if (w <= 0 || h <= 0) {
    throw LensCpuException('Decoded image has zero size.');
  }
  final int n = w * h;

  // Selective geometry (Task 4.4 aspect override): center/radius/feather/
  // angle/width mirror the shader uniforms 1:1 (uv 0..1, top-left origin),
  // but aspect is ALWAYS the frame w/h — uniforms[26] is ignored, so a
  // preview-ratio value stored by the editor can never stretch the export
  // ellipse. The preview painter does the symmetric override (paint size
  // aspect into slot 28), hence visual parity by construction.
  final SelectiveGeometry selGeometry = useSelective
      ? SelectiveGeometry(
          center: (uniforms[20], uniforms[21]),
          radius: uniforms[22],
          feather: uniforms[23],
          angle: uniforms[24],
          width: uniforms[25],
          aspect: w / h,
        )
      : SelectiveGeometry.none;

  // Source RGB in 0..1, interleaved. Normalized ONCE to 8-bit RGB: convert()
  // resolves palette/gray/alpha/16-bit sources, so the extraction loop then
  // reads the raw byte buffer directly — zero per-pixel Pixel dispatches and
  // zero boxed `num` getters (the old getPixel path boxed three ints per
  // pixel twice over a 12MP export).
  final img.Image flat = decoded.convert(
    format: img.Format.uint8,
    numChannels: 3,
  );
  final Uint8List flatBytes =
      flat.data is img.ImageDataUint8
          ? (flat.data as img.ImageDataUint8).data
          : flat.getBytes();

  final Float32List src = Float32List(n * 3);
  for (int p = 0, i = 0, b = 0; p < n; p++, i += 3, b += 3) {
    src[i] = flatBytes[b] / 255.0;
    src[i + 1] = flatBytes[b + 1] / 255.0;
    src[i + 2] = flatBytes[b + 2] / 255.0;
  }

  // Blur FIRST (Task 6.3): separable gaussian (3x-box O(n) approximation
  // since Task 6.3b) of the RAW source RGB (like the shader sampling
  // uImage, not the graded image). Honest RGB — NOT luma-only
  // (portrait blur must not shift hue at edges). A full 3n copy because
  // the raw [src] must survive for the structure maps and the master mix
  // (the frag's `raw` vs `base` split); the box passes run in place on the
  // copy with one 3n scratch. Skipped entirely unless fully armed
  // (mode + radius + strength + mask). Pixel radius = fraction * min(w,h),
  // floored at 1px (the frag taps at any radius > 0) and clamped to
  // [kLensBlurRadiusPxMax].
  //
  // The blur runs straight on the float buffer: `img.gaussianBlur` is a
  // true (2r+1)-tap separable convolution — O(n·r) with three full-frame
  // uint8 copies — which the Task 6.3b guard test exists precisely to
  // catch (tens of seconds at 12MP). The Kovesi box widths below match the
  // gaussian variance of sigma = r*2/3 — the spread the replaced
  // `img.gaussianBlur` had, so exported bokeh keeps its look (NOT
  // bit-identical to it, and tighter in the frag — see the header note).
  Float32List? blurRgb;
  if (useBlur) {
    final int minSide = w < h ? w : h;
    final int r = (blurRadius * minSide).round().clamp(1, kLensBlurRadiusPxMax);
    blurRgb = Float32List(n * 3);
    blurRgb.setAll(0, src);
    _boxBlurRgb(blurRgb, w, h, r);
  }
  // Null-checked aliases for the per-pixel loop: non-null exactly when the
  // stage is armed (final locals, so `!= null` promotes without `!`).
  final Float32List? blurTex = useBlur ? blurRgb : null;
  final Float32List? blurMsk = useBlur ? blurMask256 : null;
  final int blurDim = blurSize;

  // Structure base/detail maps of the RAW source (like the shader, which
  // textures the maps built from the source, never the graded image). The
  // shared module (`structure_filter.dart`) runs the SAME guided filter as
  // the preview on the LOW-RES coefficient grid: two ceil(w/s) x
  // ceil(h/s) float planes (at 12MP with s = 12 that is ~0.3MB each, well
  // under 1MB for the pair) instead of the old full-res 2n luma blur
  // (96MB at 12MP). The source luma is
  // folded into the low-res grid on the fly, so no full-res luma plane is
  // ever allocated. Skipped entirely when the signed amount is 0, which
  // makes the neutral case an exact no-op.
  StructureMaps? structureMaps;
  if (structureAmtEff != 0.0) {
    final StructureGeometry geo = structureGeometryFor(w, h);
    structureMaps = computeStructureMapsFromRgb(
      src,
      w,
      h,
      radius: geo.radius.toDouble(),
    );
  }

  // Rays low-res march (Task 7.3): RAW source luma (like the shader
  // tapping uImage, never the graded image) is box-downsampled to a grid
  // capped at [kLensRaysLowMaxDim] and marched N=24 toward the source IN
  // LOW-RES PIXEL SPACE — proportionally the same march as the frag
  // (marchLen = length * lowDiag, eps-guarded normalize, decay-weighted
  // mean). Only the accum (low-frequency scene light) travels through
  // low-res; the streak is angular (high-frequency) and is recomputed at
  // FULL resolution per pixel below via `raysStreak(atan2, density)` —
  // cheap and exact, never upsampled. Length <= 0 builds NOTHING here:
  // the tap-free point glow is pure per-pixel math (frag else-branch).
  // Skipped entirely unless armed (gate + strength), so a parked stage
  // costs zero low-res work. Two lw*lh float buffers (luma is dropped
  // after the march — only the accum survives into the pixel loop).
  Float32List? raysAccumLow;
  int raysLowW = 0;
  int raysLowH = 0;
  if (useRays && rayLength > 0.0) {
    final int maxSide = w > h ? w : h;
    final double raysScale = maxSide > kLensRaysLowMaxDim
        ? kLensRaysLowMaxDim / maxSide
        : 1.0;
    raysLowW = math.max(1, (w * raysScale).round());
    raysLowH = math.max(1, (h * raysScale).round());
    final Float32List raysLumaLow = _downsampleLumaBox(
      src,
      w,
      h,
      raysLowW,
      raysLowH,
    );
    raysAccumLow = _marchRaysAccumLow(
      raysLumaLow,
      raysLowW,
      raysLowH,
      rayX,
      rayY,
      rayLength,
    );
  }
  // Full-res march geometry (mirrors the frag `srcPx`/`diagPx`): the
  // source in full-res pixel coords (UNCLAMPED — an off-frame sun keeps
  // marching correctly) and the frame diagonal for the glow branch.
  final double raySrcPxX = rayX * w;
  final double raySrcPxY = rayY * h;
  final double raysDiagPx = math.sqrt((w * w + h * h).toDouble());

  // ---------------------------------------------------------------------
  // Loop-invariant constants. Everything below depends only on the grade
  // uniforms, never on the pixel; hoisting keeps the per-pixel math
  // identical (same expressions, same order) while dropping millions of
  // redundant evaluations per export.
  // ---------------------------------------------------------------------
  final double gain = math.pow(2.0, exposure).toDouble();
  final double expAmt = exposure.clamp(0.0, 2.0) / 2.0;
  final bool positiveExposure = exposure >= 0.0;
  // Negative-exposure gamma: one pow instead of ~36M at 12MP.
  final double negExposureGamma = positiveExposure
      ? 0.0
      : math.pow(2.0, -exposure).toDouble();
  // Contrast S-curve (tanh): the outer tanh is a function of the amount
  // alone, as is the 2x scale of the inner argument.
  final double conK = contrast;
  final bool useContrast = conK.abs() >= 1e-4;
  final double conTanh = useContrast ? _tanh(conK) : 0.0;
  // White-balance gains (professional multiplicative, luminance preserved;
  // mirrors the shader's white-balance block 1:1): temp/tint only.
  final double wbTemp = temp.clamp(-1.0, 1.0);
  final double wbTint = tint.clamp(-1.0, 1.0);
  final double rGain = (1.0 + 0.6 * wbTemp) * (1.0 + 0.3 * wbTint);
  final double gGain = 1.0 - 0.4 * wbTint;
  final double bGain = (1.0 - 0.6 * wbTemp) * (1.0 + 0.3 * wbTint);
  // Blur feather is a uniform: the hard-step test and the smoothstep edges
  // hoist out of the loop.
  final bool hardFeather = blurFeatherRaw <= 0.0;
  final double blurFeather = blurFeatherRaw.clamp(0.0, 1.0);
  final double featherEdge0 = 0.5 - blurFeather * 0.5;
  final double featherEdge1 = 0.5 + blurFeather * 0.5;
  // Texel-center uv per column: one table instead of two divisions per
  // pixel; the values are exactly the divisions the loop used to run.
  final Float64List uxTable = Float64List(w);
  for (int cx = 0; cx < w; cx++) {
    uxTable[cx] = (cx + 0.5) / w;
  }
  // Allocation-free scratch for the de-recorded hot-path helpers (LUT /
  // enhance / rays write R,G,B here). One per export: the isolate that
  // runs this loop is single-threaded.
  final Float64List pixelScratch = Float64List(3);

  // Output is written as a flat 8-bit RGB buffer (no per-pixel
  // setPixelRgb dispatch and rowStride math) and wrapped once at the end.
  final Uint8List outBytes = Uint8List(n * 3);
  for (int y = 0; y < h; y++) {
    final int rowStart = y * w;
    final double uy = (y + 0.5) / h;
    final double fragY = y + 0.5;
    for (int x = 0; x < w; x++) {
      final int p = rowStart + x;
      final int i = p * 3;
      final double rr = src[i];
      final double gg = src[i + 1];
      final double bb = src[i + 2];
      final double ux = uxTable[x];

    // Blur composite FIRST (Task 6.3): base = mix(blurred, raw, t) with
    // t = clamp(m + (1 - s)) — the frag formula literally. The mask is
    // bilinear-sampled at the texel-center uv like the GPU linear filter
    // ([sampleBrushMask]); feather <= 0 is the hard-step branch (e0 == e1
    // is undefined in GLSL, same guard as the selective stage), otherwise
    // the smoothstep edge; invert flips subject/background. Inactive
    // (both aliases null) => base IS raw, bit-exact neutral.
    double baseR = rr;
    double baseG = gg;
    double baseB = bb;
    if (blurTex != null && blurMsk != null) {
      final double m = sampleBrushMask(blurMsk, blurDim, ux, uy);
      final double mf;
      if (hardFeather) {
        mf = m >= 0.5 ? 1.0 : 0.0;
      } else {
        mf = lensSmoothstep(featherEdge0, featherEdge1, m);
      }
      final double mm = blurInvert ? 1.0 - mf : mf;
      final double t = (mm + (1.0 - blurStrength)).clamp(0.0, 1.0);
      final double br = blurTex[i];
      final double bg = blurTex[i + 1];
      final double bz = blurTex[i + 2];
      baseR = br + (rr - br) * t;
      baseG = bg + (gg - bg) * t;
      baseB = bz + (bb - bz) * t;
    }

    // Enhance FIRST (Task 3.2): the TG-like 1-tap grade on the composite
    // base (like the shader enhancing `base`, NOT `raw`), mirroring the
    // shader stage. Shared code with the shader
    // spec ([applyEnhancePixel]), so CPU/export agree by construction.
    // strength <= 0 skips bit-exact (early-out inside the helper too).
    double r = baseR;
    double g = baseG;
    double b = baseB;
    if (useEnhance) {
      applyEnhancePixelInto(
        baseR,
        baseG,
        baseB,
        enhance,
        enhanceStrength,
        pixelScratch,
      );
      r = pixelScratch[0];
      g = pixelScratch[1];
      b = pixelScratch[2];
    }

    // Exposure.
    // Positive: linear EV scale with filmic highlight rolloff (no clip).
    // Negative: gamma curve so midtones darken with depth instead of a
    // flat linear scale - gives the "day -> night" feel. The branch and
    // its gamma are loop-invariant (hoisted above).
    if (positiveExposure) {
      r *= gain;
      g *= gain;
      b *= gain;

      // Highlight rolloff (matches frag 1:1).
      final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
      final double k = expAmt * 0.5 * lensSmoothstep(0.7, 1.0, luma);
      r = r + ((r / (r + 0.15)) * 1.15 - r) * k;
      g = g + ((g / (g + 0.15)) * 1.15 - g) * k;
      b = b + ((b / (b + 0.15)) * 1.15 - b) * k;
    } else {
      r = math.pow(math.max(r, 0.0), negExposureGamma).toDouble();
      g = math.pow(math.max(g, 0.0), negExposureGamma).toDouble();
      b = math.pow(math.max(b, 0.0), negExposureGamma).toDouble();
    }

    // Contrast around middle gray. Professional S-curve (tanh) instead of
    // a linear scale: boosts midtone contrast without hard-clipping
    // blacks/whites. Identity at 0. The outer tanh is hoisted; the inner
    // expression keeps the original association so results stay
    // bit-identical.
    if (useContrast) {
      r = 0.5 + 0.5 * _tanh((r - 0.5) * conK * 2.0) / conTanh;
      g = 0.5 + 0.5 * _tanh((g - 0.5) * conK * 2.0) / conTanh;
      b = 0.5 + 0.5 * _tanh((b - 0.5) * conK * 2.0) / conTanh;
    }

    // Saturation via vibrance (mirrors the shader). Boosts under-saturated
    // colors more than already-saturated ones; identity at 0.
    final double satLuma = 0.299 * r + 0.587 * g + 0.114 * b;
    final double satMax = math.max(math.max(r, g), b);
    final double satMin = math.min(math.min(r, g), b);
    final double curSat = (satMax - satMin) / math.max(satMax, 1e-6);
    // Skin-tone protection (mirrors the shader).
    final double skinR = lensSmoothstep(0.35, 0.5, r);
    final double skinG = lensSmoothstep(0.20, 0.35, g);
    final double hb0 = 0.6 * r;
    final double hb1 = 0.8 * r;
    final double skinB = hb1 > hb0 ? 1.0 - lensSmoothstep(hb0, hb1, b) : 1.0;
    final double skinD = lensSmoothstep(0.0, 0.08, r - g);
    final double skinMask = skinR * skinG * skinB * skinD;
    final double vibAmount = saturation * (1.0 - 0.5 * skinMask);
    final double vibFactor = 1.0 + vibAmount * (1.0 - curSat);
    r = satLuma + (r - satLuma) * vibFactor;
    g = satLuma + (g - satLuma) * vibFactor;
    b = satLuma + (b - satLuma) * vibFactor;

    // White balance (professional multiplicative gains, luminance
    // preserved). Mirrors the shader's white-balance block 1:1; the gains
    // are loop-invariant and hoisted above.
    final double wbLumaBefore = 0.299 * r + 0.587 * g + 0.114 * b;
    double nr = r * rGain;
    double ng = g * gGain;
    double nb = b * bGain;
    final double wbLumaAfter = 0.299 * nr + 0.587 * ng + 0.114 * nb;
    if (wbLumaAfter > 1e-6) {
      final double scale = wbLumaBefore / wbLumaAfter;
      nr *= scale;
      ng *= scale;
      nb *= scale;
    }
    r = nr;
    g = ng;
    b = nb;

    // Shadows / highlights, luma-masked (luma re-measured after WB).
    final double luma = 0.299 * r + 0.587 * g + 0.114 * b;
    // Professional shadows/highlights: curve-based (lift toward 1 in
    // shadows, scale in highlights) instead of a flat additive shift.
    final double shMask = 1.0 - lensSmoothstep(0.0, 0.5, luma);
    final double hiMask = lensSmoothstep(0.5, 1.0, luma);
    r += shadows * shMask * (1.0 - r) * 0.6;
    g += shadows * shMask * (1.0 - g) * 0.6;
    b += shadows * shMask * (1.0 - b) * 0.6;
    r += highlights * hiMask * r * 0.6;
    g += highlights * hiMask * g * 0.6;
    b += highlights * hiMask * b * 0.6;

    // Structure (local contrast, not sharpening): the shared guided-filter
    // base/detail stage, mirrored 1:1 in the shader. The base maps were
    // built once from the RAW source above; `q` is the edge-preserving base
    // luma sampled bilinearly (the ONE sampling convention of the module),
    // dEV the local log-contrast, M the parabolic midtone mask and the
    // signed amount pushes exp(E). Multiplying the GRADED RGB by that one
    // factor preserves hue and saturation (the channel ratios are
    // untouched), unlike the old additive detail in all three channels.
    // Exactly neutral at amount 0 (the maps are not even built).
    if (structureMaps != null) {
      final double rawLuma = 0.299 * rr + 0.587 * gg + 0.114 * bb;
      final double q = structureBaseAt(structureMaps, x, y, rawLuma);
      // Enhance's boost fades out on near-white GRADED luma, exactly like
      // the shader: the tone curve just saved those highlights, and a
      // local-contrast tick must not push them back onto a flat white
      // wall. The user's own Structure slider is never faded.
      final double gradedLuma = 0.299 * r + 0.587 * g + 0.114 * b;
      final double boost =
          kEnhanceStructureBoost *
          enhanceStrength *
          (1.0 - lensSmoothstep(0.85, 1.0, gradedLuma));
      final double amount = (structureAmt + boost).clamp(-1.0, 1.0);
      final double mult = structureMultiplier(
        yraw: rawLuma,
        q: q,
        amount: amount,
      );
      r *= mult;
      g *= mult;
      b *= mult;
    }

    // LUT look: trilinear sample of the coarse table, mixed by
    // filterStrength. Runs BEFORE the master mix so intensity stays the
    // final word — same order as the shader (`applyLut` -> `mixAmt`).
    if (lut != null) {
      LutTables.sampleLutInto(lut, r, g, b, pixelScratch);
      r += (pixelScratch[0] - r) * filterStrength;
      g += (pixelScratch[1] - g) * filterStrength;
      b += (pixelScratch[2] - b) * filterStrength;
    }

    // Selective (Task 4.3): LAST grade before the master mix, mirroring
    // the frag's selective block. Mask branch ranges are the shader's
    // (`> 0.5 && < 1.5` radial, `> 1.5 && < 2.5` linear, `> 2.5` brush);
    // uv is the texel center, like the frag's `FlutterFragCoord / res`
    // and the raster layout. Grade inside the mask is exposure (gain +
    // the SAME highlight rolloff as the global stage) -> contrast ->
    // saturation; structure inside the mask is skipped (documented 4.x
    // limit, same as the shader). Mixed by `maskW * selStrength`.
    if (useSelective) {
      double maskW;
      if (selModeRaw > 0.5 && selModeRaw < 1.5) {
        maskW = selectiveWeight(ux, uy, selGeometry, SelectiveMode.radial);
      } else if (selModeRaw > 1.5 && selModeRaw < 2.5) {
        maskW = selectiveWeight(ux, uy, selGeometry, SelectiveMode.linear);
      } else if (selIsBrush) {
        // Null raster = neutral (NOT the shader's white stub — see the
        // file-level divergence note). A present raster is bilinear-
        // sampled at the image uv, like the GPU linear filter.
        maskW = brush == null
            ? 0.0
            : sampleBrushMask(brush.mask, brush.size, ux, uy);
      } else {
        maskW = 0.0;
      }
      if (selInvert) maskW = 1.0 - maskW;
      final double selK = (maskW * selStrength).clamp(0.0, 1.0);
      if (selK > 0.0) {
        double sr = r * selGain;
        double sg = g * selGain;
        double sb = b * selGain;
        final double selLumaPre = 0.299 * sr + 0.587 * sg + 0.114 * sb;
        final double sk =
            selExpAmt * 0.5 * lensSmoothstep(0.7, 1.0, selLumaPre);
        sr += ((sr / (sr + 0.15)) * 1.15 - sr) * sk;
        sg += ((sg / (sg + 0.15)) * 1.15 - sg) * sk;
        sb += ((sb / (sb + 0.15)) * 1.15 - sb) * sk;
        sr = (sr - 0.5) * selConK + 0.5;
        sg = (sg - 0.5) * selConK + 0.5;
        sb = (sb - 0.5) * selConK + 0.5;
        final double selLuma = 0.299 * sr + 0.587 * sg + 0.114 * sb;
        sr = selLuma + (sr - selLuma) * selSatK;
        sg = selLuma + (sg - selLuma) * selSatK;
        sb = selLuma + (sb - selLuma) * selSatK;
        r += (sr - r) * selK;
        g += (sg - g) * selK;
        b += (sb - b) * selK;
      }
    }

    // Rays (Task 7.3): AFTER selective, BEFORE the intensity mix — the
    // frag order literally. Shafts screen-blend over the finished grade
    // via [applyRaysPixel] (screen can only brighten), but the master mix
    // below still fades them with the rest, so showOriginal (mix 0) stays
    // perfectly clean. The marched scene light is the bilinear upsample
    // of the low-res accum (low-frequency — safe to upsample); the streak
    // is angular (high-frequency) and is recomputed here at FULL
    // resolution via `raysStreak(atan2, density)`. The decay is already
    // folded into the accum (like the frag multiplying `accum * streak`),
    // so `decayVal` is 1.0. Length <= 0 (null accum) is the tap-free
    // point glow: `light = decay(dist/diag)` in full-res pixels, exactly
    // the frag else-branch (same `max(diag, 1e-6)` guard).
    if (useRays) {
      final double fragX = x + 0.5;
      final double dxs = fragX - raySrcPxX;
      final double dys = fragY - raySrcPxY;
      // One atan2 instead of two: the streak and the sector read the same
      // polar angle.
      final double angle = math.atan2(dys, dxs);
      final double streakV =
          raysStreak(angle, rayDensity) * raysSector(angle, rayAngle, rayWidth);
      final double rayLight;
      final Float32List? raysAcc = raysAccumLow;
      if (rayMode == 1) {
        rayLight = 1.0;
      } else if (raysAcc != null) {
        rayLight = _sampleLowBilinear(
          raysAcc,
          raysLowW,
          raysLowH,
          fragX / w * raysLowW,
          fragY / h * raysLowH,
        );
      } else {
        final double distPx = math.sqrt(dxs * dxs + dys * dys);
        rayLight = raysDecay(distPx / math.max(raysDiagPx, 1e-6));
      }
      applyRaysPixelInto(
        r,
        g,
        b,
        rayLight,
        streakV,
        1.0,
        rayTint,
        rayIntensity,
        pixelScratch,
      );
      r = pixelScratch[0];
      g = pixelScratch[1];
      b = pixelScratch[2];
    }

    // Master mix raw<->grade.
    r = rr + (r - rr) * intensity;
    g = gg + (g - gg) * intensity;
    b = bb + (b - bb) * intensity;

    outBytes[i] = (_clamp01(r) * 255.0).round().clamp(0, 255).toInt();
    outBytes[i + 1] = (_clamp01(g) * 255.0).round().clamp(0, 255).toInt();
    outBytes[i + 2] = (_clamp01(b) * 255.0).round().clamp(0, 255).toInt();
    }
  }

  final img.Image out = img.Image.fromBytes(
    width: w,
    height: h,
    bytes: outBytes.buffer,
    numChannels: 3,
    order: img.ChannelOrder.rgb,
  );

  // Crop + straighten LAST: a framing transform over the finished grade.
  // This is the same order the preview composes (shader on the source frame,
  // then CropViewport), so masked edits and rays stay attached to the pixels
  // the user painted instead of being reinterpreted in the cropped frame.
  final img.Image rendered = crop == null ? out : applyCropGeometry(out, crop);
  return img.encodeJpg(rendered, quality: kLensExportJpegQuality);
}

/// Box-downsamples RAW source luma to [lw]x[lh] (Task 7.3).
///
/// [src] is interleaved RGB floats in 0..1; luma uses the rec.709 weights
/// like every other luma in this file. Blocks partition the source
/// exactly (`x0 = floor(lx*w/lw)` .. `x1 = floor((lx+1)*w/lw)`), so every
/// source pixel contributes to exactly one low texel — O(n) total with no
/// full-res luma intermediate (luma is folded in on the fly). Pure
/// floats, no `package:image`. Top-level for testability; pure
/// (no Flutter).
Float32List _downsampleLumaBox(Float32List src, int w, int h, int lw, int lh) {
  final Float32List out = Float32List(lw * lh);
  for (int ly = 0; ly < lh; ly++) {
    final int y0 = (ly * h / lh).floor().clamp(0, h);
    int y1 = ((ly + 1) * h / lh).floor().clamp(0, h);
    if (y1 <= y0) y1 = (y0 + 1).clamp(0, h);
    for (int lx = 0; lx < lw; lx++) {
      final int x0 = (lx * w / lw).floor().clamp(0, w);
      int x1 = ((lx + 1) * w / lw).floor().clamp(0, w);
      if (x1 <= x0) x1 = (x0 + 1).clamp(0, w);
      double acc = 0.0;
      int count = 0;
      for (int y = y0; y < y1; y++) {
        final int row = y * w;
        for (int x = x0; x < x1; x++) {
          final int i = (row + x) * 3;
          acc += 0.299 * src[i] + 0.587 * src[i + 1] + 0.114 * src[i + 2];
          count++;
        }
      }
      out[ly * lw + lx] = count > 0 ? acc / count : 0.0;
    }
  }
  return out;
}

/// Bilinear sample of a single-channel [lw]x[lh] grid at low-res pixel
/// coords ([px], [py] — texel centers at half-integers, clamped edges).
/// The rect-grid sibling of [sampleBrushMask] (which assumes a square
/// mask): the rays low grid keeps the frame aspect, so it is `lw`x`lh`.
/// Out-of-range taps clamp to the edge texel, like the GPU linear filter
/// on a clamped texture. Top-level for testability; pure (no Flutter).
double _sampleLowBilinear(
  Float32List low,
  int lw,
  int lh,
  double px,
  double py,
) {
  final double gx = px - 0.5;
  final double gy = py - 0.5;
  final int x0 = gx.floor();
  final int y0 = gy.floor();
  final double fx = gx - x0;
  final double fy = gy - y0;
  final int x0c = x0.clamp(0, lw - 1);
  final int y0c = y0.clamp(0, lh - 1);
  final int x1c = (x0 + 1).clamp(0, lw - 1);
  final int y1c = (y0 + 1).clamp(0, lh - 1);
  final double a = low[y0c * lw + x0c];
  final double b = low[y0c * lw + x1c];
  final double c = low[y1c * lw + x0c];
  final double d = low[y1c * lw + x1c];
  return (a * (1.0 - fx) + b * fx) * (1.0 - fy) +
      (c * (1.0 - fx) + d * fx) * fy;
}

/// Marches scene light toward the rays source on the LOW-RES luma grid
/// (Task 7.3).
///
/// Per low texel: the frag march literally, in low-res pixel space
/// (proportionally identical geometry to the full-res frag: source at
/// `(rayX*lw, rayY*lh)`, `marchLen = length * lowDiag`, eps-guarded
/// normalize `/ max(dist, 1e-6)` so a texel on the source marches in
/// place, `accum += tap * decay(i/24)/24` over [kLensRaysMarchSteps]).
/// Taps bilinear-sample [low] with clamped edges (GPU linear filter).
/// Returns the accum grid in 0..1 (low-frequency scene light — the only
/// term that gets upsampled; streak/decay-folding matches the frag
/// `accum * streak * intensity`, so callers pass `decayVal` 1.0 to
/// [applyRaysPixel]). Top-level for testability; pure (no Flutter).
Float32List _marchRaysAccumLow(
  Float32List low,
  int lw,
  int lh,
  double rayX,
  double rayY,
  double rayLength,
) {
  final Float32List accum = Float32List(lw * lh);
  final double srcLx = rayX * lw;
  final double srcLy = rayY * lh;
  final double diagL = math.sqrt((lw * lw + lh * lh).toDouble());
  if (diagL <= 1e-6) return accum;
  final double marchLen = rayLength * diagL;
  const int steps = kLensRaysMarchSteps;
  for (int ly = 0; ly < lh; ly++) {
    for (int lx = 0; lx < lw; lx++) {
      final double fx = lx + 0.5;
      final double fy = ly + 0.5;
      final double tx = srcLx - fx;
      final double ty = srcLy - fy;
      final double dist = math.sqrt(tx * tx + ty * ty);
      final double inv = 1.0 / math.max(dist, 1e-6);
      final double dx = tx * inv;
      final double dy = ty * inv;
      double a = 0.0;
      for (int i = 0; i < steps; i++) {
        final double t = i / steps;
        final double tapX = fx + dx * (t * marchLen);
        final double tapY = fy + dy * (t * marchLen);
        a += _sampleLowBilinear(low, lw, lh, tapX, tapY) * raysDecay(t) / steps;
      }
      accum[ly * lw + lx] = a.clamp(0.0, 1.0);
    }
  }
  return accum;
}

/// Box widths for the 3-box gaussian approximation (Kovesi, "Fast
/// Almost-Gaussian Filtering"): three sliding-window boxes whose combined
/// variance matches a gaussian of [sigma]. Result sizes are box EDGE
/// lengths (odd); each pass runs with radius `size ~/ 2`.
List<int> _boxesForGauss(double sigma, int n) {
  final double wIdeal = math.sqrt((12.0 * sigma * sigma / n) + 1.0);
  int wl = wIdeal.floor();
  if (wl % 2 == 0) wl--;
  final int wu = wl + 2;
  final double mIdeal =
      (12.0 * sigma * sigma - n * wl * wl - 4.0 * n * wl - 3.0 * n) /
      (-4.0 * wl - 4.0);
  final int m = mIdeal.round();
  return [for (int i = 0; i < n; i++) i < m ? wl : wu];
}

/// Blurs interleaved RGB [rgb] (row-major `w`x`h`, 0..1 floats) in place
/// with three sliding-window box passes whose widths match the gaussian
/// variance of `sigma = radiusPx * 2/3`. That sigma is the one the
/// replaced `img.gaussianBlur(radius: r)` used (verified against
/// package:image 4.12's kernel), so the exported blur spread at a given
/// slider value is unchanged by this refactor. O(n) per pass and
/// radius-independent (~36 cheap ops/px total); one 3n scratch buffer for
/// the horizontal half of each pass.
///
/// Sizes floor at edge 3: integer boxes cannot express sigma below ~0.82,
/// so the smallest radii would otherwise compute three identity passes —
/// an armed stage that visibly did nothing. The floor keeps the minimum
/// radius a real, smooth blur.
void _boxBlurRgb(Float32List rgb, int w, int h, int radiusPx) {
  final double sigma = radiusPx * 2.0 / 3.0;
  final List<int> boxes = _boxesForGauss(sigma, 3);
  final Float32List scratch = Float32List(rgb.length);
  for (final int boxSize in boxes) {
    final int r = (boxSize < 3 ? 3 : boxSize) ~/ 2;
    _boxBlurH(rgb, scratch, w, h, r);
    _boxBlurV(scratch, rgb, w, h, r);
  }
}

/// Horizontal sliding-window box pass: [src] -> [dst], edge taps clamped.
/// Every channel shares one window accumulator (three adds + three subs
/// per pixel, radius-independent).
void _boxBlurH(
  Float32List srcB,
  Float32List dst,
  int w,
  int h,
  int r,
) {
  final double inv = 1.0 / (r + r + 1);
  for (int y = 0; y < h; y++) {
    final int row = y * w * 3;
    final int first = row;
    final int last = row + (w - 1) * 3;
    double sr = 0.0;
    double sg = 0.0;
    double sb = 0.0;
    for (int k = -r; k <= r; k++) {
      final int c = k < 0 ? first : (k >= w ? last : row + k * 3);
      sr += srcB[c];
      sg += srcB[c + 1];
      sb += srcB[c + 2];
    }
    for (int x = 0; x < w; x++) {
      final int o = row + x * 3;
      dst[o] = sr * inv;
      dst[o + 1] = sg * inv;
      dst[o + 2] = sb * inv;
      final int ai = (x + r + 1) >= w ? last : row + (x + r + 1) * 3;
      final int si = (x - r) < 0 ? first : row + (x - r) * 3;
      sr += srcB[ai] - srcB[si];
      sg += srcB[ai + 1] - srcB[si + 1];
      sb += srcB[ai + 2] - srcB[si + 2];
    }
  }
}

/// Vertical sliding-window box pass: [src] -> [dst], edge taps clamped.
void _boxBlurV(
  Float32List srcB,
  Float32List dst,
  int w,
  int h,
  int r,
) {
  final double inv = 1.0 / (r + r + 1);
  final int rowBytes = w * 3;
  for (int x = 0; x < w; x++) {
    final int col = x * 3;
    final int first = col;
    final int last = (h - 1) * rowBytes + col;
    double sr = 0.0;
    double sg = 0.0;
    double sb = 0.0;
    for (int k = -r; k <= r; k++) {
      final int c = k < 0 ? first : (k >= h ? last : k * rowBytes + col);
      sr += srcB[c];
      sg += srcB[c + 1];
      sb += srcB[c + 2];
    }
    for (int y = 0; y < h; y++) {
      final int o = y * rowBytes + col;
      dst[o] = sr * inv;
      dst[o + 1] = sg * inv;
      dst[o + 2] = sb * inv;
      final int ai = (y + r + 1) >= h ? last : (y + r + 1) * rowBytes + col;
      final int si = (y - r) < 0 ? first : (y - r) * rowBytes + col;
      sr += srcB[ai] - srcB[si];
      sg += srcB[ai + 1] - srcB[si + 1];
      sb += srcB[ai + 2] - srcB[si + 2];
    }
  }
}
