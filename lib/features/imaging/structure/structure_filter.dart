import 'dart:math' as math;
import 'dart:typed_data';

/// Structure as a real local-contrast control: the shared base/detail
/// module used by BOTH the GPU preview and the CPU export.
///
/// Pure Dart on purpose: this file imports `dart:math` and `dart:typed_data`
/// only (no Flutter, no `dart:ui`, no `package:image`), so it is safe to
/// run inside an isolate (`Isolate.run`) on the export path and inside the
/// preview's worker isolate.
///
/// The math is the design spec's section 3, mirrored 1:1 in
/// `shaders/lens_filter.frag`:
///
/// ```text
/// Ylow = boxDownsample(Yraw, s)      // luma on the low-res grid
/// mY   = boxFilter(Ylow,  r')        // sliding-window box, O(N)
/// mYY  = boxFilter(Ylow^2, r')
/// var  = max(mYY - mY*mY, 0)
/// a0   = var / (var + eps)           // self-guided filter (p = I = Yraw)
/// b0   = mY * (1 - a0)
/// a    = boxFilter(a0,   r')
/// b    = boxFilter(b0,   r')
/// q    = a * Yraw + b                // the edge-preserving BASE
/// dEV  = clamp(ln(max(Yraw,1e-3) / max(q,1e-3)), -1, 1)
/// M    = 4 * q * (1 - q)             // parabolic midtone mask
/// E    = clamp(amount * GAIN * M * dEV, -0.7, 0.7)
/// RGB' = RGB_graded * exp(E)
/// ```

/// The guided filter radius as a fraction of the short side of the frame,
/// so the texture scale is identical at any resolution.
const double kStructureRadiusFrac = 0.0075;

/// The smallest guided filter radius, in full-res pixels.
const int kStructureRadiusMinPx = 2;

/// The largest guided filter radius, in full-res pixels.
const int kStructureRadiusMaxPx = 96;

/// The guided filter radius in the LOW-RES grid. The subsample ratio is
/// derived from it, so the low-res window is always ~2 texels and the
/// filter transfer function does not change with the resolution.
const int kStructureLowRadius = 2;

/// The largest subsample ratio (the low-res grid is at least 1/16 of the
/// source).
const int kStructureMaxSubsample = 16;

/// Guided filter regularisation. Large enough that a strong edge keeps its
/// contrast in the base (no halo), small enough that texture falls into the
/// detail map.
const double kStructureEps = 0.01;

/// How hard the slider pushes the local log-contrast: the exponent is
/// `amount * kStructureGain * mask * dEV`.
const double kStructureGain = 2.5;

/// Clamp of the local log-contrast `dEV` (natural-log units) before it
/// enters the exponent.
const double kStructureDetailClamp = 1.0;

/// Clamp of the signed exponent. The multiplier is therefore
/// `exp(-0.7) = 0.4966` .. `exp(0.7) = 2.0138` (the spec's "[0.5, 2.0]").
const double kStructureExponentClamp = 0.7;

/// The geometry of the structure filter for one frame.
///
/// * [radius] — the guided filter radius in FULL-RES pixels.
/// * [subsample] — the low-res factor `s`: the source luma is box
///   downsampled by `s` before the guided filter runs (Fast Guided Filter).
/// * [lowRadius] — the guided filter radius in LOW-RES texels.
class StructureGeometry {
  const StructureGeometry({
    required this.radius,
    required this.subsample,
    required this.lowRadius,
  });

  /// The guided filter radius in full-res pixels.
  final int radius;

  /// The low-res factor `s` of the guided filter.
  final int subsample;

  /// The guided filter radius in low-res texels.
  final int lowRadius;

  @override
  String toString() =>
      'StructureGeometry(radius: $radius, '
      'subsample: $subsample, lowRadius: $lowRadius)';
}

/// The low-res guided-filter coefficient maps of one source frame.
///
/// The base luma of a full-res pixel is `a * Yraw + b`, where `a` and `b`
/// are sampled bilinearly at the pixel's low-res position (see
/// [structureBaseAt]).
class StructureMaps {
  const StructureMaps({
    required this.a,
    required this.b,
    required this.width,
    required this.height,
    required this.sourceWidth,
    required this.sourceHeight,
  });

  /// The low-res guided-filter slope map.
  final Float32List a;

  /// The low-res guided-filter intercept map.
  final Float32List b;

  /// The width of the low-res grid.
  final int width;

  /// The height of the low-res grid.
  final int height;

  /// The full-res width the maps belong to.
  final int sourceWidth;

