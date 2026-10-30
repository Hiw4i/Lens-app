#include <flutter/runtime_effect.glsl>

// Lens Adjust v1 + procedural LUT grade (Stage 2, Task 2.3).
//
// Preview grade; the exact pixel pipeline lands on CPU in Task 2.5
// (export) and UI in 2.4. Every uniform is referenced in main() so the
// slot layout survives dead-code elimination:
//
//   sampler slots: uImage   -> setImageSampler(0, photo)
//                  uLut     -> setImageSampler(1, 512x512 LUT atlas)
//                  uSelMask -> setImageSampler(2, brush mask 128 / 1x1 stub)
//                  uBlurMask-> setImageSampler(3, subject mask 256 / 1x1 stub)
//                  uStructureMaps -> setImageSampler(4, packed structure maps)
//   float slots:   uExposure         -> setFloat(0, ...)
//                  uContrast         -> setFloat(1, ...)
//                  uSaturation       -> setFloat(2, ...)
//                  uTemp             -> setFloat(3, ...)
//                  uTint             -> setFloat(4, ...)
//                  uShadows          -> setFloat(5, ...)
//                  uHighlights       -> setFloat(6, ...)
//                  uIntensity (0..1) -> setFloat(7, ...)
//                  uStructure (-1..1, signed) -> setFloat(8, ...)
//                  uResolution       -> setFloat(9, width), setFloat(10, height)
//                  uFilterStrength   -> setFloat(11, ...)  (AFTER the vec2)
//                  uEnhR (WB R gain) -> setFloat(12, ...)
//                  uEnhB (WB B gain) -> setFloat(13, ...)
//                  uEnhBlack (levels)-> setFloat(14, ...)
//                  uEnhWhite (levels)-> setFloat(15, ...)
//                  uEnhDehaze        -> setFloat(16, ...)
//                  uEnhHazeR         -> setFloat(17, ...)
//                  uEnhHazeG         -> setFloat(18, ...)
//                  uEnhHazeB         -> setFloat(19, ...)
//                  uEnhStrength(0..1)-> setFloat(20, ...)
//   Selective (Task 4.2, applied AFTER the LUT, BEFORE intensity):
//                  uSelMode (0=off,1=radial,2=linear,3=brush)
//                                      -> setFloat(21, ...)
//                  uSelCx            -> setFloat(22, ...)
//                  uSelCy            -> setFloat(23, ...)
//                  uSelRadius        -> setFloat(24, ...)
//                  uSelFeather       -> setFloat(25, ...)
//                  uSelAngleDeg      -> setFloat(26, ...)
//                  uSelWidth         -> setFloat(27, ...)
//                  uSelAspect        -> setFloat(28, ...)
//                  uSelInvert (0/1)  -> setFloat(29, ...)
//                  uSelStrength(0..1)-> setFloat(30, ...)
//                  uSelExp           -> setFloat(31, ...)
//                  uSelCon           -> setFloat(32, ...)
//                  uSelSat           -> setFloat(33, ...)
//   Blur (Task 6.2, applied FIRST, before enhance):
//                  uBlurMode (0=off,1=auto,2=manual)
//                                      -> setFloat(34, ...)
//                  uBlurRadius (0..0.05)-> setFloat(35, ...)
//                  uBlurFeather (0..1) -> setFloat(36, ...)
//                  uBlurStrength (0..1)-> setFloat(37, ...)
//                  uBlurInvert (0/1)   -> setFloat(38, ...)
//   Rays (Task 7.2, Tyndall stage, AFTER selective, BEFORE intensity):
//                  uRayOn (0/1)        -> setFloat(39, ...)
//                  uRayX (source uv x) -> setFloat(40, ...)
//                  uRayY (source uv y) -> setFloat(41, ...)
//                  uRayIntensity (0..1)-> setFloat(42, ...)
//                  uRayLength (diag *) -> setFloat(43, ...)
//                  uRayWarmth (0..1)   -> setFloat(44, ...)
//                  uRayDensity (0..1)  -> setFloat(45, ...)
//                  uRayMode (0/1)      -> setFloat(46, ...)
//                  uRayAngle (deg)     -> setFloat(47, ...)
//                  uRayWidth (0..1)    -> setFloat(48, ...)
//   Derived auto-grade tail of the Enhance stage (declared LAST):
//                  uEnhExposure      -> setFloat(49, ...)
//                  uEnhContrast      -> setFloat(50, ...)
//                  uEnhShadowLift    -> setFloat(51, ...)
//                  uEnhVibrance      -> setFloat(52, ...)
//                  uEnhSaturation    -> setFloat(53, ...)
//                  uEnhToneShadow    -> setFloat(54, ...)
//                  uEnhToneHighlight -> setFloat(55, ...)
//                  uEnhHighlightRec  -> setFloat(56, ...)
//                  uEnhLook          -> setFloat(57, ...)
//   LensParams.toUniforms returns 56 doubles: indices 0..8 map to
//   slots 0..8, index 9 to slot 11, indices 10..18 to slots 12..20
//   (enhance core), indices 19..31 to slots 21..33 (selective, decl
//   order), indices 32..36 to slots 34..38 (blur, decl order),
//   indices 37..46 to slots 39..48 (rays, decl order),
//   indices 47..55 to slots 49..57 (derived auto-grade tail + look).
//
// NOTE on slot 11: float indices follow declaration order and a vec2
// consumes two slots, so uFilterStrength declared after uResolution
// lands on 11. LensParams.toUniforms returns 56 doubles: indices 0..8
// map to slots 0..8, index 9 maps to slot 11 (resolution fills 9..10),
// indices 10..18 map to slots 12..20 (enhance core, declaration order),
// indices 19..31 map to slots 21..33 (selective, declaration order),
// indices 32..36 map to slots 34..38 (blur, declaration order),
// indices 37..46 map to slots 39..48 (rays, declaration order),
// indices 47..55 map to slots 49..57 (derived auto-grade tail + look).
//
// Stage order in main() (Task 7.2): blur -> enhance -> exposure ->
// contrast -> saturation -> temp/tint -> shadows/highlights ->
// structure (local contrast from the low-res guided-filter maps on
// sampler 4 — NOT a sharpen) -> LUT -> selective -> rays -> intensity.
// Blur runs FIRST so the raw
// background is blurred and every later stage grades the composite,
// exactly the portrait-mode order of the giants. Enhance still runs
// before the color grade (neutral-anchored color, like the CPU path in
// lens_cpu.dart applying applyEnhancePixel on the raw source). Rays run
// AFTER selective and BEFORE the intensity mix: shafts screen-blend over
// the finished grade, but the master mix still fades them with the rest,
// so showOriginal (mix 0) stays perfectly clean.
//
// LUT atlas layout (see LutManager): 512x512 RGBA, effective N=64
// (64^3 texels), 8x8 tiles of 64x64; tile t = ty*8+tx is one B slice.
// `none` binds an identity atlas, so there is a single code path:
// always sample, then mix by uFilterStrength.
//
// Sampler slots follow declaration order: 0 uImage (photo), 1 uLut (LUT
// atlas), 2 uSelMask (brush mask), 3 uBlurMask (subject mask), 4
// uStructureMaps. Slot 4 holds the structure base maps packed by
// `packStructureMaps` (structure_filter.dart): R = a (8 bit), G:B = b as
// a 16-bit big-endian pair, A = 255. Until the real maps arrive a cached
// 1x1 neutral stub (a = 1, b = 0) is bound, which makes q = raw luma and
// the stage an exact no-op. The maps are sampled linearly, so the shader's
// UV fetch is the same bilinear texel-centre interpolation as the Dart
// `structureBaseAt`.

