import 'dart:math' as math;
import 'dart:typed_data';

import 'package:lens/features/selective/selective_mask.dart';

/// Brush stroke rasterization (Task 4.1).
///
/// Pure-Dart on purpose: this file imports `dart:*` and the pure
/// `selective_mask.dart` kernel only (no Flutter, no Riverpod), so
/// [rasterizeBrushMask] and [featherBox] are safe to run inside an
/// isolate.
///
/// Resolution contract: the preview rasterizes at 128×128 (bilinear
/// upsampling in the shader/CPU path smooths the rest); export uses
/// 256×256. Complexity is `O(pixels × segments)` — at 128² with a
/// dozen segments this is ~200k point-segment distances, trivially
/// fast, but it must NOT run per-frame on the UI thread: rasterize
/// once per stroke-cache change (Task 4.3 owns the cache) and reuse
/// the [Float32List].
///
/// Layout: row-major `mask[y * size + x]`, uv of a texel center is
/// `((x + 0.5) / size, (y + 0.5) / size)`. Overlapping strokes combine
/// by `max` (paint accumulates coverage, never overshoots 1).
///
/// Task 4.3 export resolution: the preview rasterizes at 128, export
/// rasterizes at [kBrushExportMaskSize] (256) inside the export isolate
/// from the flat stroke encoding ([encodeBrushStrokes]/[decodeBrushStrokes])
/// so only a few dozen doubles cross the isolate boundary instead of a
/// 256KB raster. The CPU grade then bilinear-samples the raster at the
/// image uv (same filtering the GPU does on the 128 preview texture).

/// Export brush raster resolution (Task 4.3): 256x256 = 65k floats.
/// Rasterized inside the export isolate from [decodeBrushStrokes] output;
/// no extra [featherBox] pass is applied — the per-dab [brushFalloff]
/// kernel plus bilinear upsampling already matches the preview path
/// (128 raster + GPU linear filtering), an extra box would diverge.
const int kBrushExportMaskSize = 256;

/// One immutable brush stroke in normalized uv 0..1.
///
/// [points] is the polyline spine (consecutive entries form segments;
/// a single point is a round dab). Treat as immutable — do not mutate
/// the list after construction. [radius] is the dab radius in uv
/// units (0..1), [feather] the edge softness 0..1 (same kernel as
/// [brushFalloff]: 0 = hard disc).
class BrushStroke {
  const BrushStroke({
    this.points = const [],
    this.radius = 0.08,
    this.feather = 0.5,
  });

  /// Polyline spine in normalized uv 0..1.
  final List<(double, double)> points;

  /// Dab radius in uv units (0..1).
  final double radius;

  /// Edge softness 0..1 (0 = hard disc).
  final double feather;