  /// The full-res height the maps belong to.
  final int sourceHeight;
}

/// The geometry of the structure filter for a [width] x [height] frame.
///
/// The radius is a fraction of the short side, so the texture scale is the
/// same at any resolution; the subsample ratio is derived from the radius
/// so the low-res window is always ~2 texels. Both paths (preview and
/// export) call this, which is what keeps them in step.
StructureGeometry structureGeometryFor(int width, int height) {
  final int shortSide = math.min(width, height);
  final int radius = (kStructureRadiusFrac * shortSide).round().clamp(
    kStructureRadiusMinPx,
    kStructureRadiusMaxPx,
  );
  return _geometryForRadius(radius.toDouble());
}

/// The maps for a full-res RGB source (interleaved floats in 0..1).
///
/// [radius] is the guided filter radius in full-res pixels (see
/// [structureGeometryFor]). The source luma uses the same BT.601-style
/// 0.299 / 0.587 / 0.114 weights as the rest of the app (the shader
/// hard-codes the same numbers). The source luma is folded into the
/// low-res grid on the fly, so no full-res luma plane is ever allocated.
StructureMaps computeStructureMapsFromRgb(
  Float32List rgb,
  int width,
  int height, {
  required double radius,
}) {
  assert(rgb.length >= width * height * 3);
  final StructureGeometry geometry = _geometryForRadius(radius);
  final int lowWidth = (width / geometry.subsample).ceil();
  final int lowHeight = (height / geometry.subsample).ceil();

  final Float64List low = Float64List(lowWidth * lowHeight);
  for (int ly = 0; ly < lowHeight; ly++) {
    final int y0 = _blockStart(ly, height, lowHeight);
    final int y1 = _blockEnd(ly, height, lowHeight);
    for (int lx = 0; lx < lowWidth; lx++) {
      final int x0 = _blockStart(lx, width, lowWidth);
      final int x1 = _blockEnd(lx, width, lowWidth);
      double acc = 0.0;
      int count = 0;
      for (int y = y0; y < y1; y++) {
        final int row = y * width;
        for (int x = x0; x < x1; x++) {
          final int i = (row + x) * 3;
          acc += 0.299 * rgb[i] + 0.587 * rgb[i + 1] + 0.114 * rgb[i + 2];
          count++;
        }
      }
      low[ly * lowWidth + lx] = count > 0 ? acc / count : 0.0;
    }
  }
  return _guidedMaps(low, lowWidth, lowHeight, width, height, geometry);
}

/// The maps for a full-res RGBA source in `dart:ui`'s `rawRgba` channel
/// order (R, G, B, A per pixel), values 0..255.
///
/// The alpha channel is ignored; the luma uses the same BT.601-style
/// 0.299 / 0.587 / 0.114 weights as every other luma in the app (the
/// shader hard-codes the same numbers), on the 0..1 byte values.
StructureMaps computeStructureMapsFromRgba(
  Uint8List rgba,
  int width,
  int height, {
  required double radius,
}) {
  assert(rgba.length >= width * height * 4);
  final StructureGeometry geometry = _geometryForRadius(radius);
  final int lowWidth = (width / geometry.subsample).ceil();
  final int lowHeight = (height / geometry.subsample).ceil();

  // This block loop deliberately mirrors the RGB one above instead of
  // sharing it behind a per-pixel luma callback: this is the export hot
  // path (up to 12 MP), where an indirect call per pixel would cost more
  // than the duplication.
  final Float64List low = Float64List(lowWidth * lowHeight);
  for (int ly = 0; ly < lowHeight; ly++) {
    final int y0 = _blockStart(ly, height, lowHeight);
    final int y1 = _blockEnd(ly, height, lowHeight);
    for (int lx = 0; lx < lowWidth; lx++) {
      final int x0 = _blockStart(lx, width, lowWidth);
      final int x1 = _blockEnd(lx, width, lowWidth);
      double acc = 0.0;
      int count = 0;
      for (int y = y0; y < y1; y++) {
        final int row = y * width;
        for (int x = x0; x < x1; x++) {
          final int i = (row + x) * 4;
          acc += 0.299 * rgba[i] + 0.587 * rgba[i + 1] + 0.114 * rgba[i + 2];
          count++;
        }
      }
      low[ly * lowWidth + lx] = count > 0 ? acc / (count * 255.0) : 0.0;
    }
  }
  return _guidedMaps(low, lowWidth, lowHeight, width, height, geometry);
}

