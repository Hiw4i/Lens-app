import 'dart:math' as math;
import 'dart:typed_data';

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_skin.dart';
import 'package:lens/features/filters/lut_definition.dart';

export 'package:lens/features/adjust/cards/enhance/enhance_skin.dart'
    show enhanceSkinMask;

/// Professional 1-tap Enhance: apply stage.
///
/// Pure-Dart on purpose: this file imports `dart:*` and
/// `package:lens` pure libraries only (no Flutter, no Riverpod), so
/// [applyEnhancePixel] and [applyEnhanceToBuffers] are safe to run inside
/// an isolate. This file only defines the per-pixel math consumed by the
/// CPU/export path; the preview shader mirrors it 1:1 in
/// `shaders/lens_filter.frag`.
///
/// Per-pixel order (all in display-referred 0..1 RGB):
/// 1. WB: `r' = mix(r, r * gainR, s)`, `b' = mix(b, b * gainB, s)`,
///    `g` unchanged (green is the anchor, `s` = clamped strength).
/// 2. Exposure: `c' = mix(c, c * exposureGain, s)`.
/// 3. Dehaze push away from the veil color, mixed by `s * protect`:
///    `c' = mix(c, c + (c - haze) * dehaze, s * protect)`.
///    It runs BEFORE the tone curve on purpose: removing the veil can
///    push a channel past 1, and the tone curve's shoulder is the stage
///    that maps that back into the display range (the other way round
///    would undo the highlight recovery).
/// 4. Tone curve (levels stretch -> highlight shoulder -> S-curve),
///    mixed by `s * protect`:
///    * stretch: `u = (c - blackPt) / (whitePt - blackPt)`;
///    * shoulder: for `u > knee` (`knee = 1 - 0.12 * highlightRecover`),
///      `u' = knee + (1 - knee) * t / (t + (1 - knee))` with `t = u - knee`
///      — a rational (Reinhard-style) roll-off that is C1 at the knee and
///      asymptotes to 1. It approaches 1 far more slowly than an
///      exponential, so an over-range (blown) highlight ends up clearly
///      BELOW pure white instead of being squeezed back onto it, and the
///      near-white pixels below it stay distinguishable;
///    * S-curve: `u'' = mix(u', u'^2 (3 - 2 u'), contrast)` (0 = neutral).
/// 5. Shadow lift: `c' = c + shadowLift * shadowMask * 0.10 * s`.
/// 6. Vibrance + saturation (skin-protected).
/// 7. Split toning (the "tone" of the photo): cool shadows / warm
///    highlights, mixed by `s`. Both tints fade with the headroom they
///    have, so the look can never push a channel out of range.
/// 8. Look: a whisper of the procedural Cinematic filter
///    ([EnhanceAnalysis.look], 30/100 at full strength), mixed by `s`.
/// Output is clamped to 0..1. `strength <= 0` returns the input untouched
/// (bit-exact); `EnhanceAnalysis.none` at any strength is the identity on
/// 0..1 inputs (every stage is a no-op at its neutral value).
///
/// Skin protection: the tone curve and the dehaze are scaled down 60% on
/// skin so faces don't go contrasty/orange while the background still pops:
/// `protect = 1 - 0.6 * skinMask`, with the smooth mask
/// `skinMask = smoothstep(0.35, 0.5, r) * smoothstep(0.2, 0.35, g) *`
/// `(1 - smoothstep(0.6R, 0.8R, b)) * smoothstep(0.0, 0.08, r - g)`
/// measured on the post-WB pixel (detection sees neutral-anchored color):
/// bright-enough red, present green, blue clearly below red (no sky/gray),
/// and red dominant over green. WB itself is NOT skin-gated — a global
/// cast must shift skin too, or the face detaches from the scene. The
/// vibrance/saturation stage protects skin separately (a flatter, milder
/// factor) so faces never turn orange.
double _smoothstep(double e0, double e1, double x) =>
    enhanceSmoothstep(e0, e1, x);

double _clamp01(double v) => v.clamp(0.0, 1.0);

/// Rec.709 luma, same weights as the shader.
double _luma(double r, double g, double b) => 0.299 * r + 0.587 * g + 0.114 * b;

/// Fraction of the highlight range the shoulder occupies when
/// [EnhanceAnalysis.highlightRecover] is 1.0 (the knee sits that far below
/// 1.0, so the roll-off starts early and the blown area never ends on a
/// hard white wall).
const double kEnhanceShoulderSpan = 0.12;

/// Extra structure the Enhance stage adds on top of the user's Structure
/// slider, at 100% strength.
///
/// `0.12` is +12 slider units: the clarity a professional auto-grade uses
/// to make a photo read as "taken with a good lens" instead of
/// "corrected". Subtle by design — it is added to [LensParams.structure],
/// never replaces it, and runs through the SAME guided-filter stage (so it
/// is local contrast, not a sharpen, and it cannot halo).
const double kEnhanceStructureBoost = 0.12;