uniform sampler2D uImage;
uniform sampler2D uLut;
uniform sampler2D uSelMask;
uniform sampler2D uBlurMask;
uniform sampler2D uStructureMaps;   // slot 4: R = a, G:B = b (16 bit big-endian)
uniform float uExposure;
uniform float uContrast;
uniform float uSaturation;
uniform float uTemp;
uniform float uTint;
uniform float uShadows;
uniform float uHighlights;
uniform float uIntensity;
uniform float uStructure;
uniform vec2 uResolution;
uniform float uFilterStrength;
// Enhance (professional 1-tap auto-grade): WB gains (G-anchored), the
// auto-levels window, the dehaze amount + veil color and the master
// strength. Slots 12..20. The derived auto-grade tail (auto-exposure,
// contrast, shadow lift, vibrance, saturation, split tone, highlight
// shoulder) is declared at the END of this file — slots 49..56 — so the
// historical slot layout of every other block stays untouched.
uniform float uEnhR;
uniform float uEnhB;
uniform float uEnhBlack;
uniform float uEnhWhite;
uniform float uEnhDehaze;
uniform float uEnhHazeR;
uniform float uEnhHazeG;
uniform float uEnhHazeB;
uniform float uEnhStrength;
// Selective (Task 4.2). Slots 29..41, declaration order == slot order.
// uSelMode: 0 = off, 1 = radial, 2 = linear, 3 = brush (uSelMask .r).
// Geometry mirrors selective_mask.dart 1:1 (uv 0..1, top-left origin):
// radial ellipse `dx=(x-cx)*aspect`, linear bilateral band, invert last.
// uSelMask is ALWAYS bound (real 128 brush mask, else a cached 1x1 stub)
// and sampled unconditionally so the sampler slot survives elimination;
// analytic modes simply ignore the texel. Grade inside the mask is
// exposure/contrast/saturation only (structure-lite skipped — documented
// 4.x limit); mixed by maskW * uSelStrength.
uniform float uSelMode;
uniform float uSelCx;
uniform float uSelCy;
uniform float uSelRadius;
uniform float uSelFeather;
uniform float uSelAngleDeg;
uniform float uSelWidth;
uniform float uSelAspect;
uniform float uSelInvert;
uniform float uSelStrength;
uniform float uSelExp;
uniform float uSelCon;
uniform float uSelSat;
// Blur (Task 6.2). Slots 42..46, declaration order == slot order.
// uBlurMode: 0 = off, 1 = auto (ML 256 mask via BlurCache), 2 = manual
// (hand-painted raster) — the real mask texture arrives in 6.4; until
// then a cached 1x1 white stub is bound (all-subject = neutral no-op).
// uBlurRadius is a fraction of min(w,h): 0..0.05, default 0.02 — the
// shader knows only uResolution, so the tap offsets below scale by
// min(w,h)/w,h to keep the disc circular on any aspect.
// uBlurFeather 0..1 softens the mask edge (0 = hard-step branch —
// smoothstep with e0==e1 is undefined in GLSL, same guard as selective).
// uBlurStrength 0..1 mixes blurred<->sharp (see the composite formula).
// uBlurInvert 0/1 blurs the subject instead of the background (creative).
uniform float uBlurMode;
uniform float uBlurRadius;
uniform float uBlurFeather;
uniform float uBlurStrength;
uniform float uBlurInvert;
// Rays (Task 7.2, Tyndall stage). Slots 47..56, declaration order ==
// slot order. uRayOn 0/1 gates the whole stage; uRayX/uRayY carry the
// source in normalized uv (same top-left convention as selective);
// uRayIntensity 0..1 is the shaft strength (0 skips before any tap);
// uRayLength 0..1 is the march length as a share of the frame diagonal
// (<= 0 degrades to a tap-free point glow around the source);
// uRayWarmth 0..1 tints neutral-white -> golden; uRayDensity 0..1 drives
// the streak frequency/sharpness. Every uniform is read in main() so
// the slots survive dead-code elimination.
uniform float uRayOn;
uniform float uRayX;
uniform float uRayY;
uniform float uRayIntensity;
uniform float uRayLength;
uniform float uRayWarmth;
uniform float uRayDensity;
uniform float uRayMode;
uniform float uRayAngle;
uniform float uRayWidth;
// Derived auto-grade tail of the Enhance stage. Slots 49..56 (declared
// last on purpose: every other block keeps its historical slot, so a
// legacy uniform vector still lands on the same uniforms). These carry
// the values `analyzeEnhance` derived from the photo: the auto-exposure
// gain, the Hermite S-curve contrast, the shadow lift, the vibrance, the
// flat saturation, the split tone (shadows + highlights) and the
// highlight shoulder.
uniform float uEnhExposure;
uniform float uEnhContrast;
uniform float uEnhShadowLift;
uniform float uEnhVibrance;
uniform float uEnhSaturation;
uniform float uEnhToneShadow;
uniform float uEnhToneHighlight;
uniform float uEnhHighlightRec;
// The built-in look (a whisper of the Cinematic filter), mixed in at the
// end of the enhance chain. Slot 57 (appended LAST, like the tail above,
// so every historical slot keeps its meaning).
uniform float uEnhLook;

