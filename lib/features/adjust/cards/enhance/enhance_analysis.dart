import 'dart:math' as math;

import 'package:image/image.dart' as img;
import 'package:lens/features/adjust/cards/enhance/enhance_skin.dart';

/// Professional 1-tap Enhance: analysis stage.
///
/// Pure-Dart on purpose: this file imports `dart:*` and `package:image`
/// only (no Flutter, no Riverpod), so [EnhanceAnalysis] and
/// [analyzeEnhance] are safe to run inside an isolate. The caller prepares
/// a ~256px downscale off the UI thread; the apply stage in
/// `enhance_apply.dart` consumes the result (this file knows nothing about
/// shaders, state, or UI).
///
/// The analysis mirrors what a professional "auto" does (Lightroom's Auto
/// Tone adjusts exposure, contrast, highlights, shadows, whites, blacks,
/// saturation and vibrance from the image content): every parameter below
/// is DERIVED from the photo, never from a fixed preset.
///
/// Estimators, all closed-form over one subsampled pass (plus a cheap
/// second pass for the white-patch mean):
///
/// 1. White balance (green-anchored) — CAST or SCENE?
///    A global cast shifts EVERYTHING, including the near-neutral pixels: a
///    sheet of paper under a tungsten lamp is warm, and that warmth must
///    go. A subject's colour does NOT shift the neutrals: a sunset's warm
///    sky sits next to cool shadows and a cool sky, so the near-neutral
///    population disagrees with the frame's overall warmth — and that
///    warmth is the picture, not the light.
///    So the reference is the NEAR-NEUTRAL population (mid-tone, low
///    saturation, and NOT skin — a warm face is the subject, not a warm
///    lamp). When it agrees with the frame's warmth, the cast is real and
///    the gains neutralize it (70% from the neutrals, 30% from the global
///    estimators as a stabiliser). When it disagrees — or when there is no
///    neutral reference and the frame mixes warm and cool colour — the
///    balance is left exactly as it was shot.
///    The global estimators (the fallback) are gray-world
///    (`grayR = avgG / avgR`), white-patch (`whiteR = topG / topR` over the
///    brightest 5% by luma) and shades-of-gray (Minkowski p=6 over the
///    chromaticity `r/(r+g+b)`), blended `0.25 / 0.30 / 0.45`, each term
///    clamped to 0.75..1.33.
///    Two guards force gains to exactly 1.0 (the cast is treated as intent):
///    * mono guard: `max(avg) - min(avg) < 0.08` (sunsets-in-gray,
///      duotones);
///    * hue guard: mean saturation above [kHueGuardSat] with a mean hue in
///      the warm sector (`<= kHueGuardWarmDeg` or `>= 360 - kHueGuardWarmDeg`)
///      — saturated sunsets, neon red, bonfires. A moderately warm living
///      room (sat ~0.5) still gets corrected; only strongly saturated
///      warm dominance is preserved. Cool saturated casts (blue neon) are
///      NOT guarded — only the warm sector is artistic by default.
///    The green anchor makes the balance nearly luminance-neutral by
///    construction; the residual luma shift is measured and folded into
///    the exposure gain, so the correction never changes the picture's
///    brightness on its own.
///    The estimated gains are then split into their two axes: temperature
///    (R vs B, warm/cool) is kept as estimated, while the GREEN/MAGENTA
///    tint (R+B vs G) is damped to [kTintDamping] and capped at
///    [kTintMaxLog]. The tint axis is where a neutral-pixel estimator is
///    least trustworthy — a pink sunset reads as "magenta", a greenish
///    face reads as "the light" — so a full tint correction either makes
///    the picture ordinary or pushes skin pink.
/// 2. Exposure (auto-exposure): the key is the MEDIAN luma (robust to both
///    specular highlights and large black borders, unlike the mean). The
///    gain is solved so that the frame's midtone lands on
///    [kExposureTargetMid] AFTER the tone window has stretched the frame to
///    0..1 — the two stages have to agree, or the gain would be undone by
///    the stretch. A frame that is already bright is never darkened, only
///    lifted. The gain is capped so the 99.5th percentile does not run far
///    past 1.0 (the highlight shoulder in the apply stage absorbs the
///    rest), and finally clamped to [kExposureGainMin]..[kExposureGainMax].
///    A frame with hard-clipped pixels is pulled down further — that is
///    the overexposure fix: the blown area comes back off pure white
///    instead of ending on a flat white wall.
/// 3. Levels (the tone window, from a 64-bin luma histogram):
///    `blackPt` = luma of the 0.5th percentile (lower bin edge, `lo/64`),
///    `whitePt` = luma of the 99.5th percentile (upper bin edge,
///    `(hi+1)/64`), with `luma = 0.299R + 0.587G + 0.114B`.
///    A HIGH-KEY frame (a document, a snow scene — the median above
///    [kExposureKeyHigh]) keeps its blacks: crushing them would grey the
///    picture down, so only the white point anchors it and the paper stays
///    paper. A low-key frame gets the classic auto-levels window (the
///    blacks crushed, the whites at 1), widened symmetrically to
///    [kMinToneWindow] when the frame is too flat — the extra contrast
///    would be amplified noise.
/// 4. Contrast (RMS): the luma standard deviation is compared against
///    [kTargetSigma]. Flat frames get a Hermite S-curve boost; harsh frames
///    get none (their contrast is tamed by the shadow lift + the highlight
///    shoulder instead, which is how a colourist fixes a blown frame).
/// 5. Shadow lift: a small additive lift in the deep shadows (the "lifted
///    blacks" of a film print). Base [kShadowLiftBase], raised for harsh
///    frames so the blacks come back up instead of crushing to zero.
/// 6. Highlight recovery: driven by the share of near-white and clipped
///    pixels. It sets the shoulder knee used by the apply stage, so blown
///    highlights roll off smoothly instead of ending on a hard white wall.
/// 7. Saturation / vibrance: the mean saturation is compared against
///    [kTargetSaturation]; a low-saturation frame gets vibrance (which
///    boosts the muted colours far more than the already-vivid ones) plus a
///    small flat saturation lift, a vivid frame gets only the base
///    vibrance. Skin tones are protected in the apply stage.
/// 8. Tone (split toning): the frame's warmth (from the raw channel means)
///    drives a cool-shadow / warm-highlight split, the classic cinematic
///    separation — but the split never fights the scene: a warm picture (a
///    sunset, a golden hour) keeps warm shadows instead of being cooled in
///    them.
/// 9. Dehaze (veil estimate): the veil colour is the mean of the
///    low-saturation mid-tone pixels (`(max(R,G,B) - min(R,G,B)) < 0.12`
///    AND luma in [0.3, 0.8]) — the classic atmospheric-light estimate.
///    The veil AMOUNT is not the share of those pixels alone: a veil is
///    what LIFTS the blacks, so the darkest region of the frame must sit
///    close to the veil colour. A properly exposed low-saturation photo
///    has near-black shadows and a bright mid-tone, and must not be
///    pushed around — hence the proximity test that scales the amount
///    down to zero when the veil and the shadows do not match.
/// 10. Look: a whisper of the procedural Cinematic filter
///    ([kEnhanceLookStrength] = 30/100 at full strength), mixed in at the
///    END of the chain. It is part of the analysis ([EnhanceAnalysis.look])
///    so the neutral analysis stays an exact identity.
///
/// Sampling: the caller passes a ~256px downscale, but [analyzeEnhance]
/// never trusts that — inputs larger than 256px on the long side are
/// subsampled in place with `step = ceil(longSide / 256)` (no resize, no
/// scratch buffers; a 64-int histogram is the only allocation). A reusable
/// [img.Pixel] keeps the loop allocation-free.
class EnhanceAnalysis {
  const EnhanceAnalysis({
    this.wbGainR = 1.0,
    this.wbGainB = 1.0,
    this.blackPt = 0.0,
    this.whitePt = 1.0,
    this.dehaze = 0.0,
    this.hazeColor = (0.5, 0.5, 0.5),
    this.exposureGain = 1.0,
    this.contrast = 0.0,
    this.shadowLift = 0.0,
    this.vibrance = 0.0,
    this.saturation = 0.0,
    this.toneShadow = 0.0,
    this.toneHighlight = 0.0,
    this.highlightRecover = 0.0,
    this.look = 0.0,
  });