/// The tone curve of one channel: auto-levels stretch, highlight shoulder
/// and the Hermite S-curve. Pure (no Flutter).
///
/// [invSpan] is `1 / (whitePt - blackPt)` (the caller hoists it out of the
/// per-pixel loop).
double enhanceToneChannel(
  double x,
  EnhanceAnalysis a,
  double invSpan,
) {
  double u = (x - a.blackPt) * invSpan;
  // The S-curve shapes the IN-RANGE part only; the excess above 1 rides
  // along untouched so the shoulder can still compress it. Folding it back
  // afterwards keeps a blown highlight off pure white instead of the curve
  // pulling it there.
  final double excess = u > 1.0 ? u - 1.0 : 0.0;
  double shaped = u.clamp(0.0, 1.0);
  // Hermite S-curve: more midtone separation, gentler ends.
  final double contrast = a.contrast.clamp(0.0, 1.0);
  if (contrast > 0.0) {
    final double hermite = shaped * shaped * (3.0 - 2.0 * shaped);
    shaped += (hermite - shaped) * contrast;
  }
  u = shaped + excess;
  // Highlight shoulder: a rational (Reinhard-style) roll-off that is C1 at
  // the knee and asymptotes to 1. It approaches 1 far more slowly than an
  // exponential, so an over-range (blown) highlight ends up clearly BELOW
  // pure white instead of being squeezed back onto it.
  final double knee = 1.0 - kEnhanceShoulderSpan * a.highlightRecover.clamp(
    0.0,
    1.0,
  );
  final double width = 1.0 - knee;
  if (width > 1e-6 && u > knee) {
    final double t = u - knee;
    u = knee + width * t / (t + width);
  }
  return u.clamp(0.0, 1.0);
}

/// Applies the Enhance grade to a single 0..1 RGB pixel.
///
/// [strength] is clamped to 0..1; 0 returns `(r, g, b)` untouched.
/// Pure (no Flutter), safe for tight per-pixel loops.
(double, double, double) applyEnhancePixel(
  double r,
  double g,
  double b,
  EnhanceAnalysis a,
  double strength,
) {
  final Float64List out = Float64List(3);
  applyEnhancePixelInto(r, g, b, a, strength, out);
  return (out[0], out[1], out[2]);
}