out vec4 fragColor;

// Effective LUT lattice packed in the atlas. HARDCODED 64 (not a uniform):
// fewer slots = fewer ways for Dart/GLSL to desync. Must match
// LutManager.atlasLutSize (64) and atlasTilesPerSide (8).
const float kLutSize = 64.0;
const float kLutTiles = 8.0;

// Samples the 8x8-tiled LUT atlas at `color` (clamped to 0..1).
// B selects the tile; the two bracketing B slices are sampled with a
// half-texel inset (scale = (N-1)/N, offset = 0.5/atlasSize in tile
// units) so bilinear filtering never bleeds across tile borders, then
// mixed by the fractional B position. Standard quad-tiled LUT lookup.
vec3 applyLut(vec3 color) {
  vec3 c = clamp(color, 0.0, 1.0);
  float slice = c.b * (kLutSize - 1.0);
  float slice0 = floor(slice);
  float slice1 = min(slice0 + 1.0, kLutSize - 1.0);
  float f = slice - slice0;
  vec2 tile0 = vec2(mod(slice0, kLutTiles), floor(slice0 / kLutTiles));
  vec2 tile1 = vec2(mod(slice1, kLutTiles), floor(slice1 / kLutTiles));
  float tileUv = 1.0 / kLutTiles;
  float texelUv = tileUv / kLutSize;
  vec2 rg = c.rg * (kLutSize - 1.0) / kLutSize;
  vec2 uv0 = tile0 * tileUv + vec2(texelUv * 0.5) + rg * tileUv;
  vec2 uv1 = tile1 * tileUv + vec2(texelUv * 0.5) + rg * tileUv;
  vec3 c0 = texture(uLut, uv0).rgb;
  vec3 c1 = texture(uLut, uv1).rgb;
  return mix(c0, c1, f);
}

// The procedural Cinematic look, mirrored 1:1 from `LutTables._cinematic`
// in `lut_definition.dart` (teal shadows, orange highlights, saturation
// 1.1, contrast 1.08). The Enhance stage mixes a whisper of it at the end
// of its chain, so the auto-grade has a point of view without reading as
// "a filter was applied". Duplicated here because the shader cannot call
// Dart; the Dart/GLSL constants must stay in sync.
vec3 cinematicLook(vec3 c) {
  float l = dot(c, vec3(0.299, 0.587, 0.114));
  float sh = 1.0 - smoothstep(0.0, 0.5, l);
  c.r -= 0.04 * sh;
  c.b += 0.08 * sh;
  float hi = smoothstep(0.5, 1.0, l);
  c.r += 0.06 * hi;
  c.g += 0.02 * hi;
  float sl = dot(c, vec3(0.299, 0.587, 0.114));
  c = mix(vec3(sl), c, 1.1);
  c = (c - vec3(0.5)) * 1.08 + vec3(0.5);
  return clamp(c, 0.0, 1.0);
}