  /// Multiplicative white-balance gain for R (green-anchored, 0.7..1.3).
  final double wbGainR;

  /// Multiplicative white-balance gain for B (green-anchored, 0.7..1.3).
  final double wbGainB;

  /// Luma black point of the auto-levels window (0..1).
  ///
  /// The stretch's lower anchor. It is 0 for a HIGH-KEY frame (a document,
  /// a snow scene): crushing its blacks would grey the picture down, so
  /// only the white point anchors it.
  final double blackPt;

  /// Luma white point of the auto-levels window (0..1).
  ///
  /// The stretch's upper anchor: the value that maps to 1.0 before the
  /// highlight shoulder takes over.
  final double whitePt;

  /// Veil strength (0..1; the analyzer itself never exceeds 0.6).
  final double dehaze;

  /// Mean color of the hazy pixels (0..1 per channel).
  final (double, double, double) hazeColor;

  /// Auto-exposure gain (linear multiplier, 1.0 = neutral).
  ///
  /// Derived from the frame's median luma with a dead zone, so a
  /// well-exposed photo is left alone while a dark one is lifted and a
  /// blown one is pulled back. Clamped to ±1.2 EV by the analyzer.
  final double exposureGain;

  /// Hermite S-curve contrast amount (0..1, 0 = neutral).
  ///
  /// Non-zero only for frames whose luma spread is narrower than
  /// [kTargetSigma]; harsh frames get 0 and are fixed with the shadow lift
  /// and the highlight shoulder instead.
  final double contrast;