/// The base luma of the full-res pixel at ([x], [y]), given its raw luma
/// [yraw].
///
/// This is the ONE sampling convention of the module, mirrored 1:1 in
/// GLSL: the low-res texels are sampled at the texel-centre mapping
///
/// ```text
/// fx = (x + 0.5) * maps.width / maps.sourceWidth - 0.5
/// fy = (y + 0.5) * maps.height / maps.sourceHeight - 0.5
/// ```
///
/// with bilinear weights and clamped edges - exactly what the GPU's linear
/// filter does on a clamp-to-edge texture. The result is NOT clamped: the
/// stage clamps `q` to 0..1 (see [structureMultiplier]).
double structureBaseAt(StructureMaps maps, int x, int y, double yraw) {
  final double fx = (x + 0.5) * maps.width / maps.sourceWidth - 0.5;
  final double fy = (y + 0.5) * maps.height / maps.sourceHeight - 0.5;
  final double a = _bilinear(maps.a, maps.width, maps.height, fx, fy);
  final double b = _bilinear(maps.b, maps.width, maps.height, fx, fy);
  return a * yraw + b;
}

/// The structure stage's multiplier for one pixel - mirrored 1:1 in GLSL.
///
/// * [yraw] — the raw luma of the pixel.
/// * [q] — the base luma (see [structureBaseAt]).
/// * [amount] — the signed slider value, -1..1.
///
/// Returns `exp(E)` with `E = clamp(amount * GAIN * M * dEV, -0.7, 0.7)`
/// and `M = 4 * q * (1 - q)`, the parabolic midtone mask. At `amount = 0`
/// the multiplier is exactly 1, so the stage is an exact no-op.
double structureMultiplier({
  required double yraw,
  required double q,
  required double amount,
}) {
  final double base = q.clamp(0.0, 1.0);
  final double dEV = math
      .log(math.max(yraw, 1e-3) / math.max(base, 1e-3))
      .clamp(-kStructureDetailClamp, kStructureDetailClamp);
  final double mask = 4.0 * base * (1.0 - base);
  final double exponent = (amount * kStructureGain * mask * dEV).clamp(
    -kStructureExponentClamp,
    kStructureExponentClamp,
  );
  return math.exp(exponent);
}

/// Packs the maps for the preview texture: R = `a` (8 bit), G:B = `b`
/// (16 bit big-endian), A = 255.
///
/// `a` and `b` are clamped to 0..1 before quantisation: the guided filter's
/// local linear model is unbounded and can overshoot slightly outside the
/// range near a hard edge, and an out-of-range value would wrap the 16-bit
/// pair.
///
/// The shader decodes `b` as `(g * 255 * 256 + b * 255) / 65535`.
Uint8List packStructureMaps(StructureMaps maps) {
  final int count = maps.width * maps.height;
  final Uint8List out = Uint8List(count * 4);
  for (int i = 0; i < count; i++) {
    final int a8 = (maps.a[i].clamp(0.0, 1.0) * 255.0).round();
    final int b16 = (maps.b[i].clamp(0.0, 1.0) * 65535.0).round();
    final int o = i * 4;
    out[o] = a8;
    out[o + 1] = (b16 >> 8) & 0xff;
    out[o + 2] = b16 & 0xff;
    out[o + 3] = 0xff;
  }
  return out;
}

/// The geometry for an explicit full-res [radius].
///
/// The subsample ratio is derived from the radius so the low-res window is
/// always ~2 texels (`kStructureLowRadius`), and the low-res radius is the
/// radius expressed in those texels.
StructureGeometry _geometryForRadius(double radius) {
  final int fullRadius = radius.round().clamp(
    kStructureRadiusMinPx,
    kStructureRadiusMaxPx,
  );
  final int subsample = (fullRadius / kStructureLowRadius).round().clamp(
    1,
    kStructureMaxSubsample,
  );
  final int lowRadius = (fullRadius / subsample).round().clamp(1, fullRadius);
  return StructureGeometry(
    radius: fullRadius,
    subsample: subsample,
    lowRadius: lowRadius,
  );
}

/// The first source row/column of the low-res block [index].
int _blockStart(int index, int size, int blocks) =>
    (index * size / blocks).floor().clamp(0, size);

/// The end (exclusive) of the low-res block [index].
///
/// The blocks partition the source exactly: block `i` runs from
/// `floor(i * size / blocks)` to `floor((i + 1) * size / blocks)`, so every
/// source pixel lands in exactly one low-res texel.
int _blockEnd(int index, int size, int blocks) {
  final int start = _blockStart(index, size, blocks);
  final int end = ((index + 1) * size / blocks).floor().clamp(0, size);
  return end > start ? end : (start + 1).clamp(0, size);
}

