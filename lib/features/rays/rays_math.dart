import 'dart:math' as math;
import 'dart:typed_data';

/// Tyndall rays (god rays) math core (Task 7.1).
///
/// Pure-Dart on purpose: this file imports `dart:math` only (no Flutter,
/// no Riverpod, no `package:image`), so every symbol here is safe to run
/// inside an isolate. It knows nothing about shaders, state, or UI —
/// streak/decay/tint helpers plus one per-pixel screen blend only.
///
/// Pipeline split (composite order is NOT defined here):
/// * this file — noise + streak profile + decay + tint + screen blend;
/// * Task 7.2 (CPU march) / 7.3 (GLSL) — the radial march from
///   [RaysParams.source] that supplies `light`, `streakVal` and
///   `decayVal` per pixel to [applyRaysPixel].
///
/// GLSL 1:1 port contract — every formula below uses ONLY operations
/// that translate bit-for-bit intent into GLSL ES 1.0:
/// * `sin`, `floor` and the `fract`/`mix` equivalents defined here
///   ([raysFract] is `x - floor(x)`; blending is explicit `a+(b-a)*t`,
///   never a Dart-only helper);
/// * NO integer hashing, NO bit ops, NO `pow` with a negative base,
///   NO exceptions — out-of-range inputs are clamped, never thrown on.
/// The matching `.frag` code must copy the constants verbatim
/// (43758.5453, octave weights, tint endpoints).
///
/// Precision caveat (see concerns): Dart is float64, GLSL `mediump` is
/// float32 — the `sin`-hash diverges between CPU and GPU for large
/// inputs, so streak *patterns* will differ slightly while every
/// *statistical* property (range, continuity, monotonic decay) holds on
/// both sides. Never compare CPU/GPU pixels bit-exact; compare ranges.

/// Immutable Tyndall-rays parameters.
///
/// * [source] — sun position in normalized uv 0..1, origin top-left
///   (matches the shader's `uv`). Default (.5, .2): sun near the top.
/// * [intensity] — 0..1, UI 0..100 mapped as `ui / 100`. Default 0 = off
///   (the whole stage is a bit-exact identity, see [applyRaysPixel]).
/// * [length] — 0..1, march length as a share of the frame diagonal.
///   Consumed by the 7.2/7.3 march, not by this file's helpers.
/// * [warmth] — 0..1, 0 = neutral white, 1 = golden ([raysTint]).
/// * [density] — 0..1, streak frequency/sharpness ([raysStreak]).
class RaysParams {
  const RaysParams({
    this.source = (0.5, 0.2),
    this.intensity = 0.0,
    this.length = 0.6,
    this.warmth = 0.7,
    this.density = 0.5,
    int? mode,
    int? kind,
    int? type,
    double? angle,
    double? direction,
    double? width,
    double? spread,
  }) : mode = mode ?? kind ?? type ?? 0,
       angle = angle ?? direction ?? 0.0,
       width = width ?? spread ?? 1.0,
       assert(intensity >= 0.0 && intensity <= 1.0),
       assert(length >= 0.0 && length <= 1.0),
       assert(warmth >= 0.0 && warmth <= 1.0),
       assert(density >= 0.0 && density <= 1.0);

  /// Sun position in normalized uv 0..1.
  final (double, double) source;

  /// Ray strength 0..1 (UI 0..100 → /100). 0 = stage off (identity).
  final double intensity;

  /// March length as a share of the frame diagonal 0..1 (7.2/7.3 march).
  final double length;

  /// Ray color 0..1: 0 = neutral white, 1 = golden.
  final double warmth;

  /// Streak frequency 0..1 (sparse soft ↔ dense sharp).
  final double density;

  /// Ray kind: 0 = bright-source dependent (god rays), 1 = fog-like.
  final int mode;

  /// Direction the rays point, in degrees 0..360.
  final double angle;

  /// Angular spread 0..1: 1 = all sides, 0 = narrow single side.
  final double width;

  /// Stage off: default values with [intensity] 0 (bit-exact identity).
  static const RaysParams off = RaysParams(intensity: 0.0);

