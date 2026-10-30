import 'dart:math' as math;

/// Selective mask math core (Task 4.1).
///
/// Pure-Dart on purpose: this file imports `dart:*` only (no Flutter, no
/// Riverpod, no `package:image`), so every symbol here is safe to run
/// inside an isolate. It knows nothing about shaders, state, or UI —
/// mask *values* only. Rasterization of brush strokes lives in
/// `mask_raster.dart`; mixing by strength lives on the apply side
/// (Task 4.4+).
///
/// Coordinate convention: normalized `uv` in 0..1 for both axes, origin at
/// the top-left (matches the shader's `uv`). All weights are 0..1.
///
/// Formulas:
/// * radial (elliptical disc with soft edge):
///   `dx = (x - cx) * aspect`, `dy = y - cy`,
///   `d = sqrt(dx*dx + dy*dy) / max(radius, eps)`,
///   `w = 1 - smoothstep(1 - feather, 1, d)`.
///   The `aspect` field (preview `w/h`, default 1) turns the disc into an
///   ellipse that looks circular on a non-square preview: with
///   `aspect = 2` an x-offset is penalized twice as hard as the same
///   y-offset. `aspect` affects radial only; linear works in plain uv.
/// * linear (bilateral band around the center line, NOT a one-sided
///   Snapseed-style gradient — a symmetric band is simpler and
///   predictable; one-sided gradients can be built with `invert` in a
///   later task if needed):
///   `p = ((x - cx) * cosA + (y - cy) * sinA) / max(width, eps)`,
///   `w = 1 - smoothstep(1 - feather, 1, |p|)`,
///   with `A = angle * pi / 180`. `angle` is the band's gradient
///   direction: 90° (default) varies along y (horizontal band), 0°
///   varies along x (vertical band).
/// * brush: this file provides only the 1-D kernel [brushFalloff];
///   stroke rasterization is [rasterizeBrushMask] in `mask_raster.dart`.
/// * invert (applied last, all modes): `w = invert ? 1 - w : w`.
/// * feather 0 is a hard step (`d <= 1 ? 1 : 0`); the smooth formula is
///   used only for `feather > 0` (at exactly 0 the smoothstep window
///   degenerates to a point, so the branch keeps the edge exact).
/// * `strength` is NOT applied here — the caller mixes `w` on the apply
///   side, exactly like Enhance mixes by `s` in `enhance_apply.dart`.

/// Which mask shape [selectiveWeight] evaluates.
///
/// `brush` has no analytic field here (strokes need rasterization, see
/// `mask_raster.dart`); passing it to [selectiveWeight] returns 0.0.
enum SelectiveMode { radial, linear, brush }

/// Immutable geometry shared by the radial/linear selective masks.
///
/// All fields are normalized: [center] components, [radius], [feather]
/// and [width] live in 0..1, [angle] in degrees 0..360, [aspect] is the
/// preview width/height ratio (> 0, 1 = square).
class SelectiveGeometry {
  const SelectiveGeometry({
    this.center = (0.5, 0.5),
    this.radius = 0.35,
    this.feather = 0.5,
    this.angle = 90.0,
    this.width = 0.5,
    this.invert = false,
    this.aspect = 1.0,
  }) : assert(radius >= 0.0 && radius <= 1.0),
       assert(feather >= 0.0 && feather <= 1.0),
       assert(angle >= 0.0 && angle <= 360.0),
       assert(width >= 0.0 && width <= 1.0),
       assert(aspect > 0.0);

  /// Mask center in normalized uv 0..1.
  final (double, double) center;

  /// Radial disc radius in uv units (0..1).
  final double radius;

  /// Edge softness 0..1: 0 = hard step, 1 = falloff starts at the center.
  final double feather;

  /// Linear gradient direction in degrees 0..360 (default 90 = along y).
  final double angle;

  /// Linear half-band width in uv units (0..1): `|p| <= 1` is inside.
  final double width;

  /// When true the final weight is flipped (`1 - w`).
  final bool invert;

  /// Preview width/height ratio; stretches the radial disc into an
  /// ellipse so it looks circular on non-square previews. Default 1.
  final double aspect;

  /// Neutral geometry: default field values (no inversion).
  static const SelectiveGeometry none = SelectiveGeometry();