// Tyndall helpers (Task 7.2): verbatim port of rays_math.dart —
// rayHash/rayNoise/rayFbm/rayStreak/rayDecay mirror raysHash/raysNoise/
// raysFbm/raysStreak/raysDecay 1:1 (constants 43758.5453, octave weights
// 0.5/0.25 normalized by 1.75, freq 6+22d, sharp 2+4d, tint endpoints
// (1.0,0.98,0.95)->(1.0,0.75,0.45)). highp throughout: the sin-hash
// needs float32 CPU/GPU parity (see the precision caveat in
// rays_math.dart) and mediump (float16 on many mobiles) would quantize
// the hash lattice and band the shafts. `time` is 0 by design (Lens
// motion never self-animates), so the fbm shift is folded out.
highp float rayHash(highp float n) {
  return fract(sin(n) * 43758.5453);
}
highp float rayNoise(highp float x) {
  highp float i = floor(x);
  highp float f = x - i;
  highp float u = f * f * (3.0 - 2.0 * f);
  return mix(rayHash(i), rayHash(i + 1.0), u);
}
highp float rayFbm(highp float x) {
  return (rayNoise(x) + 0.5 * rayNoise(2.0 * x) +
          0.25 * rayNoise(4.0 * x)) /
      1.75;
}
highp float rayStreak(highp float angle, highp float density) {
  highp float d = clamp(density, 0.0, 1.0);
  highp float freq = 6.0 + d * 22.0;
  highp float sharp = 2.0 + d * 4.0;
  highp float base = 0.5 + 0.5 * rayFbm(angle * freq);
  return pow(clamp(base, 0.0, 1.0), sharp);
}
highp float rayDecay(highp float t) {
  highp float c = clamp(t, 0.0, 1.0);
  highp float k = 1.0 - c;
  return k * k;
}
highp float raySector(highp float angle, highp float centerDeg, highp float width) {
  if (width >= 0.999) return 1.0;
  highp float center = centerDeg * 3.14159265 / 180.0;
  highp float diff = abs(angle - center);
  if (diff > 3.14159265) diff = 2.0 * 3.14159265 - diff;
  highp float halfW = clamp(width, 0.0, 1.0) * 3.14159265;
  if (halfW < 0.05) halfW = 0.05;
  if (diff >= halfW) return 0.0;
  highp float edge = clamp(halfW * 0.15, 1e-6, halfW);
  if (diff > halfW - edge) {
    return 1.0 - (diff - (halfW - edge)) / edge;
  }
  return 1.0;
}

