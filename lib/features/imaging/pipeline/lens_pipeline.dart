import 'dart:typed_data';

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';

/// Grade parameters driving `shaders/lens_filter.frag`.
///
/// Stage 0: every field defaults to 0 (identity) — the shader draws 1:1.
/// Stage 1 (Adjust) binds real sliders to these fields.
/// Stage 2 (Task 2.3) adds the LUT look: [filterId] selects the atlas
/// texture (bound to sampler slot 1, NOT a float uniform), [filterStrength]
/// drives float slot 11.
///
/// Fixed UI ranges (enforced at the [EditorStateNotifier] setters):
/// - exposure: -3..+3 stops, passed to the shader as-is.
/// - contrast/saturation: -100..100, mapped to the shader as /100.
/// - temp/tint: -100..100, mapped to the shader as /100.
/// - shadows/highlights: -100..100, mapped to the shader as /100.
/// - structure: -100..100 (SIGNED), local-contrast (clarity) amount in the
///   Hypic Structure sense — NOT a naive sharpen; negative softens the
///   texture. Normalized to -1..1 in slot 8.
/// - intensity: 0..1 master mix raw<->grade.
/// - filterId: 0..8, `LensFilterId.index` (fixed enum order, none = 0).
///   Selects the LUT atlas texture; never enters [toUniforms].
/// - filterStrength: 0..1, LUT mix graded<->lut (slot 11).
/// - Enhance (professional 1-tap auto-grade): enhR/enhB are G-anchored WB
///   gains (shader slots 12..13); enhBlack/enhWhite bound the auto-levels
///   window (slots 14..15); enhDehaze + enhHazeR/G/B carry the veil amount
///   and color (slots 16..19); enhanceStrength is the master mix 0..1
///   (slot 20); enhExposure/enhContrast/enhShadowLift/enhVibrance/
///   enhSaturation/enhToneShadow/enhToneHighlight/enhHighlightRecover
///   carry the derived auto-grade (slots 49..56) and enhLook the built-in
///   cinematic finish (slot 57). All default to neutral
///   AND enhanceStrength defaults to 0, so [identity] (and any params
///   without an analysis) skip the stage everywhere: shader mixes are
///   no-ops, the CPU path early-outs.
///   The values themselves come from [EnhanceAnalysis] (see enhance_cache);
///   Task 3.3 wires them in via `EditorStateToLensParams` (sync
///   `EnhanceCache.getOrNone` read + `enhanceStrength/100` mix).
/// - Task 4.2 (Selective, LAST grade before intensity): selMode selects
///   the mask shape (0 = off, 1 = radial, 2 = linear, 3 = brush from the
///   `uSelMask` texture, sampler slot 2); selCx/selCy/selRadius/selFeather/
///   selAngle/selWidth/selAspect/selInvert mirror `SelectiveGeometry`
///   1:1 (shader slots 22..29); selStrength is the mask mix 0..1
///   (slot 30); selExp/selCon/selSat are the local grade inside the mask
///   (slots 31..33, exposure/contrast/saturation only — structure-lite
///   skipped, documented 4.x limit). All default to neutral AND
///   selMode defaults to 0 + selStrength to 0, so [identity] (and any
///   params without selective state, e.g. `toLensParams` before Task 4.4)
///   skip the stage everywhere: the shader mix weight is 0, the CPU path
///   (Task 4.3) ignores the block.
/// - Task 6.2 (Blur, FIRST stage before enhance): blurMode selects the
///   mask source (0 = off, 1 = auto ML mask, 2 = manual raster from the
///   `uBlurMask` texture, sampler slot 3); blurRadius is the bokeh radius
///   as a fraction of min(w,h) 0..0.05 (shader slot 35); blurFeather 0..1
///   softens the mask edge (slot 36, 0 = hard step); blurStrength is the
///   blurred<->sharp mix 0..1 (slot 37); blurInvert 0/1 blurs the subject
///   instead of the background (slot 38). All default to neutral AND
///   blurMode defaults to 0 + blurStrength to 0, so [identity] skips the
///   stage everywhere: mode 0 exits before any mask read, strength 0
///   composites to raw 1:1. The CPU export ignores the block until
///   Task 6.3 (preview-only stage); the real mask texture arrives in
///   Task 6.4 (MaskManager/BlurCache -> ui.Image).
/// - Task 7.2 (Rays, Tyndall stage AFTER selective, BEFORE intensity):
///   rayOn 0/1 gates the stage (shader slot 39); rayX/rayY carry the sun
///   in normalized uv 0..1, top-left origin like selective (slots 40..41,
///   pass through unclamped so an off-frame sun keeps working);
///   rayIntensity 0..1 is the shaft strength (slot 42);
///   rayLength 0..1 is the march length as a share of the frame diagonal
///   (slot 43, <= 0 degrades to a tap-free point glow); rayWarmth 0..1
///   tints neutral-white -> golden (slot 44, mirrors `raysTint`);
///   rayDensity 0..1 drives streak frequency/sharpness (slot 45, mirrors
///   `raysStreak`). Defaults mirror [RaysParams] (.5/.2 source, 0 intensity,
///   .6 length, .7 warmth, .5 density) AND rayOn defaults to 0, so
///   [identity] skips the stage everywhere: the shader exits before any
///   tap, the CPU export (7.3) ignores the block. Task 7.4 wires
///   `RaysState` in via `EditorStateToLensParams` (rayOn gate +
///   intensity/length/warmth/density /100, source as-is).
class LensParams {
  const LensParams({
    this.exposure = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.temp = 0,
    this.tint = 0,
    this.shadows = 0,
    this.highlights = 0,
    this.structure = 0,
    this.intensity = 1,
    this.filterId = 0,
    this.filterStrength = 1,
    this.enhR = 1,
    this.enhB = 1,
    this.enhBlack = 0,
    this.enhWhite = 1,
    this.enhDehaze = 0,
    this.enhHazeR = 0.5,
    this.enhHazeG = 0.5,
    this.enhHazeB = 0.5,
    this.enhanceStrength = 0,
    this.enhExposure = 1,
    this.enhContrast = 0,
    this.enhShadowLift = 0,
    this.enhVibrance = 0,
    this.enhSaturation = 0,
    this.enhToneShadow = 0,
    this.enhToneHighlight = 0,
    this.enhHighlightRecover = 0,
    this.enhLook = 0,
    this.selMode = 0,
    this.selCx = 0.5,
    this.selCy = 0.5,
    this.selRadius = 0.35,
    this.selFeather = 0.5,
    this.selAngle = 90.0,
    this.selWidth = 0.5,
    this.selAspect = 1.0,
    this.selInvert = 0,
    this.selStrength = 0,
    this.selExp = 0,
    this.selCon = 0,
    this.selSat = 0,
    this.blurMode = 0,
    this.blurRadius = 0.02,
    this.blurFeather = 0.5,
    this.blurStrength = 0,
    this.blurInvert = 0,
    this.rayOn = 0,
    this.rayX = 0.5,
    this.rayY = 0.2,
    this.rayIntensity = 0,
    this.rayLength = 0.6,
    this.rayWarmth = 0.7,
    this.rayDensity = 0.5,
    int? rayMode,
    int? rayKind,
    int? rayType,
    double? rayAngle,
    double? rayDirection,
    double? rayWidth,
    double? raySpread,
  }) : rayMode = rayMode ?? rayKind ?? rayType ?? 0,
       rayAngle = rayAngle ?? rayDirection ?? 0.0,
       rayWidth = rayWidth ?? raySpread ?? 1.0,
       assert(filterId >= 0 && filterId <= 8, 'filterId must be 0..8'),
       assert(selMode >= 0 && selMode <= 3, 'selMode must be 0..3'),
       assert(selInvert == 0 || selInvert == 1, 'selInvert must be 0 or 1'),
       assert(blurMode >= 0 && blurMode <= 2, 'blurMode must be 0..2'),
       assert(blurInvert == 0 || blurInvert == 1, 'blurInvert must be 0 or 1'),
       assert(rayOn == 0 || rayOn == 1, 'rayOn must be 0 or 1');