  /// Shadow lift amount (0..1, 0 = neutral).
  ///
  /// Additive lift of the deep shadows (the "faded blacks" film look);
  /// also the main tool against an over-contrasty frame.
  final double shadowLift;

  /// Vibrance amount (-1..1, 0 = neutral).
  ///
  /// Boosts under-saturated colours far more than already-vivid ones, so
  /// a flat frame gets colour without posterising.
  final double vibrance;

  /// Flat saturation amount (-1..1, 0 = neutral).
  ///
  /// A small extra lift for frames that are desaturated across the board
  /// (haze, fog, an over-corrected scan).
  final double saturation;

  /// Split-tone shift for the shadows (-1..1, 0 = neutral).
  ///
  /// Negative = cooler shadows, positive = warmer shadows.
  final double toneShadow;

  /// Split-tone shift for the highlights (-1..1, 0 = neutral).
  ///
  /// Positive = warmer highlights, negative = cooler highlights.
  final double toneHighlight;

  /// Highlight shoulder amount (0..1, 0 = neutral).
  ///
  /// Drives the shoulder knee of the tone curve: the higher the value, the
  /// earlier and firmer the highlights roll off (never a hard clip).
  final double highlightRecover;

  /// Strength of the built-in cinematic look (0..1, 0 = none).
  ///
  /// A whisper of the Cinematic filter, applied at the END of the enhance
  /// chain ([kEnhanceLookStrength] at 100%): the professional "finish" that
  /// separates an auto-graded photo from a merely corrected one. It lives
  /// in the analysis (not as a constant in the apply stage) so
  /// [EnhanceAnalysis.none] stays an exact identity at any strength.
  final double look;

  /// Neutral analysis: identity for every stage of the apply pipeline.
  static const EnhanceAnalysis none = EnhanceAnalysis();

  @override
  bool operator ==(Object other) =>
      other is EnhanceAnalysis &&
      wbGainR == other.wbGainR &&
      wbGainB == other.wbGainB &&
      blackPt == other.blackPt &&
      whitePt == other.whitePt &&
      dehaze == other.dehaze &&
      hazeColor == other.hazeColor &&
      exposureGain == other.exposureGain &&
      contrast == other.contrast &&
      shadowLift == other.shadowLift &&
      vibrance == other.vibrance &&
      saturation == other.saturation &&
      toneShadow == other.toneShadow &&
      toneHighlight == other.toneHighlight &&
      highlightRecover == other.highlightRecover &&
      look == other.look;

  @override
  int get hashCode => Object.hash(
    wbGainR,
    wbGainB,
    blackPt,
    whitePt,
    dehaze,
    hazeColor,
    exposureGain,
    contrast,
    shadowLift,
    vibrance,
    saturation,
    toneShadow,
    toneHighlight,
    highlightRecover,
    look,
  );

  @override
  String toString() =>
      'EnhanceAnalysis(wbGainR: $wbGainR, wbGainB: $wbGainB, '
      'blackPt: $blackPt, whitePt: $whitePt, dehaze: $dehaze, '
      'hazeColor: $hazeColor, exposureGain: $exposureGain, '
      'contrast: $contrast, shadowLift: $shadowLift, '
      'vibrance: $vibrance, saturation: $saturation, '
      'toneShadow: $toneShadow, toneHighlight: $toneHighlight, '
      'highlightRecover: $highlightRecover, look: $look)';
}

/// Per-estimate gain clamp (matches the [EnhanceAnalysis] field contract
/// with headroom: analysis stays strictly inside 0.7..1.3).
double _clampGain(double v) => v.clamp(0.75, 1.33);

/// Strength of the built-in Cinematic look at 100% Enhance.
///
/// `0.30` = the Cinematic filter's own slider at 30/100: a whisper of the
/// teal-orange look, enough to give the auto-grade a point of view and
/// never enough to read as "a filter was applied". Applied at the END of
/// the enhance chain (after the split tone), so it finishes the grade
/// instead of competing with it.
const double kEnhanceLookStrength = 0.30;

/// Mean-saturation floor for the hue guard (0..1). Warm scenes below this
/// (tungsten living rooms ~0.5) are still corrected; only strongly
/// saturated warm dominance (sunsets ~0.9) is preserved as intent.
const double kHueGuardSat = 0.65;

/// Warm hue half-sector in degrees: mean hue <= this or >= 360 - this
/// counts as warm (red-orange). Cool saturated casts stay correctable.
const double kHueGuardWarmDeg = 40.0;

/// Saturation below which a mid-tone pixel counts as NEUTRAL — i.e. it can
/// carry the illuminant (a sheet of paper, a wall, a road). Skin is
/// excluded separately: a warm face is the subject, not a warm lamp.
///
/// Deliberately strict (0.35, not 0.5): a pink sky or a vivid pastel wall
/// must NOT enter the reference population, or its colour becomes "the
/// light" and gets neutralised.
const double kNeutralSat = 0.35;