/// Allocation-free variant of [applyEnhancePixel] for the export hot loop:
/// writes R,G,B into [out] (length >= 3). Same arithmetic in the same
/// order — the per-pixel record (plus the look's [LutTables.gradePixel]
/// record) was the dominant allocation of an enhanced export.
void applyEnhancePixelInto(
  double r,
  double g,
  double b,
  EnhanceAnalysis a,
  double strength,
  Float64List out,
) {
  final double s = strength.clamp(0.0, 1.0);
  if (s <= 0.0) {
    out[0] = r;
    out[1] = g;
    out[2] = b;
    return;
  }

  // 1. WB, G-anchored, mixed by s.
  double rr = r * (1.0 + (a.wbGainR - 1.0) * s);
  double gg = g;
  double bb = b * (1.0 + (a.wbGainB - 1.0) * s);

  // 2. Skin gate (post-WB), shared by the tone curve + dehaze.
  final double skin = enhanceSkinMask(rr, gg, bb);
  final double protect = 1.0 - 0.6 * skin;

  // 3. Auto-exposure gain, mixed by s.
  final double exposureGain = 1.0 + (a.exposureGain - 1.0) * s;
  rr *= exposureGain;
  gg *= exposureGain;
  bb *= exposureGain;

  // 4. Dehaze: push away from the veil color. It runs BEFORE the tone
  // curve on purpose: the veil removal can push a channel past 1, and the
  // tone curve's shoulder is the stage that maps that back into the
  // display range (doing it the other way round would undo the
  // highlight recovery).
  final double kHz = s * protect;
  if (kHz > 0.0 && a.dehaze > 0.0) {
    final double d = a.dehaze * kHz;
    rr = rr + (rr - a.hazeColor.$1) * d;
    gg = gg + (gg - a.hazeColor.$2) * d;
    bb = bb + (bb - a.hazeColor.$3) * d;
    // The veil removal can push a channel below zero (the veil used to
    // lift the shadows; taking it away crushes them). Clamping to a valid
    // display value keeps the stages below well-conditioned (without it
    // the saturation estimate would divide by ~0 and blow the vibrance up).
    rr = rr.clamp(0.0, 1.5);
    gg = gg.clamp(0.0, 1.5);
    bb = bb.clamp(0.0, 1.5);
  }

  // 5. Tone curve (stretch -> shoulder -> S-curve), skin-gated.
  final double kTone = s * protect;
  if (kTone > 0.0) {
    final double span = a.whitePt - a.blackPt;
    final double invSpan = span <= 1e-6 ? 1.0 : 1.0 / span;
    rr = rr + (enhanceToneChannel(rr, a, invSpan) - rr) * kTone;
    gg = gg + (enhanceToneChannel(gg, a, invSpan) - gg) * kTone;
    bb = bb + (enhanceToneChannel(bb, a, invSpan) - bb) * kTone;
  }

  // 6. Shadow lift: a small additive lift of the deep shadows (the
  //    filmic "lifted blacks"), mixed by s.
  final double shadowLift = a.shadowLift;
  if (shadowLift > 0.0) {
    final double luma = _luma(rr, gg, bb);
    final double mask = 1.0 - _smoothstep(0.0, 0.45, luma);
    final double lift = shadowLift * mask * 0.10 * s;
    rr += lift;
    gg += lift;
    bb += lift;
  }

  // 7. Vibrance (under-saturated colours first) + a flat saturation lift.
  if (a.vibrance != 0.0 || a.saturation != 0.0) {
    final double luma = _luma(rr, gg, bb);
    final double mx = math.max(rr, math.max(gg, bb));
    final double mn = math.min(rr, math.min(gg, bb));
    final double sat = (mx - mn) / math.max(mx, 1e-3);
    final double vibFactor =
        1.0 + a.vibrance * (1.0 - sat) * (1.0 - 0.7 * skin);
    final double vr = luma + (rr - luma) * vibFactor;
    final double vg = luma + (gg - luma) * vibFactor;
    final double vb = luma + (bb - luma) * vibFactor;
    final double satFactor = 1.0 + a.saturation * (1.0 - 0.5 * skin);
    final double sr = luma + (vr - luma) * satFactor;
    final double sg = luma + (vg - luma) * satFactor;
    final double sb = luma + (vb - luma) * satFactor;
    rr += (sr - rr) * s;
    gg += (sg - gg) * s;
    bb += (sb - bb) * s;
  }

  // 8. Split toning: cool shadows / warm highlights, mixed by s.
  //    Both tints are faded by the headroom they have: the shadow tint
  //    dies in the deep blacks and the highlight tint dies as a pixel
  //    approaches white, so the look can never push a channel out of
  //    range (which would undo the highlight recovery).
  if (a.toneShadow != 0.0 || a.toneHighlight != 0.0) {
    final double luma = _luma(rr, gg, bb);
    final double shadowMask = 1.0 - _smoothstep(0.05, 0.5, luma);
    final double highlightMask = _smoothstep(0.5, 0.95, luma);
    final double ts =
        a.toneShadow *
        shadowMask *
        (1.0 - 0.6 * skin) *
        math.min(luma * 3.0, 1.0) *
        s;
    final double headroom = 1.0 - math.max(rr, math.max(gg, bb));
    final double th =
        a.toneHighlight *
        highlightMask *
        math.min(1.0, headroom * 4.0) *
        s;
    rr += ts * -0.030 + th * 0.040;
    gg += th * 0.012;
    bb += ts * 0.050 + th * -0.028;
  }

  // 9. The built-in look: a whisper of the procedural Cinematic filter
  //    (30/100 at full strength — see [kEnhanceLookStrength]). It finishes
  //    the grade instead of competing with it, and it lives in the ANALYSIS
  //    (`a.look`), so `EnhanceAnalysis.none` stays an exact identity at any
  //    strength. The single source of the look is the filter module's own
  //    `gradePixel`, so the export and the strip's Cinematic thumb agree.
  //
  //    Highlight guard: the look warms the highlights, which must never
  //    undo the highlight recovery above. Its mix therefore fades out as
  //    the pixel approaches white (the same rule the split tone follows):
  //    full look below ~0.87, nothing at pure white.
  if (a.look > 0.0) {
    final double lookHeadroom = 1.0 - math.max(rr, math.max(gg, bb));
    final double k = (a.look * s * math.min(1.0, lookHeadroom * 8.0)).clamp(
      0.0,
      1.0,
    );
    if (k > 0.0) {
      final (double lr, double lg, double lb) = LutTables.gradePixel(
        LensFilterId.cinematic,
        rr,
        gg,
        bb,
      );
      rr += (lr - rr) * k;
      gg += (lg - gg) * k;
      bb += (lb - bb) * k;
    }
  }

  out[0] = _clamp01(rr);
  out[1] = _clamp01(gg);
  out[2] = _clamp01(bb);
}

/// Applies the Enhance grade in place to interleaved 0..1 [rgb] floats.
///
/// [rgb] must hold exactly `width * height * 3` floats (throws
/// [ArgumentError] otherwise). `strength <= 0` leaves the buffer
/// untouched (bit-exact early-out). Pure (no Flutter).
void applyEnhanceToBuffers(
  Float32List rgb,
  int width,
  int height,
  EnhanceAnalysis analysis,
  double strength,
) {
  if (width <= 0 || height <= 0) {
    throw ArgumentError('width/height must be positive, got $width x $height.');
  }
  if (rgb.length != width * height * 3) {
    throw ArgumentError(
      'Expected ${width * height * 3} floats '
      '(w*h*3), got ${rgb.length}.',
    );
  }
  final double s = strength.clamp(0.0, 1.0);
  if (s <= 0.0) return;
  for (int i = 0; i < rgb.length; i += 3) {
    final (double r, double g, double b) = applyEnhancePixel(
      rgb[i],
      rgb[i + 1],
      rgb[i + 2],
      analysis,
      s,
    );
    rgb[i] = r;
    rgb[i + 1] = g;
    rgb[i + 2] = b;
  }
}