  final double exposure;
  final double contrast;
  final double saturation;
  final double temp;
  final double tint;
  final double shadows;
  final double highlights;

  /// Local-contrast amount, -100..100 (SIGNED; negative softens the texture),
  /// Hypic Structure sense. Normalized to -1..1 via [structureNormalized]
  /// into [toUniforms] slot 8.
  final double structure;

  /// Master mix raw<->grade, 0..1.
  final double intensity;

  /// LUT atlas selector: `LensFilterId.index` (0 = none/identity atlas).
  /// Bound as sampler slot 1 via `LutManager.lutAtlasImage`, never as a
  /// float uniform — a LUT id is categorical, not interpolable.
  final int filterId;

  /// LUT mix graded<->lut, 0..1. Normalized via [filterStrengthNormalized]
  /// into [toUniforms] index 9 (shader float slot 11).
  final double filterStrength;

  /// Enhance white-balance gain for R (green-anchored). Neutral 1.0.
  /// Into [toUniforms] index 10 (shader float slot 12).
  final double enhR;

  /// Enhance white-balance gain for B (green-anchored). Neutral 1.0.
  /// Into [toUniforms] index 11 (shader float slot 13).
  final double enhB;

  /// Enhance auto-levels black point. Neutral 0.0.
  /// Into [toUniforms] index 12 (shader float slot 14).
  final double enhBlack;