  @override
  bool operator ==(Object other) {
    if (other is! BrushStroke) return false;
    if (radius != other.radius || feather != other.feather) return false;
    if (points.length != other.points.length) return false;
    for (int i = 0; i < points.length; i++) {
      if (points[i] != other.points[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(radius, feather, Object.hashAll(points));

  @override
  String toString() =>
      'BrushStroke(points: $points, radius: $radius, feather: $feather)';
}

/// Distance from point `p` to segment `ab` in uv units. Pure helper.
double _pointSegmentDistance(
  double px,
  double py,
  double ax,
  double ay,
  double bx,
  double by,
) {
  final double abx = bx - ax;
  final double aby = by - ay;
  final double len2 = abx * abx + aby * aby;
  if (len2 <= 1e-12) {
    final double dx = px - ax;
    final double dy = py - ay;
    return math.sqrt(dx * dx + dy * dy);
  }
  double t = ((px - ax) * abx + (py - ay) * aby) / len2;
  t = t.clamp(0.0, 1.0);
  final double cx = ax + abx * t;
  final double cy = ay + aby * t;
  final double dx = px - cx;
  final double dy = py - cy;
  return math.sqrt(dx * dx + dy * dy);
}

/// Rasterizes [strokes] into a `size × size` row-major 0..1 coverage
/// mask.
///
/// Each texel takes the `max` of [brushFalloff] over all strokes and
/// their segments (distance = point-to-segment distance in uv units).
/// Empty [strokes] (or strokes with no points) yield all zeros.
/// Throws [ArgumentError] when `size <= 0`. Pure (no Flutter).
Float32List rasterizeBrushMask(List<BrushStroke> strokes, int size) {
  if (size <= 0) {
    throw ArgumentError('size must be positive, got $size.');
  }
  final Float32List mask = Float32List(size * size);
  if (strokes.isEmpty) return mask;

  for (int y = 0; y < size; y++) {
    final double uvY = (y + 0.5) / size;
    for (int x = 0; x < size; x++) {
      final double uvX = (x + 0.5) / size;
      double best = 0.0;
      for (final BrushStroke s in strokes) {
        if (s.points.isEmpty || best >= 1.0) continue;
        double d;
        if (s.points.length == 1) {
          final double dx = uvX - s.points[0].$1;
          final double dy = uvY - s.points[0].$2;
          d = math.sqrt(dx * dx + dy * dy);
        } else {
          d = double.infinity;
          for (int i = 0; i + 1 < s.points.length; i++) {
            // Cheap reject: segment bbox expanded by the dab radius.
            final double ax = s.points[i].$1;
            final double ay = s.points[i].$2;
            final double bx = s.points[i + 1].$1;
            final double by = s.points[i + 1].$2;
            final double loX = math.min(ax, bx) - s.radius;
            final double hiX = math.max(ax, bx) + s.radius;
            if (uvX < loX || uvX > hiX) continue;
            final double loY = math.min(ay, by) - s.radius;
            final double hiY = math.max(ay, by) + s.radius;
            if (uvY < loY || uvY > hiY) continue;
            final double seg = _pointSegmentDistance(uvX, uvY, ax, ay, bx, by);
            if (seg < d) d = seg;
          }
          if (d == double.infinity) continue; // outside every bbox
        }
        final double w = brushFalloff(d, s.radius, s.feather);
        if (w > best) best = w;
      }
      mask[y * size + x] = best;
    }
  }
  return mask;
}

/// Separable box blur over a row-major `size × size` [mask], radius
/// [radius] texels (1–2 typical), clamped (replicated) edges.
///
/// Returns a NEW [Float32List]; the input is untouched. `radius <= 0`
/// returns a copy. Throws [ArgumentError] when `size <= 0` or
/// `mask.length != size * size`. Pure (no Flutter). Top-level for
/// tests.
Float32List featherBox(Float32List mask, int size, int radius) {
  if (size <= 0) {
    throw ArgumentError('size must be positive, got $size.');
  }
  if (mask.length != size * size) {
    throw ArgumentError(
      'Expected ${size * size} floats (size*size), got ${mask.length}.',
    );
  }
  if (radius <= 0) return Float32List.fromList(mask);

  final int r = radius;
  final int window = 2 * r + 1;
  final Float32List tmp = Float32List(mask.length);
  final Float32List out = Float32List(mask.length);

  // Horizontal pass.
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      double acc = 0.0;
      for (int k = -r; k <= r; k++) {
        acc += mask[y * size + (x + k).clamp(0, size - 1)];
      }
      tmp[y * size + x] = acc / window;
    }
  }
  // Vertical pass.
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      double acc = 0.0;
      for (int k = -r; k <= r; k++) {
        acc += tmp[(y + k).clamp(0, size - 1) * size + x];
      }
      out[y * size + x] = acc / window;
    }
  }
  return out;
}

/// Flat Sendable encoding of [strokes] for the isolate boundary (Task 4.3).
///
/// Layout (all entries plain doubles, so `List<double>` stays Sendable):
/// `[strokeCount, (pointCount, radius, feather, x0, y0, ...)*]`.
/// Counts are stored as doubles and rounded on decode. Empty input encodes
/// to `[]`, which decodes back to `[]` (callers treat both as "no brush").
/// Pure (no Flutter), safe on both sides of the isolate boundary.
List<double> encodeBrushStrokes(List<BrushStroke> strokes) {
  final List<double> flat = <double>[strokes.length.toDouble()];
  if (strokes.isEmpty) return <double>[];
  for (final BrushStroke s in strokes) {
    flat.add(s.points.length.toDouble());
    flat.add(s.radius);
    flat.add(s.feather);
    for (final (double, double) p in s.points) {
      flat.add(p.$1);
      flat.add(p.$2);
    }
  }
  return flat;
}

/// Reconstructs brush strokes from [encodeBrushStrokes] output.
///
/// Throws [ArgumentError] on truncated input or negative counts; a lone
/// empty list decodes to `[]`. Pure (no Flutter), runs inside the export
/// isolate in [ExportService].
List<BrushStroke> decodeBrushStrokes(List<double> flat) {
  if (flat.isEmpty) return <BrushStroke>[];
  int cursor = 0;
  double take() {
    if (cursor >= flat.length) {
      throw ArgumentError(
        'Truncated brush encoding at entry $cursor (len ${flat.length}).',
      );
    }
    return flat[cursor++];
  }

  final int nStrokes = take().round();
  if (nStrokes < 0) {
    throw ArgumentError('Negative stroke count $nStrokes.');
  }
  final List<BrushStroke> out = <BrushStroke>[];
  for (int s = 0; s < nStrokes; s++) {
    final int nPts = take().round();
    if (nPts < 0) throw ArgumentError('Negative point count $nPts.');
    final double radius = take();
    final double feather = take();
    final List<(double, double)> pts = <(double, double)>[];
    for (int i = 0; i < nPts; i++) {
      pts.add((take(), take()));
    }
    out.add(BrushStroke(points: pts, radius: radius, feather: feather));
  }
  return out;
}