  SelectiveGeometry copyWith({
    (double, double)? center,
    double? radius,
    double? feather,
    double? angle,
    double? width,
    bool? invert,
    double? aspect,
  }) {
    return SelectiveGeometry(
      center: center ?? this.center,
      radius: radius ?? this.radius,
      feather: feather ?? this.feather,
      angle: angle ?? this.angle,
      width: width ?? this.width,
      invert: invert ?? this.invert,
      aspect: aspect ?? this.aspect,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is SelectiveGeometry &&
      center == other.center &&
      radius == other.radius &&
      feather == other.feather &&
      angle == other.angle &&
      width == other.width &&
      invert == other.invert &&
      aspect == other.aspect;

  @override
  int get hashCode =>
      Object.hash(center, radius, feather, angle, width, invert, aspect);

  @override
  String toString() =>
      'SelectiveGeometry(center: $center, radius: $radius, '
      'feather: $feather, angle: $angle, width: $width, '
      'invert: $invert, aspect: $aspect)';
}

/// GLSL-style smoothstep: 0 below `e0`, 1 above `e1`, Hermite blend
/// `t*t*(3-2t)` in between. Degenerate `e0 == e1` returns 0.0 (GLSL
/// leaves that case undefined; Enhance's Dart `_smoothstep` does the
/// same). Top-level for testability; pure (no Flutter).
double selectiveSmoothstep(double e0, double e1, double x) {
  if (e0 == e1) return 0.0;
  final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// 1-D brush kernel: falloff of a dab with distance [d] (0..1 in uv
/// units) from the stroke spine, `radius` dab radius (0..1).
///
/// `dn = d / max(radius, eps)`, then the radial kernel:
/// `w = 1 - smoothstep(1 - feather, 1, dn)`, hard step at `feather <= 0`.
/// Output is clamped to 0..1. Pure (no Flutter).
double brushFalloff(double d, double radius, double feather) {
  const double eps = 1e-6;
  final double dn = d / math.max(radius, eps);
  double w;
  if (feather <= 0.0) {
    w = dn <= 1.0 ? 1.0 : 0.0;
  } else {
    final double e0 = (1.0 - feather).clamp(0.0, 1.0);
    w = 1.0 - selectiveSmoothstep(e0, 1.0, dn);
  }
  return w.clamp(0.0, 1.0);
}

/// Evaluates the selective mask weight at normalized uv ([x], [y]).
///
/// Pure (no Flutter), safe for tight per-pixel loops. `brush` mode
/// returns 0.0 — brush masks come from `rasterizeBrushMask` in
/// `mask_raster.dart`, there is no analytic field to evaluate here.
/// See the library docs for the exact per-mode formulas.
double selectiveWeight(
  double x,
  double y,
  SelectiveGeometry g,
  SelectiveMode mode,
) {
  const double eps = 1e-6;
  double w;
  switch (mode) {
    case SelectiveMode.radial:
      final double dx = (x - g.center.$1) * g.aspect;
      final double dy = y - g.center.$2;
      final double d = math.sqrt(dx * dx + dy * dy) / math.max(g.radius, eps);
      if (g.feather <= 0.0) {
        w = d <= 1.0 ? 1.0 : 0.0;
      } else {
        final double e0 = (1.0 - g.feather).clamp(0.0, 1.0);
        w = 1.0 - selectiveSmoothstep(e0, 1.0, d);
      }
    case SelectiveMode.linear:
      final double a = g.angle * math.pi / 180.0;
      final double p =
          ((x - g.center.$1) * math.cos(a) + (y - g.center.$2) * math.sin(a)) /
          math.max(g.width, eps);
      final double ap = p.abs();
      if (g.feather <= 0.0) {
        w = ap <= 1.0 ? 1.0 : 0.0;
      } else {
        final double e0 = (1.0 - g.feather).clamp(0.0, 1.0);
        w = 1.0 - selectiveSmoothstep(e0, 1.0, ap);
      }
    case SelectiveMode.brush:
      // No analytic field — rasterize strokes instead. 0.0 (no effect)
      // is the safe default so generic pipelines stay silent.
      w = 0.0;
  }
  if (g.invert) w = 1.0 - w;
  return w.clamp(0.0, 1.0);
}