  /// Enhance auto-levels white point. Neutral 1.0.
  /// Into [toUniforms] index 13 (shader float slot 15).
  final double enhWhite;

  /// Enhance dehaze veil amount. Neutral 0.0.
  /// Into [toUniforms] index 14 (shader float slot 16).
  final double enhDehaze;

  /// Enhance veil color channels (mean color of the hazy pixels).
  /// Neutral 0.5 each; only read when [enhDehaze] > 0.
  /// Into [toUniforms] indices 15..17 (shader float slots 17..19).
  final double enhHazeR;
  final double enhHazeG;
  final double enhHazeB;

  /// Enhance master mix raw<->enhanced, 0..1. Neutral 0.0 (stage skipped).
  /// Into [toUniforms] index 18 (shader float slot 20).
  final double enhanceStrength;

  /// Enhance auto-exposure gain (linear multiplier). Neutral 1.0.
  /// Into [toUniforms] index 47 (shader float slot 49).
  final double enhExposure;

  /// Enhance Hermite S-curve contrast amount, 0..1. Neutral 0.0.
  /// Into [toUniforms] index 48 (shader float slot 50).
  final double enhContrast;

  /// Enhance shadow lift amount, 0..1. Neutral 0.0.
  /// Into [toUniforms] index 49 (shader float slot 51).
  final double enhShadowLift;

  /// Enhance vibrance amount, -1..1. Neutral 0.0.
  /// Into [toUniforms] index 50 (shader float slot 52).
  final double enhVibrance;

  /// Enhance flat saturation amount, -1..1. Neutral 0.0.
  /// Into [toUniforms] index 51 (shader float slot 53).
  final double enhSaturation;

  /// Enhance split-tone shift for the shadows, -1..1. Neutral 0.0.
  /// Into [toUniforms] index 52 (shader float slot 54).
  final double enhToneShadow;

  /// Enhance split-tone shift for the highlights, -1..1. Neutral 0.0.
  /// Into [toUniforms] index 53 (shader float slot 55).
  final double enhToneHighlight;

  /// Enhance highlight shoulder amount, 0..1. Neutral 0.0.
  /// Into [toUniforms] index 54 (shader float slot 56).
  final double enhHighlightRecover;

  /// Strength of the built-in cinematic look (0..1). Neutral 0.0.
  ///
  /// A whisper of the Cinematic filter that finishes the enhance grade
  /// (`kEnhanceLookStrength` = 0.30 at full strength). Into [toUniforms]
  /// index 55 (shader float slot 57).
  final double enhLook;

  /// Selective mask shape: 0 = off, 1 = radial, 2 = linear, 3 = brush.
  /// Categorical (like [filterId]) but carried as a float uniform because
  /// the shader branches on ranges (`< 0.5 / < 1.5 / < 2.5`).
  /// Into [toUniforms] index 19 (shader float slot 21).
  final int selMode;

  /// Selective mask center in normalized uv 0..1 (top-left origin,
  /// mirrors `SelectiveGeometry.center`).
  /// Into [toUniforms] indices 20..21 (shader float slots 22..23).
  final double selCx;
  final double selCy;

  /// Radial disc radius in uv units (0..1, mirrors geometry `radius`).
  /// Into [toUniforms] index 22 (shader float slot 24).
  final double selRadius;

  /// Edge softness 0..1 (0 = hard step branch, mirrors `feather`).
  /// Into [toUniforms] index 23 (shader float slot 25).
  final double selFeather;