/// The self-guided filter on the low-res luma [low].
///
/// Returns the `a` and `b` coefficient maps, both box-smoothed with the
/// low-res radius.
StructureMaps _guidedMaps(
  Float64List low,
  int lowWidth,
  int lowHeight,
  int sourceWidth,
  int sourceHeight,
  StructureGeometry geometry,
) {
  final int count = lowWidth * lowHeight;
  final Float64List mY = _boxFilter(
    low,
    lowWidth,
    lowHeight,
    geometry.lowRadius,
  );
  final Float64List squared = Float64List(count);
  for (int i = 0; i < count; i++) {
    squared[i] = low[i] * low[i];
  }
  final Float64List mYY = _boxFilter(
    squared,
    lowWidth,
    lowHeight,
    geometry.lowRadius,
  );

  final Float64List a0 = Float64List(count);
  final Float64List b0 = Float64List(count);
  for (int i = 0; i < count; i++) {
    final double variance = math.max(mYY[i] - mY[i] * mY[i], 0.0);
    final double a = variance / (variance + kStructureEps);
    a0[i] = a;
    b0[i] = mY[i] * (1.0 - a);
  }

  final Float64List a = _boxFilter(a0, lowWidth, lowHeight, geometry.lowRadius);
  final Float64List b = _boxFilter(b0, lowWidth, lowHeight, geometry.lowRadius);

  final Float32List aOut = Float32List(count);
  final Float32List bOut = Float32List(count);
  for (int i = 0; i < count; i++) {
    aOut[i] = a[i];
    bOut[i] = b[i];
  }
  return StructureMaps(
    a: aOut,
    b: bOut,
    width: lowWidth,
    height: lowHeight,
    sourceWidth: sourceWidth,
    sourceHeight: sourceHeight,
  );
}

/// A separable box filter with a sliding-window sum (O(N), independent of
/// the radius) and clamped edges: the window always holds `2 * radius + 1`
/// taps, and taps outside the grid repeat the edge texel.
Float64List _boxFilter(Float64List src, int width, int height, int radius) {
  final Float64List horizontal = Float64List(width * height);
  final Float64List out = Float64List(width * height);
  final double window = (2 * radius + 1).toDouble();

  for (int y = 0; y < height; y++) {
    final int row = y * width;
    double sum = 0.0;
    for (int i = -radius; i <= radius; i++) {
      sum += src[row + _clampIndex(i, width)];
    }
    horizontal[row] = sum / window;
    for (int x = 1; x < width; x++) {
      sum -= src[row + _clampIndex(x - 1 - radius, width)];
      sum += src[row + _clampIndex(x + radius, width)];
      horizontal[row + x] = sum / window;
    }
  }

  for (int x = 0; x < width; x++) {
    double sum = 0.0;
    for (int i = -radius; i <= radius; i++) {
      sum += horizontal[_clampIndex(i, height) * width + x];
    }
    out[x] = sum / window;
    for (int y = 1; y < height; y++) {
      sum -= horizontal[_clampIndex(y - 1 - radius, height) * width + x];
      sum += horizontal[_clampIndex(y + radius, height) * width + x];
      out[y * width + x] = sum / window;
    }
  }
  return out;
}

/// The index of the edge texel closest to [index].
int _clampIndex(int index, int size) {
  if (index < 0) return 0;
  if (index >= size) return size - 1;
  return index;
}

/// Bilinear sample of a low-res plane at texel coordinates ([fx], [fy])
/// with clamped edges.
double _bilinear(
  Float32List plane,
  int width,
  int height,
  double fx,
  double fy,
) {
  final int x0 = fx.floor();
  final int y0 = fy.floor();
  final double tx = fx - x0;
  final double ty = fy - y0;
  final int x0c = x0.clamp(0, width - 1);
  final int x1c = (x0 + 1).clamp(0, width - 1);
  final int y0c = y0.clamp(0, height - 1);
  final int y1c = (y0 + 1).clamp(0, height - 1);
  final double topLeft = plane[y0c * width + x0c];
  final double topRight = plane[y0c * width + x1c];
  final double bottomLeft = plane[y1c * width + x0c];
  final double bottomRight = plane[y1c * width + x1c];
  return (topLeft * (1.0 - tx) + topRight * tx) * (1.0 - ty) +
      (bottomLeft * (1.0 - tx) + bottomRight * tx) * ty;
}