/// Luma band of the neutral reference population (dark shadows and
/// clipped highlights carry no colour information).
const double kNeutralMinLuma = 0.12;
const double kNeutralMaxLuma = 0.92;

/// Skin probability above which a pixel is excluded from the neutral
/// reference population.
const double kNeutralSkinLimit = 0.55;

/// Share of the frame the neutral reference population must cover before
/// it is trusted as the illuminant.
const double kNeutralMinFrac = 0.04;

/// Warmth ((r - b) / (r + b)) above which a cast is worth correcting.
const double kCastWarmthMin = 0.05;

/// Channel delta above which a chromatic pixel counts as warm (or cool).
const double kChromaticWarmDelta = 0.05;

/// How much of the estimated GREEN/MAGENTA correction survives.
///
/// The G-anchored gains split into two independent axes:
/// * temperature — R vs B, the cast a camera's own white balance is
///   trusted on (tungsten, shade, overcast);
/// * tint — R+B vs G, the axis where a neutral-pixel estimator is least
///   trustworthy. A pink sunset reads as "magenta", a green-lit subject
///   reads as "green", and a greenish face reads as "the light", so a
///   full correction turns the picture ordinary or pushes the skin
///   magenta.
///
/// The tint axis therefore gets a strong damping: temperature is corrected
/// as before, tint only partially. Mixed warm/cool frames keep their
/// balance untouched (see `analyzeEnhance`); this damping covers the
/// remaining cases (a frame dominated by one tinted subject, a pink sky
/// with no neutral reference).
const double kTintDamping = 0.40;

/// Hard cap of the damped tint correction, in natural-log units.
///
/// `0.09` is ~9% on R and B in the same direction — visible as a cast fix
/// on a document or a wall, never enough to recolour a scene.
const double kTintMaxLog = 0.09;

/// Share of the frame a warm (or cool) CHROMATIC population must cover
/// before the frame counts as "mixed" — a picture with colours of its own
/// rather than a global cast.
const double kMixedChromaticMin = 0.03;

/// Median luma below which a frame counts as "too dark" and gets lifted.
const double kExposureKeyLow = 0.32;

/// Median luma above which a frame counts as HIGH-KEY (a document, a snow
/// scene, a studio shot): its blacks are already right and crushing them
/// would grey the picture down, so only the white point anchors it.
const double kExposureKeyHigh = 0.62;

/// Target midtone of the graded frame (display-referred 0..1).
const double kExposureTargetMid = 0.45;

/// Minimum width of the tone window. A frame flatter than this is not
/// stretched further: the extra contrast would be amplified noise.
const double kMinToneWindow = 0.2;

/// Hard bounds for the auto-exposure gain (+1.26 EV / -0.86 EV).
const double kExposureGainMin = 0.55;
const double kExposureGainMax = 2.40;

/// How far the 99.5th percentile may be pushed past 1.0 by the
/// auto-exposure gain. The tone curve's highlight shoulder absorbs the
/// excess, so a slightly generous limit is safe.
const double kExposureHighlightLimit = 1.10;

/// Target luma standard deviation. Below it the frame is flat and gets an
/// S-curve boost; above it the frame is harsh and is tamed by the shadow
/// lift and the highlight shoulder instead.
const double kTargetSigma = 0.215;

/// Base shadow lift (the filmic "lifted blacks").
const double kShadowLiftBase = 0.18;

/// Luma standard deviation above which a frame counts as harsh.
const double kHarshSigma = 0.26;

/// Target mean saturation. Frames below it get vibrance.
const double kTargetSaturation = 0.32;

/// Mean saturation below which a frame also gets a flat saturation lift.
const double kFlatSaturation = 0.24;

/// Rec.709 luma, same weights as the shader/CPU grade.
double _luma(double r, double g, double b) => 0.299 * r + 0.587 * g + 0.114 * b;

/// Mean-RGB hue in degrees (0..360, red = 0). Achromatic input returns 0.0
/// (the caller only reads hue when saturation is significant).
double _meanHue(double r, double g, double b) {
  final double mx = math.max(r, math.max(g, b));
  final double mn = math.min(r, math.min(g, b));
  final double d = mx - mn;
  if (d <= 1e-6) return 0.0;
  double h;
  if (mx == r) {
    h = 60.0 * ((g - b) / d % 6.0);
  } else if (mx == g) {
    h = 60.0 * ((b - r) / d + 2.0);
  } else {
    h = 60.0 * ((r - g) / d + 4.0);
  }
  if (h < 0.0) h += 360.0;
  return h;
}

/// Index of the first histogram bin whose cumulative count reaches
/// [fraction] of the samples (ascending scan). Returns the last bin when
/// the fraction is above the total (degenerate frames).
int _percentileBin(List<int> hist, int total, double fraction) {
  final double need = total * fraction;
  int acc = 0;
  for (int b = 0; b < hist.length; b++) {
    acc += hist[b];
    if (acc >= need) return b;
  }
  return hist.length - 1;
}