  /// Linear gradient direction in degrees 0..360 (mirrors `angle`).
  /// Into [toUniforms] index 24 (shader float slot 26).
  final double selAngle;

  /// Linear half-band width in uv units (mirrors `width`).
  /// Into [toUniforms] index 25 (shader float slot 27).
  final double selWidth;

  /// Preview width/height ratio for the radial ellipse (mirrors `aspect`).
  /// Into [toUniforms] index 26 (shader float slot 28).
  /// STORED fallback only (Task 4.4 aspect contract): the preview painter
  /// overwrites slot 28 with the paint size aspect every frame and the CPU
  /// export recomputes it from the decoded frame `w/h`, so this value is
  /// never trusted downstream — the ellipse looks identical in both
  /// contexts despite different resolutions.
  final double selAspect;

  /// Invert flag 0/1 (mirrors `SelectiveGeometry.invert`; int so the
  /// uniform mapping is exact, shader tests `> 0.5`).
  /// Into [toUniforms] index 27 (shader float slot 29).
  final int selInvert;

  /// Selective master mix 0..1. Neutral 0.0 (stage skipped).
  /// Into [toUniforms] index 28 (shader float slot 30).
  final double selStrength;

  /// Local grade inside the mask: exposure stops, contrast/saturation
  /// in shader units (same scale as the global fields).
  /// Into [toUniforms] indices 29..31 (shader float slots 31..33).
  final double selExp;
  final double selCon;
  final double selSat;

  /// Blur mask source: 0 = off, 1 = auto (ML mask), 2 = manual raster.
  /// Categorical (like [filterId]/[selMode]) carried as a float because
  /// the shader branches on ranges (`< 0.5` off).
  /// Into [toUniforms] index 32 (shader float slot 34).
  final int blurMode;

  /// Bokeh radius as a fraction of min(w,h), 0..0.05. The shader knows
  /// only the resolution, so it scales tap offsets by min(w,h)/w,h.
  /// Into [toUniforms] index 33 (shader float slot 35).
  final double blurRadius;

  /// Mask edge softness 0..1 (0 = hard step branch, mirrors the selective
  /// `feather <= 0.0` guard against degenerate smoothstep).
  /// Into [toUniforms] index 34 (shader float slot 36).
  final double blurFeather;

  /// Blurred<->sharp mix 0..1. Neutral 0.0 (stage composites to raw 1:1).
  /// Into [toUniforms] index 35 (shader float slot 37).
  final double blurStrength;

  /// Invert flag 0/1: blur the subject instead of the background.
  /// Into [toUniforms] index 36 (shader float slot 38).
  final int blurInvert;

  /// Rays stage gate 0/1: 0 skips the stage before any tap (like
  /// [selMode]/[blurMode] 0), 1 arms the 24-tap march.
  /// Into [toUniforms] index 37 (shader float slot 39).
  final int rayOn;

  /// Sun position in normalized uv, top-left origin (mirrors
  /// `RaysParams.source`; same convention as [selCx]/[selCy]).
  /// Pass through UNCLAMPED (an off-frame sun keeps marching correctly).
  /// Into [toUniforms] indices 38..39 (shader float slots 40..41).
  final double rayX;
  final double rayY;

  /// Shaft strength 0..1 (mirrors `RaysParams.intensity`; 0 = identity).
  /// Into [toUniforms] index 40 (shader float slot 42).
  final double rayIntensity;

  /// March length as a share of the frame diagonal 0..1 (mirrors
  /// `RaysParams.length`; <= 0 degrades to a tap-free point glow).
  /// Into [toUniforms] index 41 (shader float slot 43).
  final double rayLength;

  /// Shaft color 0..1: 0 = neutral white, 1 = golden (mirrors
  /// `RaysParams.warmth` / `raysTint`).
  /// Into [toUniforms] index 42 (shader float slot 44).
  final double rayWarmth;

  /// Streak frequency/sharpness 0..1 (mirrors `RaysParams.density` /
  /// `raysStreak`).
  /// Into [toUniforms] index 43 (shader float slot 45).
  final double rayDensity;

  /// Ray kind: 0 = bright-source dependent, 1 = fog-like.
  /// Into [toUniforms] index 44 (shader float slot 46).
  final int rayMode;

  /// Ray direction in degrees 0..360.
  /// Into [toUniforms] index 45 (shader float slot 47).
  final double rayAngle;