  RaysParams copyWith({
    (double, double)? source,
    double? intensity,
    double? length,
    double? warmth,
    double? density,
    int? mode,
    int? kind,
    int? type,
    double? angle,
    double? direction,
    double? width,
    double? spread,
  }) {
    return RaysParams(
      source: source ?? this.source,
      intensity: intensity ?? this.intensity,
      length: length ?? this.length,
      warmth: warmth ?? this.warmth,
      density: density ?? this.density,
      mode: mode ?? kind ?? type ?? this.mode,
      angle: angle ?? direction ?? this.angle,
      width: width ?? spread ?? this.width,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is RaysParams &&
      source == other.source &&
      intensity == other.intensity &&
      length == other.length &&
      warmth == other.warmth &&
      density == other.density &&
      mode == other.mode &&
      angle == other.angle &&
      width == other.width;

  @override
  int get hashCode => Object.hash(
    source,
    intensity,
    length,
    warmth,
    density,
    mode,
    angle,
    width,
  );

  @override
  String toString() =>
      'RaysParams(source: $source, intensity: $intensity, length: $length, '
      'warmth: $warmth, density: $density, mode: $mode, angle: $angle, '
      'width: $width)';
}

double _clamp01(double v) => v.clamp(0.0, 1.0);

/// GLSL `fract`: `x - floor(x)`, always in [0, 1). Top-level so the
/// `.frag` port mirrors it line-for-line (`fract(x)` builtin).
/// Pure (no Flutter).
/// Angular sector mask in [0, 1]: 1 inside the illuminated cone, 0
/// outside. [width] 1 = all sides (no masking); smaller values narrow the
/// cone around [centerDeg] (degrees). Used by the direction/width controls.
double raysSector(double angle, double centerDeg, double width) {
  if (width >= 0.999) return 1.0;
  final double center = centerDeg * math.pi / 180.0;
  double diff = (angle - center).abs();
  if (diff > math.pi) diff = 2.0 * math.pi - diff;
  final double half = (width.clamp(0.0, 1.0) * math.pi).clamp(0.05, math.pi);
  if (diff >= half) return 0.0;
  final double edge = (half * 0.15).clamp(1e-6, half);
  if (diff > half - edge) {
    return 1.0 - (diff - (half - edge)) / edge;
  }
  return 1.0;
}

double raysFract(double x) => x - x.floorToDouble();

/// GLSL-style `mix`: `a + (b - a) * t`. Top-level so the `.frag` port
/// mirrors it (`mix(a, b, t)` builtin). Pure (no Flutter).
double raysMix(double a, double b, double t) => a + (b - a) * t;

/// Deterministic texture-free hash in [0, 1):
/// `fract(sin(n) * 43758.5453)`.
///
/// GLSL limits (must hold in the `.frag` port too):
/// * input must stay modest (|n| ≲ 300 — the lattice values used by
///   [raysNoise] after `floor`); `sin` of huge floats loses precision
///   and the CPU (float64) / GPU (float32) patterns diverge;
/// * the magic constant 43758.5453 must be copied verbatim.
/// Pure (no Flutter).
double raysHash(double n) => raysFract(math.sin(n) * 43758.5453);

/// 1-D value noise in [0, 1]:
/// `i = floor(x)`, `f = fract(x)`, `u = f*f*(3-2f)` (Hermite, same
/// kernel as `selectiveSmoothstep`/`_smoothstep` in the Enhance and
/// Selective cores), `mix(hash(i), hash(i+1), u)`.
///
/// Only `floor`/`fract`/`mix` + [raysHash] — directly GLSL-portable.
/// Pure (no Flutter).
double raysNoise(double x) {
  final double i = x.floorToDouble();
  final double f = x - i;
  final double u = f * f * (3.0 - 2.0 * f);
  return raysMix(raysHash(i), raysHash(i + 1.0), u);
}

/// 3-octave fractal noise in [0, 1]:
/// `(n(x) + 0.5 * n(2x) + 0.25 * n(4x)) / 1.75`
/// (weights sum to 1.75, so the output stays in [0, 1]).
///
/// Fixed lacunarity 2.0 and fixed gains — no extra uniforms, so the
/// `.frag` port is three verbatim [raysNoise] calls. Pure (no Flutter).
double raysFbm(double x) =>
    (raysNoise(x) + 0.5 * raysNoise(2.0 * x) + 0.25 * raysNoise(4.0 * x)) /
    1.75;

/// Angular streak profile in [0, 1]:
/// `pow(0.5 + 0.5 * fbm(angle * freq + time), sharp)` with
/// `freq = 6 + density * 22`, `sharp = 2 + density * 4`
/// ([density] clamped to 0..1; density 0 = sparse soft bands,
/// density 1 = dense sharp shafts).
///
/// `angle` is the polar angle around [RaysParams.source] in radians
/// (supplied by the 7.2/7.3 march).
///
/// `time` is STATIC by design and MUST be 0: Lens motion answers a user
/// action, it never self-animates, so rays do not shimmer on their own.
/// The parameter exists only to keep the Dart/GLSL signatures aligned;
/// a nonzero value shifts the pattern along the noise axis (reserved
/// for scrub-linked use, not animation). Only `sin`-free arithmetic on
/// top of [raysFbm] — GLSL-portable. Pure (no Flutter).
double raysStreak(double angle, double density, [double time = 0.0]) {
  final double d = density.clamp(0.0, 1.0);
  final double freq = 6.0 + d * 22.0;
  final double sharp = 2.0 + d * 4.0;
  final double base = 0.5 + 0.5 * raysFbm(angle * freq + time);
  return math.pow(_clamp01(base), sharp).toDouble();
}

/// March-distance decay in [0, 1]: `(1 - t)^2`, `t` clamped to 0..1
/// (`t` = march distance / ([RaysParams.length] × diagonal), supplied
/// by the 7.2/7.3 march). Quadratic falloff: bright core near the sun,
/// fast fade outward. Pure (no Flutter).
double raysDecay(double t) {
  final double c = t.clamp(0.0, 1.0);
  final double k = 1.0 - c;
  return k * k;
}

/// Ray color: `mix(vec3(1.0, 0.98, 0.95), vec3(1.0, 0.75, 0.45), warmth)`
/// ([warmth] clamped to 0..1). Warmth 0 is near-white daylight,
/// warmth 1 is golden hour. Constants must be copied verbatim into the
/// `.frag` port. Pure (no Flutter).
(double, double, double) raysTint(double warmth) {
  final double w = warmth.clamp(0.0, 1.0);
  return (raysMix(1.0, 1.0, w), raysMix(0.98, 0.75, w), raysMix(0.95, 0.45, w));
}

/// Screen-blends one ray contribution over a 0..1 RGB pixel:
/// `k = light * streakVal * decayVal * intensity` (each clamped to
/// 0..1), `ray = tint * k` per channel,
/// `out = 1 - (1 - c) * (1 - ray)` per channel, clamped to 0..1.
///
/// * `light` — marched-scene term from the 7.2/7.3 march (mean luma
///   along the march, 0 = occluded, 1 = clear sky); `light = 1`
///   reduces `k` to the bare `streak * decay * intensity`.
/// * `intensity <= 0` leaves [out] untouched (bit-exact), so
///   [RaysParams.off] is a free no-op like Enhance at strength 0.
/// Screen can only brighten: `out >= in` per channel. Pure (no Flutter),
/// safe for tight per-pixel loops.
(double, double, double) applyRaysPixel(
  double r,
  double g,
  double b,
  double light,
  double streakVal,
  double decayVal,
  (double, double, double) tint,
  double intensity,
) {
  final Float64List out = Float64List(3);
  applyRaysPixelInto(
    r,
    g,
    b,
    light,
    streakVal,
    decayVal,
    tint,
    intensity,
    out,
  );
  return (out[0], out[1], out[2]);
}

/// Allocation-free variant of [applyRaysPixel] for the export hot loop:
/// writes R,G,B into [out] (length >= 3) with the same arithmetic in the
/// same order. `intensity <= 0` (or a fully-occluded `k`) leaves [out]
/// untouched — callers seed it with their input first (the export loop
/// re-reads the same registers, so the untouched case equals the input).
void applyRaysPixelInto(
  double r,
  double g,
  double b,
  double light,
  double streakVal,
  double decayVal,
  (double, double, double) tint,
  double intensity,
  Float64List out,
) {
  if (intensity <= 0.0) {
    out[0] = r;
    out[1] = g;
    out[2] = b;
    return;
  }
  final double k =
      (_clamp01(light) *
              _clamp01(streakVal) *
              _clamp01(decayVal) *
              _clamp01(intensity))
          .clamp(0.0, 1.0);
  if (k <= 0.0) {
    out[0] = r;
    out[1] = g;
    out[2] = b;
    return;
  }
  final double rr = 1.0 - (1.0 - r) * (1.0 - tint.$1 * k);
  final double gg = 1.0 - (1.0 - g) * (1.0 - tint.$2 * k);
  final double bb = 1.0 - (1.0 - b) * (1.0 - tint.$3 * k);
  out[0] = _clamp01(rr);
  out[1] = _clamp01(gg);
  out[2] = _clamp01(bb);
}