/// Estimates the 1-tap Enhance parameters for [small].
///
/// Top-level and pure (no Flutter) so it can run in an isolate. See the
/// file docs for the exact formulas.
EnhanceAnalysis analyzeEnhance(img.Image small) {
  final int w = small.width;
  final int h = small.height;
  if (w <= 0 || h <= 0) return EnhanceAnalysis.none;

  final int longSide = math.max(w, h);
  final int step = longSide > 256 ? ((longSide + 255) ~/ 256) : 1;

  const int bins = 64;
  final List<int> hist = List<int>.filled(bins, 0);

  double sumR = 0.0, sumG = 0.0, sumB = 0.0;
  double sumLuma = 0.0, sumLuma2 = 0.0, sumSat = 0.0;
  double sumRc6 = 0.0, sumGc6 = 0.0, sumBc6 = 0.0;
  double hazeR = 0.0, hazeG = 0.0, hazeB = 0.0;
  double darkR = 0.0, darkG = 0.0, darkB = 0.0;
  double nR = 0.0, nG = 0.0, nB = 0.0;
  int count = 0;
  int hazeCount = 0;
  int darkCount = 0;
  int nCount = 0;
  int warmPx = 0;
  int coolPx = 0;
  int nearWhite = 0;
  int clipped = 0;

  img.Pixel? pixel;
  for (int y = 0; y < h; y += step) {
    for (int x = 0; x < w; x += step) {
      pixel = small.getPixel(x, y, pixel);
      final double r = pixel.r / 255.0;
      final double g = pixel.g / 255.0;
      final double b = pixel.b / 255.0;
      sumR += r;
      sumG += g;
      sumB += b;
      count++;

      final double luma = _luma(r, g, b);
      sumLuma += luma;
      sumLuma2 += luma * luma;
      final int bin = (luma * bins).floor().clamp(0, bins - 1);
      hist[bin]++;

      final double mx = math.max(r, math.max(g, b));
      final double mn = math.min(r, math.min(g, b));
      sumSat += (mx - mn) / math.max(mx, 1e-6);

      // The white-balance reference population: mid-tone, near-neutral and
      // NOT skin. These are the only pixels that can carry the ILLUMINANT
      // — a warm face is the subject, a warm sheet of paper under a
      // tungsten lamp is the light.
      final bool midTone = luma >= kNeutralMinLuma && luma <= kNeutralMaxLuma;
      if (midTone) {
        final double sat = (mx - mn) / math.max(mx, 1e-6);
        if (sat < kNeutralSat) {
          if (enhanceSkinMask(r, g, b) < kNeutralSkinLimit) {
            nR += r;
            nG += g;
            nB += b;
            nCount++;
          }
        } else {
          // Chromatic pixels: warm or cool. A frame that carries BOTH has
          // colours, not a cast.
          if (r > b + kChromaticWarmDelta) {
            warmPx++;
          } else if (b > r + kChromaticWarmDelta) {
            coolPx++;
          }
        }
      }

      // Shades-of-gray: Minkowski p=6 mean over the chromaticity.
      final double sumRgb = r + g + b;
      if (sumRgb > 1e-6) {
        final double rc = r / sumRgb;
        final double gc = g / sumRgb;
        final double bc = b / sumRgb;
        final double rc3 = rc * rc * rc;
        final double gc3 = gc * gc * gc;
        final double bc3 = bc * bc * bc;
        sumRc6 += rc3 * rc3;
        sumGc6 += gc3 * gc3;
        sumBc6 += bc3 * bc3;
      }

      // Highlight pressure: near-white (about to clip) and hard-clipped.
      if (mx >= 0.97) nearWhite++;
      if (r >= 0.996 || g >= 0.996 || b >= 0.996) clipped++;

      if (mx - mn < 0.12 && luma >= 0.3 && luma <= 0.8) {
        hazeR += r;
        hazeG += g;
        hazeB += b;
        hazeCount++;
      }
      // The darkest region: if the frame is veiled, the veil is what
      // lifts these pixels, so their colour is close to the veil colour.
      if (luma < 0.25) {
        darkR += r;
        darkG += g;
        darkB += b;
        darkCount++;
      }
    }
  }
  if (count == 0) return EnhanceAnalysis.none;

  final double avgR = sumR / count;
  final double avgG = sumG / count;
  final double avgB = sumB / count;
  final double meanLuma = sumLuma / count;
  final double variance = math.max(
    0.0,
    sumLuma2 / count - meanLuma * meanLuma,
  );
  final double sigma = math.sqrt(variance);
  final double meanPixelSat = sumSat / count;
  final double nearWhiteFrac = nearWhite / count;
  final double clippedFrac = clipped / count;

  // White patch: luma bin threshold holding the brightest ~5%.
  int thrBin = bins - 1;
  {
    final double needTop = count * 0.05;
    int acc = 0;
    for (int b = bins - 1; b >= 0; b--) {
      acc += hist[b];
      if (acc >= needTop) {
        thrBin = b;
        break;
      }
    }
  }
  double topR = 0.0, topG = 0.0, topB = 0.0;
  int topN = 0;
  for (int y = 0; y < h; y += step) {
    for (int x = 0; x < w; x += step) {
      pixel = small.getPixel(x, y, pixel);
      final double r = pixel.r / 255.0;
      final double g = pixel.g / 255.0;
      final double b = pixel.b / 255.0;
      final int bin = (_luma(r, g, b) * bins).floor().clamp(0, bins - 1);
      if (bin >= thrBin) {
        topR += r;
        topG += g;
        topB += b;
        topN++;
      }
    }
  }

  // 1. White balance, G-anchored, with the mono + hue guards.
  double wbGainR = 1.0;
  double wbGainB = 1.0;
  final double spread =
      math.max(avgR, math.max(avgG, avgB)) -
      math.min(avgR, math.min(avgG, avgB));
  final double meanMax = math.max(avgR, math.max(avgG, avgB));
  final double meanSat = meanMax > 1e-3
      ? (meanMax - math.min(avgR, math.min(avgG, avgB))) / meanMax
      : 0.0;
  final double meanHue = _meanHue(avgR, avgG, avgB);
  final bool hueGuard =
      meanSat > kHueGuardSat &&
      (meanHue <= kHueGuardWarmDeg || meanHue >= 360.0 - kHueGuardWarmDeg);
  if (spread >= 0.08 && !hueGuard) {
    final double grayR = avgR > 1e-3 ? avgG / avgR : 1.0;
    final double grayB = avgB > 1e-3 ? avgG / avgB : 1.0;
    double whiteR = 1.0;
    double whiteB = 1.0;
    if (topN > 0) {
      final double tR = topR / topN;
      final double tG = topG / topN;
      final double tB = topB / topN;
      whiteR = tR > 1e-3 ? tG / tR : 1.0;
      whiteB = tB > 1e-3 ? tG / tB : 1.0;
    }
    // Shades-of-gray (Minkowski p=6 over the chromaticity), G-anchored.
    const double p6 = 1.0 / 6.0;
    final double sogR = math.pow(sumRc6 / count, p6).toDouble();
    final double sogG = math.pow(sumGc6 / count, p6).toDouble();
    final double sogB = math.pow(sumBc6 / count, p6).toDouble();
    final double sogGainR = sogR > 1e-6 ? sogG / sogR : 1.0;
    final double sogGainB = sogB > 1e-6 ? sogG / sogB : 1.0;

    // The global estimators: the frame's overall colour balance. They are
    // the fallback, NOT the primary source — they cannot tell a cast from
    // a subject (they cool a sunset just as happily as they cool a
    // tungsten-lit page).
    final double globalR = _clampGain(
      0.25 * _clampGain(grayR) +
          0.30 * _clampGain(whiteR) +
          0.45 * _clampGain(sogGainR),
    );
    final double globalB = _clampGain(
      0.25 * _clampGain(grayB) +
          0.30 * _clampGain(whiteB) +
          0.45 * _clampGain(sogGainB),
    );

    // CAST OR SCENE? Two questions, in this order.
    //
    // 1. Does the frame carry colours of its own? A warm sky next to a
    //    cool sky (a sunset), a green field under a blue one: the frame
    //    mixes warm and cool CHROMATIC content, so its overall balance is
    //    a picture, not a lamp. A cast shifts everything uniformly and
    //    leaves no opposite chromatic population behind — that is why a
    //    page under a tungsten bulb still gets corrected while a sunset
    //    does not.
    // 2. Otherwise the near-neutral population decides. A cast shifts the
    //    neutrals too (a sheet of paper under a tungsten lamp is warm);
    //    a subject's colour does not. When the neutrals agree with the
    //    frame's overall warmth, the warmth is the light and it goes.
    final bool mixedChromatic =
        warmPx > count * kMixedChromaticMin && coolPx > count * kMixedChromaticMin;
    final double frameWarmth = (avgR - avgB) / math.max(avgR + avgB, 1e-6);
    final bool haveNeutrals = nCount >= count * kNeutralMinFrac;
    if (mixedChromatic) {
      // The frame has colours of its own — leave the balance alone.
    } else if (haveNeutrals) {
      final double nMeanR = nR / nCount;
      final double nMeanG = nG / nCount;
      final double nMeanB = nB / nCount;
      final double neutralWarmth =
          (nMeanR - nMeanB) / math.max(nMeanR + nMeanB, 1e-6);
      final bool agrees = (neutralWarmth > 0) == (frameWarmth > 0);
      if (agrees && neutralWarmth.abs() >= kCastWarmthMin) {
        // The cast shows in the neutrals: correct it from them, with the
        // global estimators only as a stabiliser.
        final double neutralR = nMeanG / math.max(nMeanR, 1e-3);
        final double neutralB = nMeanG / math.max(nMeanB, 1e-3);
        wbGainR = _clampGain(
          0.70 * _clampGain(neutralR) + 0.30 * globalR,
        );
        wbGainB = _clampGain(
          0.70 * _clampGain(neutralB) + 0.30 * globalB,
        );
      }
      // else: the neutrals and the frame disagree, or there is no cast
      // worth speaking of — leave the colour exactly as it was shot.
    } else {
      wbGainR = globalR;
      wbGainB = globalB;
    }
  }

  // 1b. Tint damping (the GREEN/MAGENTA axis only).
  //
  // The G-anchored gains are two independent axes in log space:
  //   temperature T = (log R - log B) / 2  — warm/cool, trusted;
  //   tint        K = (log R + log B) / 2  — green/magenta, opinionated.
  // K moves R and B TOGETHER against G, which is exactly what turns a pink
  // sunset ordinary (the estimator reads magenta as a cast and pushes
  // green) or a greenish face magenta (the face is the frame, so the
  // estimator reads it as a cast and over-corrects). Temperature is left
  // alone: a tungsten page still gets white. The tint keeps
  // [kTintDamping] of its estimate, capped at [kTintMaxLog].
  {
    final double logR = math.log(math.max(wbGainR, 1e-6));
    final double logB = math.log(math.max(wbGainB, 1e-6));
    final double temperature = 0.5 * (logR - logB);
    final double tint = (0.5 * (logR + logB) * kTintDamping).clamp(
      -kTintMaxLog,
      kTintMaxLog,
    );
    wbGainR = math.exp(temperature + tint);
    wbGainB = math.exp(-temperature + tint);
  }

  // 2. Levels from the 64-bin luma histogram.
  final double need = count * 0.005;
  int lo = 0;
  {
    int acc = 0;
    for (int b = 0; b < bins; b++) {
      acc += hist[b];
      if (acc >= need) {
        lo = b;
        break;
      }
    }
  }
  int hi = bins - 1;
  {
    int acc = 0;
    for (int b = bins - 1; b >= 0; b--) {
      acc += hist[b];
      if (acc >= need) {
        hi = b;
        break;
      }
    }
  }
  double blackPt = lo / bins;
  double whitePt = (hi + 1) / bins;

  // 3. Auto-exposure and the tone window.
  //
  // The green-anchored balance is nearly luminance-neutral, but the
  // residual shift is measured and compensated so the WB never changes
  // the picture's brightness on its own.
  final double lumaBefore = _luma(avgR, avgG, avgB);
  final double lumaAfter = _luma(
    avgR * wbGainR,
    avgG,
    avgB * wbGainB,
  );
  final double wbRatio = lumaBefore > 1e-6 ? lumaAfter / lumaBefore : 1.0;
  final int medianBin = _percentileBin(hist, count, 0.5);
  final double medianLuma = (medianBin + 0.5) / bins;
  final double key = medianLuma * wbRatio;

  // The tone window.
  //
  // A HIGH-KEY frame (a document, a snow scene — the median above
  // [kExposureKeyHigh]) keeps its blacks: crushing them would grey the
  // picture down, so only the white point anchors it and the paper stays
  // paper. A low-key frame gets the classic auto-levels window (the blacks
  // crushed, the whites at 1), widened symmetrically when the frame is too
  // flat — the extra contrast would be amplified noise.
  final bool highKey = key > kExposureKeyHigh;
  if (highKey) {
    blackPt = 0.0;
  } else if (whitePt - blackPt < kMinToneWindow) {
    final double c = ((whitePt + blackPt) / 2).clamp(0.1, 0.9);
    blackPt = c - kMinToneWindow / 2;
    whitePt = c + kMinToneWindow / 2;
  }

  // The gain that lands the frame's midtone on the target AFTER the
  // stretch: the window maps to 0..1, so the gain has to be solved
  // against it. A frame that is already bright is never darkened — only
  // lifted — so a well-exposed picture keeps its level.
  double exposureGain = 1.0;
  if (!highKey) {
    final double span = whitePt - blackPt;
    if (span > 1e-6) {
      final double solved =
          (kExposureTargetMid * span + blackPt) / math.max(key, 1e-3);
      if (solved > 1.0) exposureGain = solved;
    }
  }
  final double highLuma = whitePt * wbRatio;
  final double highlightLimit =
      kExposureHighlightLimit / math.max(highLuma, 0.08);
  exposureGain = math.min(exposureGain, highlightLimit);
  // Overexposure fix: a frame with a meaningful share of HARD-clipped
  // pixels is pulled down, so the blown area comes back off pure white
  // instead of ending on a flat white wall. The pull is scaled by how much
  // of the frame is actually clipped (a few specular pixels must not
  // darken the whole photo).
  if (clippedFrac > 0.0005) {
    final double pull = 0.06 * math.min(clippedFrac * 20.0, 1.0);
    exposureGain = math.min(exposureGain, 1.0 - pull);
  }
  exposureGain = exposureGain.clamp(kExposureGainMin, kExposureGainMax);

  // 4. Contrast: only flat frames get the S-curve; harsh frames are
  // fixed with the shadow lift and the highlight shoulder instead.
  double contrast = 0.0;
  if (sigma < kTargetSigma - 0.02) {
    contrast = (((kTargetSigma - sigma) / 0.13).clamp(0.0, 1.0)) * 0.75;
  }

  // 5. Shadow lift: a filmic base plus extra for harsh frames.
  double shadowLift = kShadowLiftBase;
  if (sigma > kHarshSigma) {
    shadowLift = (kShadowLiftBase + (sigma - kHarshSigma) * 2.2).clamp(
      0.0,
      0.85,
    );
  }

  // 6. Highlight recovery: the shoulder knee. Driven by how much of the
  // frame is near-white or hard-clipped. The floor matters: even a
  // perfectly exposed frame gets a soft filmic roll-off, so the whites
  // never end on a hard edge.
  double highlightRecover = (0.40 + nearWhiteFrac * 8.0).clamp(0.0, 1.0);
  if (clippedFrac > 0.002) {
    highlightRecover = math.max(highlightRecover, 0.85);
  }
  if (sigma > 0.28) {
    highlightRecover = math.max(
      highlightRecover,
      ((sigma - 0.28) / 0.10).clamp(0.0, 1.0),
    );
  }

  // 7. Saturation / vibrance.
  double vibrance =
      0.12 +
      (((kTargetSaturation - meanPixelSat) / kTargetSaturation).clamp(
        0.0,
        1.0,
      )) *
          0.55;
  vibrance = vibrance.clamp(0.0, 0.85);
  final double saturation = meanPixelSat < kFlatSaturation ? 0.10 : 0.0;

  // 8. Tone: the frame's warmth drives a cool-shadow / warm-highlight
  // split (the classic cinematic separation) — but the split never fights
  // the scene: a warm picture (a sunset, a golden hour) keeps warm
  // shadows instead of being cooled in them.
  final double warmth = ((avgR - avgB) / math.max(avgR + avgB, 1e-6)).clamp(
    -0.4,
    0.4,
  );
  final double toneShadow = (-0.22 + 0.55 * warmth).clamp(-0.55, 0.55);
  final double toneHighlight = (0.20 + 0.35 * warmth).clamp(-0.55, 0.55);

  // 9. Dehaze from the low-saturation mid-tone share. The raw share is
  // only half the story: a veil is what LIFTS the blacks, so the darkest
  // region of the frame must sit close to the veil colour. A properly
  // exposed low-saturation photo has near-black shadows and a bright
  // mid-tone, and must NOT be pushed around — hence the proximity test.
  final (double, double, double) hazeColor = hazeCount > 0
      ? (hazeR / hazeCount, hazeG / hazeCount, hazeB / hazeCount)
      : (avgR, avgG, avgB);
  double dehaze = 0.0;
  if (hazeCount > 0) {
    // No dark pixels at all means the whole frame sits at the veil level
    // (a uniform, definitely veiled frame) — the veil is present.
    final double veilFactor = darkCount > 0
        ? (() {
            final double veilLuma = _luma(
              hazeColor.$1,
              hazeColor.$2,
              hazeColor.$3,
            );
            final double veilChroma =
                math.max(hazeColor.$1, math.max(hazeColor.$2, hazeColor.$3)) -
                math.min(hazeColor.$1, math.min(hazeColor.$2, hazeColor.$3));
            final double darkLuma = _luma(
              darkR / darkCount,
              darkG / darkCount,
              darkB / darkCount,
            );
            final double darkChroma =
                math.max(darkR, math.max(darkG, darkB)) / darkCount -
                math.min(darkR, math.min(darkG, darkB)) / darkCount;
            final double veilDistance =
                (veilLuma - darkLuma).abs() +
                0.5 * (veilChroma - darkChroma).abs();
            return (1.0 - veilDistance / 0.25).clamp(0.0, 1.0);
          })()
        : 1.0;
    dehaze = (hazeCount / count * 0.8).clamp(0.0, 0.6) * veilFactor;
  }

  return EnhanceAnalysis(
    wbGainR: wbGainR,
    wbGainB: wbGainB,
    blackPt: blackPt,
    whitePt: whitePt,
    dehaze: dehaze,
    hazeColor: hazeColor,
    exposureGain: exposureGain,
    contrast: contrast,
    shadowLift: shadowLift,
    vibrance: vibrance,
    saturation: saturation,
    toneShadow: toneShadow,
    toneHighlight: toneHighlight,
    highlightRecover: highlightRecover,
    look: kEnhanceLookStrength,
  );
}