  /// Ray angular spread 0..1: 1 = all sides.
  /// Into [toUniforms] index 46 (shader float slot 48).
  final double rayWidth;

  /// Identity grade: shader output equals the input texture.
  static const LensParams identity = LensParams();

  /// Structure normalized to -1..1 for the CPU/preview path.
  double get structureNormalized => (structure / 100).clamp(-1.0, 1.0);

  /// LUT strength normalized to 0..1 for the shader/CPU path.
  double get filterStrengthNormalized =>
      filterStrength.clamp(0.0, 1.0).toDouble();

  /// Float-uniform slot order. Must match the declaration order in
  /// `lens_filter.frag`: exposure(0), contrast(1), saturation(2), temp(3),
  /// tint(4), shadows(5), highlights(6), intensity(7),
  /// structure(8, SIGNED -1..1: negative softens),
  /// then uResolution (w=9, h=10), then uFilterStrength (11), then the
  /// Enhance block: enhR(12), enhB(13), enhBlack(14), enhWhite(15),
  /// enhDehaze(16), enhHazeR(17), enhHazeG(18), enhHazeB(19),
  /// enhanceStrength(20), then the Task 4.2 Selective block:
  /// selMode(21), selCx(22), selCy(23), selRadius(24), selFeather(25),
  /// selAngle(26), selWidth(27), selAspect(28), selInvert(29),
  /// selStrength(30), selExp(31), selCon(32), selSat(33), then the
  /// Task 6.2 Blur block: blurMode(34), blurRadius(35), blurFeather(36),
  /// blurStrength(37), blurInvert(38), then the Task 7.2 Rays block:
  /// rayOn(39), rayX(40), rayY(41), rayIntensity(42), rayLength(43),
  /// rayWarmth(44), rayDensity(45), rayMode(46), rayAngle(47),
  /// rayWidth(48), and finally the derived auto-grade tail:
  /// enhExposure(49), enhContrast(50), enhShadowLift(51), enhVibrance(52),
  /// enhSaturation(53), enhToneShadow(54), enhToneHighlight(55),
  /// enhHighlightRecover(56), enhLook(57).
  /// Returns 56 doubles: indices 0..8 -> slots 0..8, index 9 -> slot 11
  /// (slots 9..10 are the paint size, written by the painter, not here),
  /// indices 10..18 -> slots 12..20 (enhance core, declaration order),
  /// indices 19..31 -> slots 21..33 (selective, declaration order),
  /// indices 32..36 -> slots 34..38 (blur, declaration order),
  /// indices 37..46 -> slots 39..48 (rays, declaration order),
  /// indices 47..55 -> slots 49..57 (derived auto-grade tail + look).
  /// [filterId] is intentionally absent (it selects a texture, not a float).
  List<double> toUniforms() => <double>[
    exposure,
    contrast,
    saturation,
    temp,
    tint,
    shadows,
    highlights,
    intensity.clamp(0.0, 1.0),
    structureNormalized,
    filterStrengthNormalized,
    enhR,
    enhB,
    enhBlack,
    enhWhite,
    enhDehaze,
    enhHazeR,
    enhHazeG,
    enhHazeB,
    enhanceStrength.clamp(0.0, 1.0),
    selMode.toDouble(),
    selCx,
    selCy,
    selRadius,
    selFeather,
    selAngle,
    selWidth,
    selAspect,
    selInvert.toDouble(),
    selStrength.clamp(0.0, 1.0),
    selExp,
    selCon,
    selSat,
    blurMode.toDouble(),
    blurRadius.clamp(0.0, 0.05),
    blurFeather.clamp(0.0, 1.0),
    blurStrength.clamp(0.0, 1.0),
    blurInvert.toDouble(),
    rayOn.toDouble(),
    rayX,
    rayY,
    rayIntensity.clamp(0.0, 1.0),
    rayLength.clamp(0.0, 1.0),
    rayWarmth.clamp(0.0, 1.0),
    rayDensity.clamp(0.0, 1.0),
    rayMode.toDouble(),
    rayAngle,
    rayWidth.clamp(0.0, 1.0),
    // The derived auto-grade tail. APPENDED at the end on purpose: the
    // Enhance block itself grew, but appending keeps every historical
    // uniform prefix (the legacy 9/10/19/32/37/47-slot vectors) pointing
    // at exactly the same fields it always did, so a legacy vector keeps
    // grading byte-for-byte and the derived stages simply stay neutral.
    enhExposure,
    enhContrast,
    enhShadowLift,
    enhVibrance,
    enhSaturation,
    enhToneShadow,
    enhToneHighlight,
    enhHighlightRecover,
    enhLook,
  ];