void main() {
  vec2 safeRes = max(uResolution, vec2(1.0, 1.0));
  vec2 uv = FlutterFragCoord().xy / safeRes;
  vec3 raw = texture(uImage, uv).rgb;

  // Blur FIRST (Task 6.2): the raw background is blurred, then the whole
  // grade (enhance..selective..intensity) lands on the composite.
  // Mask convention: .r 1 = subject (stays sharp), 0 = background.
  // Kernel: dual-scale 9-tap gather (center x4 + cross x2 + diagonal x1,
  // normalized by 16) at radius R and R*2.7 mixed 0.65/0.35 — a wide-
  // bokeh approximation in 18 taps (two true passes are impossible in one
  // fragment). Radius is a fraction of min(w,h); radius <= 0 skips the
  // taps (base stays raw). Mode 0 skips before any mask read, so the
  // default params cost zero taps.
  // Mask: m = smoothstep(0.5-f*0.5, 0.5+f*0.5, texel) with f = feather;
  // feather <= 0 is a hard-step branch (e0==e1 undefined, same guard as
  // the selective stage). Invert flips subject/background for creative
  // use. Composite: t = clamp(m + (1-s), 0, 1), base = mix(blur, raw, t):
  // at s = 1 classic mix(blur, raw, m); at s = 0 t = 1 everywhere, i.e.
  // raw 1:1.
  vec3 base = raw;
  if (uBlurMode > 0.5) {
    float blurR = clamp(uBlurRadius, 0.0, 0.05);
    float blurS = clamp(uBlurStrength, 0.0, 1.0);
    if (blurR > 0.0 && blurS > 0.0) {
       float minRes = min(safeRes.x, safeRes.y);
      // True 2-D Gaussian gather: a 7x7 tap grid scaled to the blur radius,
      // weighted by a 2-D Gaussian (sigma ~= 1.2 tap). Far smoother and more
      // isotropic than the previous dual-scale 18-tap gather (which left
      // spider/box artifacts at large radii). 49 taps, all reads of uImage.
      vec2 step = blurR * vec2(minRes / safeRes.x, minRes / safeRes.y) / 3.0;
      const float sigma = 1.2;
      const float invTwoSigma2 = 1.0 / (2.0 * sigma * sigma);
      vec3 bokehAcc = vec3(0.0);
      float bokehW = 0.0;
      for (int yy = -3; yy <= 3; yy++) {
        for (int xx = -3; xx <= 3; xx++) {
          float d2 = float(xx * xx + yy * yy);
          float w = exp(-d2 * invTwoSigma2);
          vec2 off = vec2(float(xx), float(yy)) * step;
          bokehAcc += texture(uImage, uv + off).rgb * w;
          bokehW += w;
        }
      }
      vec3 bokeh = bokehAcc / max(bokehW, 1e-6);
      float m = texture(uBlurMask, uv).r;
      if (uBlurFeather <= 0.0) {
        m = m >= 0.5 ? 1.0 : 0.0;
      } else {
        float f = clamp(uBlurFeather, 0.0, 1.0);
        m = smoothstep(0.5 - f * 0.5, 0.5 + f * 0.5, m);
      }
      if (uBlurInvert > 0.5) {
        m = 1.0 - m;
      }
      float t = clamp(m + (1.0 - blurS), 0.0, 1.0);
      base = mix(bokeh, raw, t);
    }
  }

  // Enhance FIRST (professional 1-tap auto-grade). Mirrors
  // applyEnhancePixel in enhance_apply.dart 1:1:
  //   1. WB, G-anchored: r *= mix(1, uEnhR, s), b *= mix(1, uEnhB, s).
  //   2. Skin gate measured on the post-WB pixel, shared by the tone
  //      curve + dehaze: protect = 1 - 0.6 * skinMask.
  //   3. Auto-exposure gain: c *= mix(1, uEnhExposure, s).
  //   4. Dehaze push away from the veil color, same gating (BEFORE the
  //      tone curve: the veil removal can overshoot 1 and the shoulder is
  //      the stage that maps it back).
  //   5. Tone curve: levels stretch -> highlight shoulder (a rational,
  //      C1-at-the-knee roll-off asymptotic to 1, so a blown highlight is
  //      compressed instead of clipped) -> Hermite S-curve.
  //   6. Shadow lift, 7. vibrance + saturation, 8. split toning.
  // At uEnhStrength == 0 every mix weight is 0, so the stage is an exact
  // no-op without branching; EnhanceAnalysis.none (gains 1, window 0..1,
  // exposure 1, no contrast/lift/vibrance/tone/shoulder) is likewise
  // identity at any strength. The trailing clamp mirrors the Dart clamp so
  // the CPU path sees identical input.
  float enhS = clamp(uEnhStrength, 0.0, 1.0);
  vec3 enhanced = base;
  enhanced.r *= mix(1.0, uEnhR, enhS);
  enhanced.b *= mix(1.0, uEnhB, enhS);
  float skinR = smoothstep(0.35, 0.5, enhanced.r);
  float skinG = smoothstep(0.20, 0.35, enhanced.g);
  // smoothstep with edge0 == edge1 is undefined in GLSL (Dart returns
  // 0.0 there), so degenerate dark-red rows are guarded explicitly.
  float hb0 = 0.6 * enhanced.r;
  float hb1 = 0.8 * enhanced.r;
  float skinB = 1.0 - (hb1 > hb0 ? smoothstep(hb0, hb1, enhanced.b) : 0.0);
  float skinD = smoothstep(0.0, 0.08, enhanced.r - enhanced.g);
  float skinMask = skinR * skinG * skinB * skinD;
  float protect = 1.0 - 0.6 * skinMask;

  // Auto-exposure gain (mixed by the master strength).
  float enhExposure = mix(1.0, uEnhExposure, enhS);
  enhanced *= vec3(enhExposure);

  // Dehaze: push away from the veil color. It runs BEFORE the tone curve
  // on purpose: the veil removal can push a channel past 1, and the tone
  // curve's shoulder is the stage that maps that back into the display
  // range (the other way round would undo the highlight recovery).
  float kHz = enhS * protect;
  if (kHz > 0.0 && uEnhDehaze > 0.0) {
    vec3 haze = vec3(uEnhHazeR, uEnhHazeG, uEnhHazeB);
    enhanced = mix(enhanced, enhanced + (enhanced - haze) * uEnhDehaze, kHz);
    // Keep the colour a valid display value for the stages below.
    enhanced = clamp(enhanced, 0.0, 1.5);
  }

  // Tone curve: levels stretch -> highlight shoulder -> S-curve.
  float span = uEnhWhite - uEnhBlack;
  float invSpan = span <= 1e-6 ? 1.0 : 1.0 / span;
  float kEnh = enhS * protect;
  if (kEnh > 0.0) {
    vec3 tone = (enhanced - vec3(uEnhBlack)) * vec3(invSpan);
    // The S-curve shapes the IN-RANGE part only; the excess above 1
    // rides along untouched so the shoulder can still compress it.
    vec3 excess = max(tone - vec3(1.0), vec3(0.0));
    vec3 shaped = clamp(tone, 0.0, 1.0);
    // Hermite S-curve (identity at 0 contrast).
    float enhContrast = clamp(uEnhContrast, 0.0, 1.0);
    if (enhContrast > 0.0) {
      vec3 hermite = shaped * shaped * (vec3(3.0) - 2.0 * shaped);
      shaped = mix(shaped, hermite, enhContrast);
    }
    tone = shaped + excess;
    // Highlight shoulder: a rational (Reinhard-style) roll-off, C1 at the
    // knee and asymptotic to 1. It approaches 1 much more slowly than an
    // exponential, so an over-range (blown) highlight ends up clearly
    // BELOW pure white instead of being squeezed back onto it.
    float knee = 1.0 - 0.12 * clamp(uEnhHighlightRec, 0.0, 1.0);
    float width = 1.0 - knee;
    if (width > 1e-6) {
      vec3 t = max(tone - vec3(knee), vec3(0.0));
      vec3 rolled = vec3(knee) + vec3(width) * t / (t + vec3(width));
      tone = mix(tone, rolled, step(vec3(knee), tone));
    }
    tone = clamp(tone, 0.0, 1.0);
    enhanced = mix(enhanced, tone, kEnh);
  }

  // Shadow lift: a small additive lift of the deep shadows (the filmic
  // "lifted blacks"). Mixed by the master strength.
  if (uEnhShadowLift > 0.0) {
    float liftLuma = dot(enhanced, vec3(0.299, 0.587, 0.114));
    float liftMask = 1.0 - smoothstep(0.0, 0.45, liftLuma);
    enhanced += vec3(uEnhShadowLift * liftMask * 0.10 * enhS);
  }

  // Vibrance (under-saturated colours first) + a flat saturation lift.
  if (uEnhVibrance != 0.0 || uEnhSaturation != 0.0) {
    float vibLuma = dot(enhanced, vec3(0.299, 0.587, 0.114));
    float vibMax = max(max(enhanced.r, enhanced.g), enhanced.b);
    float vibMin = min(min(enhanced.r, enhanced.g), enhanced.b);
    float vibSat = (vibMax - vibMin) / max(vibMax, 1e-3);
    float vibFactor =
        1.0 + uEnhVibrance * (1.0 - vibSat) * (1.0 - 0.7 * skinMask);
    vec3 vib = mix(vec3(vibLuma), enhanced, vibFactor);
    float satFactor = 1.0 + uEnhSaturation * (1.0 - 0.5 * skinMask);
    vec3 sat = mix(vec3(vibLuma), vib, satFactor);
    enhanced = mix(enhanced, sat, enhS);
  }

  // Split toning: cool shadows / warm highlights (the cinematic tone).
  // Both tints are faded by the headroom they have, so the look can
  // never push a channel out of range (which would undo the highlight
  // recovery).
  if (uEnhToneShadow != 0.0 || uEnhToneHighlight != 0.0) {
    float toneLuma = dot(enhanced, vec3(0.299, 0.587, 0.114));
    float toneShadowMask = 1.0 - smoothstep(0.05, 0.5, toneLuma);
    float toneHighlightMask = smoothstep(0.5, 0.95, toneLuma);
    float ts = uEnhToneShadow * toneShadowMask * (1.0 - 0.6 * skinMask) *
        min(toneLuma * 3.0, 1.0) * enhS;
    float toneHeadroom = 1.0 - max(max(enhanced.r, enhanced.g), enhanced.b);
    float th = uEnhToneHighlight * toneHighlightMask *
        min(1.0, toneHeadroom * 4.0) * enhS;
    enhanced += vec3(ts * -0.030 + th * 0.040, th * 0.012,
                      ts * 0.050 + th * -0.028);
  }

  // Built-in look: a whisper of the Cinematic filter at the very end of
  // the chain. uEnhLook is analysis-owned (0.30 for a real analysis, 0 for
  // EnhanceAnalysis.none), so the neutral analysis stays an exact identity
  // at any strength; the master strength fades the look with the rest.
  // Highlight guard (mirrors enhance_apply.dart): the look's warm
  // highlights fade out as the pixel approaches white, so it can never
  // undo the highlight recovery above.
  if (uEnhLook > 0.0) {
    float lookHeadroom = 1.0 - max(max(enhanced.r, enhanced.g), enhanced.b);
    float kLook = clamp(uEnhLook, 0.0, 1.0) * enhS *
        clamp(lookHeadroom * 8.0, 0.0, 1.0);
    if (kLook > 0.0) {
      enhanced = mix(enhanced, cinematicLook(enhanced), kLook);
    }
  }
  enhanced = clamp(enhanced, 0.0, 1.0);

  // Exposure: gain in stops, identity at 0.
  // Positive: linear EV scale with filmic highlight rolloff (no clip).
  // Negative: gamma curve so midtones darken with depth instead of a
  // flat linear scale - gives the "day -> night" feel.
  vec3 graded;
  if (uExposure >= 0.0) {
    graded = enhanced * pow(2.0, uExposure);
    float expAmt = clamp(uExposure, 0.0, 2.0) / 2.0;
    float hlRoll =
        smoothstep(0.7, 1.0, dot(graded, vec3(0.299, 0.587, 0.114)));
    vec3 compressed = graded / (graded + vec3(0.15)) * 1.15;
    graded = mix(graded, compressed, expAmt * 0.5 * hlRoll);
  } else {
    float gexp = pow(2.0, -uExposure);
    graded = pow(max(enhanced, vec3(0.0)), vec3(gexp));
  }

  // Contrast around middle gray. Identity at 0.
  // Professional S-curve (tanh) instead of a linear scale: boosts
  // midtone contrast without hard-clipping blacks/whites.
  float conK = uContrast;
  if (abs(conK) < 1e-4) {
    // identity
  } else {
    float t = tanh(conK);
    graded = vec3(0.5) + vec3(0.5) * tanh((graded - vec3(0.5)) * (conK * 2.0)) / t;
  }

  // Saturation via vibrance: boosts under-saturated colors more than
  // already-saturated ones (and leaves neutrals clean), so the slider
  // feels like a professional "vibrance" rather than a flat scale.
  // Identity at 0.
  float satLuma = dot(graded, vec3(0.299, 0.587, 0.114));
  float satMax = max(max(graded.r, graded.g), graded.b);
  float satMin = min(min(graded.r, graded.g), graded.b);
  float curSat = (satMax - satMin) / max(satMax, 1e-6);
  // Skin-tone protection: reduce saturation effect on skin pixels to avoid
  // the orange/red skin that flat saturation produces.
  float satSkinR = smoothstep(0.35, 0.5, graded.r);
  float satSkinG = smoothstep(0.20, 0.35, graded.g);
  float satHb0 = 0.6 * graded.r;
  float satHb1 = 0.8 * graded.r;
  float satSkinB = 1.0 - (satHb1 > satHb0 ? smoothstep(satHb0, satHb1, graded.b) : 0.0);
  float satSkinD = smoothstep(0.0, 0.08, graded.r - graded.g);
  float gradeSkinMask = satSkinR * satSkinG * satSkinB * satSkinD;
  float vibAmount = uSaturation * (1.0 - 0.5 * gradeSkinMask);
  float vibFactor = 1.0 + vibAmount * (1.0 - curSat);
  graded = mix(vec3(satLuma), graded, vibFactor);

  // White balance. Identity at 0.
  // Professional temperature/tint: multiplicative channel gains along
  // the warm<->cool (temp) and green<->magenta (tint) axes, with
  // per-pixel luminance preserved so the cast does not uniformly
  // brighten/darken the image (SpeedGrade/Nuke style). Temp +1 warms
  // (R up, B down), tint +1 magentas (R&B up, G down).
  float wbTemp = clamp(uTemp, -1.0, 1.0);
  float wbTint = clamp(uTint, -1.0, 1.0);
  float rGain = (1.0 + 0.6 * wbTemp) * (1.0 + 0.3 * wbTint);
  float gGain = 1.0 - 0.4 * wbTint;
  float bGain = (1.0 - 0.6 * wbTemp) * (1.0 + 0.3 * wbTint);
  float wbLumaBefore = dot(graded, vec3(0.299, 0.587, 0.114));
  vec3 wbGraded = graded * vec3(rGain, gGain, bGain);
  float wbLumaAfter = dot(wbGraded, vec3(0.299, 0.587, 0.114));
  if (wbLumaAfter > 1e-6) {
    wbGraded *= wbLumaBefore / wbLumaAfter;
  }
  graded = wbGraded;

  // Shadows / highlights, luma-masked. Identity at 0.
  // shadows lift:    uShadows * (1 - smoothstep(0.0, 0.5, luma)) * 0.6
  // highlights pull: uHighlights * smoothstep(0.5, 1.0, luma) * 0.6
  // Luma is re-measured after WB so the masks follow the graded image.
  float luma = dot(graded, vec3(0.299, 0.587, 0.114));
  // Professional shadows/highlights: curve-based (lift toward 1 in
  // shadows, scale in highlights) instead of a flat additive shift.
  float shMask = 1.0 - smoothstep(0.0, 0.5, luma);
  float hiMask = smoothstep(0.5, 1.0, luma);
  graded += uShadows * shMask * (1.0 - graded) * 0.6;
  graded += uHighlights * hiMask * graded * 0.6;

  // Structure: real local contrast (base/detail separation), mirrored 1:1
  // from `structure_filter.dart` (see structureMultiplier / structureBaseAt).
  // Base comes from the low-res guided-filter maps on sampler 4 (R = a,
  // G:B = 16-bit big-endian b); sampling is linear, which is exactly the
  // Dart bilinear texel-centre convention with clamped edges.
  //   q    = clamp(a * rawL + b, 0, 1)          // edge-preserving BASE
  //   dEV  = clamp(ln(max(rawL,1e-3) / max(q,1e-3)), -1, 1)
  //   M    = 4 * q * (1 - q)                    // parabolic midtone mask
  //   E    = clamp(amount * GAIN * M * dEV, -0.7, 0.7)
  //   RGB' = RGB_graded * exp(E)                // hue-preserving scale
  // The constants mirror the Dart module: GAIN = kStructureGain (2.5),
  // dEV clamp = kStructureDetailClamp (1.0), exponent clamp =
  // kStructureExponentClamp (0.7). The shader cannot import them, so they
  // are written as literals here and must stay in sync. uStructure is
  // signed (-1..1): negative softens the texture, 0 is an exact no-op.
  // Enhance adds a small clarity boost on top of the user's slider
  // (kEnhanceStructureBoost = 0.12 at full strength), so a one-tap grade
  // reads as "a good lens" instead of "corrected". It is ADDED to the
  // slider, never replaces it, and runs through the same guided-filter
  // stage (local contrast, not a sharpen). The BOOST fades out on
  // near-white pixels (graded luma -> 1): the tone curve just saved those
  // highlights, and a local-contrast tick must not push them back onto a
  // flat white wall. The user's own slider is untouched.
  float structL = dot(graded, vec3(0.299, 0.587, 0.114));
  float sBoost = 0.12 * enhS * (1.0 - smoothstep(0.85, 1.0, structL));
  float sAmt = clamp(uStructure + sBoost, -1.0, 1.0);
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

  // LUT look (Task 2.3): sample the atlas, mix by uFilterStrength.
  // `none` binds the identity atlas so this path is a no-op there.
  // Runs BEFORE selective + master mix so intensity stays the final word.
  vec3 lutColor = applyLut(graded);
  graded = mix(graded, lutColor, clamp(uFilterStrength, 0.0, 1.0));

  // Selective (Task 4.2): LAST grade before the master mix.
  // Mask math mirrors selective_mask.dart 1:1 (eps = 1e-6, Hermite
  // smoothstep is the builtin; e0==e1 never occurs here because the
  // feather<=0 hard step is branched explicitly, matching the Dart
  // `feather <= 0.0` branch). uSelMask is sampled unconditionally so
  // the sampler slot survives; analytic modes (1, 2) ignore the texel.
  // Grade inside the mask = exposure (gain + highlight rolloff, same
  // as the global stage) -> contrast -> saturation; structure inside
  // the mask is SKIPPED (documented 4.x limit, no extra taps).
  // At uSelMode == 0 or uSelStrength == 0 the mix weight is 0, so the
  // stage is an exact no-op without branching the grade away.
  float brushW = texture(uSelMask, uv).r;
  float analyticW = 0.0;
  if (uSelMode > 0.5 && uSelMode < 1.5) {
    // Radial elliptical disc with soft edge.
    float dx = (uv.x - uSelCx) * uSelAspect;
    float dy = uv.y - uSelCy;
    float d = sqrt(dx * dx + dy * dy) / max(uSelRadius, 1e-6);
    if (uSelFeather <= 0.0) {
      analyticW = d <= 1.0 ? 1.0 : 0.0;
    } else {
      float e0 = clamp(1.0 - uSelFeather, 0.0, 1.0);
      analyticW = 1.0 - smoothstep(e0, 1.0, d);
    }
  } else if (uSelMode > 1.5 && uSelMode < 2.5) {
    // Linear bilateral band around the center line.
    float ang = radians(uSelAngleDeg);
    float p = ((uv.x - uSelCx) * cos(ang) + (uv.y - uSelCy) * sin(ang)) /
        max(uSelWidth, 1e-6);
    float ap = abs(p);
    if (uSelFeather <= 0.0) {
      analyticW = ap <= 1.0 ? 1.0 : 0.0;
    } else {
      float e0 = clamp(1.0 - uSelFeather, 0.0, 1.0);
      analyticW = 1.0 - smoothstep(e0, 1.0, ap);
    }
  }
  float maskW = 0.0;
  if (uSelMode > 0.5 && uSelMode < 1.5) {
    maskW = analyticW;
  } else if (uSelMode > 1.5 && uSelMode < 2.5) {
    maskW = analyticW;
  } else if (uSelMode > 2.5) {
    maskW = brushW;
  }
  if (uSelInvert > 0.5) {
    maskW = 1.0 - maskW;
  }
  // Invert is applied even when mode == 0 (maskW 0 -> 1)? NO — off must
  // stay off: with no shape selected there is nothing to invert, so the
  // flip applies only to modes 1..3. Keeps identity neutral when the
  // UI parks invert=1 while the mode is still off.
  if (uSelMode < 0.5) {
    maskW = 0.0;
  }
  float selK = clamp(maskW * clamp(uSelStrength, 0.0, 1.0), 0.0, 1.0);
  if (selK > 0.0) {
    vec3 sel = graded * pow(2.0, uSelExp);
    float selExpAmt = clamp(uSelExp, 0.0, 2.0) / 2.0;
    float selHlRoll =
        smoothstep(0.7, 1.0, dot(sel, vec3(0.299, 0.587, 0.114)));
    vec3 selCompressed = sel / (sel + vec3(0.15)) * 1.15;
    sel = mix(sel, selCompressed, selExpAmt * 0.5 * selHlRoll);
    sel = (sel - 0.5) * (1.0 + uSelCon) + 0.5;
    float selLuma = dot(sel, vec3(0.299, 0.587, 0.114));
    sel = mix(vec3(selLuma), sel, 1.0 + uSelSat);
    graded = mix(graded, sel, selK);
  }

  // Rays (Task 7.2, Tyndall stage): AFTER selective, BEFORE intensity.
  // Shafts gather scene light along a 24-tap march from the pixel TOWARD
  // the source and screen-blend over the graded pixel (see applyRaysPixel
  // in rays_math.dart — screen can only brighten). March length =
  // uRayLength * frame diagonal; step i samples t = i/24 with
  // accum += luma(tap) * decay(t)/24, then k = accum * streak * intensity
  // and ray = tint * k. The tap luma is the raw scene (uImage): shafts
  // gather from bright areas toward the sun. uRayLength <= 0 degrades to
  // a tap-free point glow (decay of the normalized source distance).
  // uRayOn < 0.5 or intensity <= 0 skips before ANY tap, so the default
  // params cost zero texture reads. Perf: 24 taps + ~3 ALU octaves per
  // tap-pixel ONLY while rays are armed (see concerns in the task doc).
  if (uRayOn > 0.5) {
    highp float rayI = clamp(uRayIntensity, 0.0, 1.0);
    if (rayI > 0.0) {
      highp float rayLen = clamp(uRayLength, 0.0, 1.0);
      highp float rayW = clamp(uRayWarmth, 0.0, 1.0);
      highp float rayD = clamp(uRayDensity, 0.0, 1.0);
      highp vec2 srcPx = vec2(uRayX, uRayY) * safeRes;
      highp vec2 fragPx = FlutterFragCoord().xy;
      highp vec2 toSrc = srcPx - fragPx;
      highp float distPx = length(toSrc);
      highp vec2 fromSrc = fragPx - srcPx;
      highp float angle = atan(fromSrc.y, fromSrc.x);
      highp float streakV = rayStreak(angle, rayD) * raySector(angle, uRayAngle, uRayWidth);
      highp vec3 tintV = vec3(
          mix(1.0, 1.0, rayW), mix(0.98, 0.75, rayW), mix(0.95, 0.45, rayW));
      highp float diagPx = length(safeRes);
      highp float kR;
      if (rayLen > 0.0 && diagPx > 1e-6) {
        highp float marchLen = rayLen * diagPx;
        // Epsilon-guarded normalize (no branch, no precision-mixed
        // ternary): a pixel exactly on the source marches in place.
        highp vec2 stepDir = toSrc / max(distPx, 1e-6);
        highp float accum = 0.0;
        for (int i = 0; i < 24; i++) {
          highp float t = float(i) / 24.0;
          highp vec2 tapPx = fragPx + stepDir * (t * marchLen);
          highp float light = 1.0;
          if (uRayMode < 0.5) {
            highp vec3 tap = texture(uImage, tapPx / safeRes).rgb;
            light = tap.r * 0.299 + tap.g * 0.587 + tap.b * 0.114;
          }
          accum += light * rayDecay(t) / 24.0;
        }
        kR = clamp(accum, 0.0, 1.0) * clamp(streakV, 0.0, 1.0) * rayI;
      } else {
        // Point glow: zero-length march, pure math, no taps. The max()
        // guard keeps the divide safe (safeRes >= 1 in practice, so
        // diagPx >> 1e-6; a degenerate zero would decay to 0 anyway).
        highp float d01 = distPx / max(diagPx, 1e-6);
        kR = rayDecay(d01) * clamp(streakV, 0.0, 1.0) * rayI;
      }
      vec3 ray = vec3(tintV * kR);
      graded = clamp(
          vec3(1.0) - (vec3(1.0) - graded) * (vec3(1.0) - ray), 0.0, 1.0);
    }
  }

  // Master mix: 0 shows raw, 1 shows the full grade.
  // Referenced here so the slot is never eliminated.
  float mixAmt = clamp(uIntensity, 0.0, 1.0);
  graded = mix(raw, graded, mixAmt);

  fragColor = vec4(graded, 1.0);
}