  LensParams copyWith({
    double? exposure,
    double? contrast,
    double? saturation,
    double? temp,
    double? tint,
    double? shadows,
    double? highlights,
    double? structure,
    double? intensity,
    int? filterId,
    double? filterStrength,
    double? enhR,
    double? enhB,
    double? enhBlack,
    double? enhWhite,
    double? enhDehaze,
    double? enhHazeR,
    double? enhHazeG,
    double? enhHazeB,
    double? enhanceStrength,
    double? enhExposure,
    double? enhContrast,
    double? enhShadowLift,
    double? enhVibrance,
    double? enhSaturation,
    double? enhToneShadow,
    double? enhToneHighlight,
    double? enhHighlightRecover,
    double? enhLook,
    int? selMode,
    double? selCx,
    double? selCy,
    double? selRadius,
    double? selFeather,
    double? selAngle,
    double? selWidth,
    double? selAspect,
    int? selInvert,
    double? selStrength,
    double? selExp,
    double? selCon,
    double? selSat,
    int? blurMode,
    double? blurRadius,
    double? blurFeather,
    double? blurStrength,
    int? blurInvert,
    int? rayOn,
    double? rayX,
    double? rayY,
    double? rayIntensity,
    double? rayLength,
    double? rayWarmth,
    double? rayDensity,
    int? rayMode,
    int? rayKind,
    int? rayType,
    double? rayAngle,
    double? rayDirection,
    double? rayWidth,
    double? raySpread,
  }) {
    return LensParams(
      exposure: exposure ?? this.exposure,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      temp: temp ?? this.temp,
      tint: tint ?? this.tint,
      shadows: shadows ?? this.shadows,
      highlights: highlights ?? this.highlights,
      structure: structure ?? this.structure,
      intensity: intensity ?? this.intensity,
      filterId: filterId ?? this.filterId,
      filterStrength: filterStrength ?? this.filterStrength,
      enhR: enhR ?? this.enhR,
      enhB: enhB ?? this.enhB,
      enhBlack: enhBlack ?? this.enhBlack,
      enhWhite: enhWhite ?? this.enhWhite,
      enhDehaze: enhDehaze ?? this.enhDehaze,
      enhHazeR: enhHazeR ?? this.enhHazeR,
      enhHazeG: enhHazeG ?? this.enhHazeG,
      enhHazeB: enhHazeB ?? this.enhHazeB,
      enhanceStrength: enhanceStrength ?? this.enhanceStrength,
      enhExposure: enhExposure ?? this.enhExposure,
      enhContrast: enhContrast ?? this.enhContrast,
      enhShadowLift: enhShadowLift ?? this.enhShadowLift,
      enhVibrance: enhVibrance ?? this.enhVibrance,
      enhSaturation: enhSaturation ?? this.enhSaturation,
      enhToneShadow: enhToneShadow ?? this.enhToneShadow,
      enhToneHighlight: enhToneHighlight ?? this.enhToneHighlight,
      enhHighlightRecover: enhHighlightRecover ?? this.enhHighlightRecover,
      enhLook: enhLook ?? this.enhLook,
      selMode: selMode ?? this.selMode,
      selCx: selCx ?? this.selCx,
      selCy: selCy ?? this.selCy,
      selRadius: selRadius ?? this.selRadius,
      selFeather: selFeather ?? this.selFeather,
      selAngle: selAngle ?? this.selAngle,
      selWidth: selWidth ?? this.selWidth,
      selAspect: selAspect ?? this.selAspect,
      selInvert: selInvert ?? this.selInvert,
      selStrength: selStrength ?? this.selStrength,
      selExp: selExp ?? this.selExp,
      selCon: selCon ?? this.selCon,
      selSat: selSat ?? this.selSat,
      blurMode: blurMode ?? this.blurMode,
      blurRadius: blurRadius ?? this.blurRadius,
      blurFeather: blurFeather ?? this.blurFeather,
      blurStrength: blurStrength ?? this.blurStrength,
      blurInvert: blurInvert ?? this.blurInvert,
      rayOn: rayOn ?? this.rayOn,
      rayX: rayX ?? this.rayX,
      rayY: rayY ?? this.rayY,
      rayIntensity: rayIntensity ?? this.rayIntensity,
      rayLength: rayLength ?? this.rayLength,
      rayWarmth: rayWarmth ?? this.rayWarmth,
      rayDensity: rayDensity ?? this.rayDensity,
      rayMode: rayMode ?? rayKind ?? rayType ?? this.rayMode,
      rayAngle: rayAngle ?? rayDirection ?? this.rayAngle,
      rayWidth: rayWidth ?? raySpread ?? this.rayWidth,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is LensParams &&
          exposure == other.exposure &&
          contrast == other.contrast &&
          saturation == other.saturation &&
          temp == other.temp &&
          tint == other.tint &&
          shadows == other.shadows &&
          highlights == other.highlights &&
          structure == other.structure &&
          intensity == other.intensity &&
          filterId == other.filterId &&
          filterStrength == other.filterStrength &&
          enhR == other.enhR &&
          enhB == other.enhB &&
          enhBlack == other.enhBlack &&
          enhWhite == other.enhWhite &&
          enhDehaze == other.enhDehaze &&
          enhHazeR == other.enhHazeR &&
          enhHazeG == other.enhHazeG &&
          enhHazeB == other.enhHazeB &&
          enhanceStrength == other.enhanceStrength &&
          enhExposure == other.enhExposure &&
          enhContrast == other.enhContrast &&
          enhShadowLift == other.enhShadowLift &&
          enhVibrance == other.enhVibrance &&
          enhSaturation == other.enhSaturation &&
          enhToneShadow == other.enhToneShadow &&
          enhToneHighlight == other.enhToneHighlight &&
          enhHighlightRecover == other.enhHighlightRecover &&
          enhLook == other.enhLook &&
          selMode == other.selMode &&
          selCx == other.selCx &&
          selCy == other.selCy &&
          selRadius == other.selRadius &&
          selFeather == other.selFeather &&
          selAngle == other.selAngle &&
          selWidth == other.selWidth &&
          selAspect == other.selAspect &&
          selInvert == other.selInvert &&
          selStrength == other.selStrength &&
          selExp == other.selExp &&
          selCon == other.selCon &&
          selSat == other.selSat &&
          blurMode == other.blurMode &&
          blurRadius == other.blurRadius &&
          blurFeather == other.blurFeather &&
          blurStrength == other.blurStrength &&
          blurInvert == other.blurInvert &&
          rayOn == other.rayOn &&
          rayX == other.rayX &&
          rayY == other.rayY &&
          rayIntensity == other.rayIntensity &&
          rayLength == other.rayLength &&
          rayWarmth == other.rayWarmth &&
          rayDensity == other.rayDensity &&
          rayMode == other.rayMode &&
          rayAngle == other.rayAngle &&
          rayWidth == other.rayWidth;

  @override
  int get hashCode => Object.hashAll(<Object>[
    exposure,
    contrast,
    saturation,
    temp,
    tint,
    shadows,
    highlights,
    structure,
    intensity,
    filterId,
    filterStrength,
    enhR,
    enhB,
    enhBlack,
    enhWhite,
    enhDehaze,
    enhHazeR,
    enhHazeG,
    enhHazeB,
    enhanceStrength,
    enhExposure,
    enhContrast,
    enhShadowLift,
    enhVibrance,
    enhSaturation,
    enhToneShadow,
    enhToneHighlight,
    enhHighlightRecover,
    enhLook,
    selMode,
    selCx,
    selCy,
    selRadius,
    selFeather,
    selAngle,
    selWidth,
    selAspect,
    selInvert,
    selStrength,
    selExp,
    selCon,
    selSat,
    blurMode,
    blurRadius,
    blurFeather,
    blurStrength,
    blurInvert,
    rayOn,
    rayX,
    rayY,
    rayIntensity,
    rayLength,
    rayWarmth,
    rayDensity,
    rayMode,
    rayAngle,
    rayWidth,
  ]);
}

/// CPU-side pipeline stub. The real pixel work lives in the fragment
/// shader; this class owns param plumbing plus a CPU fallback path.
class LensPipeline {
  const LensPipeline._();

  /// CPU fallback used when the shader program is unavailable.
  /// Stage 0: pass-through (identity). Stage 1 will apply the grade on CPU.
  static Uint8List applyIdentity(Uint8List bytes) => bytes;
}
