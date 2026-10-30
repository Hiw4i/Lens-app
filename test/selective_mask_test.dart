import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lens/features/selective/mask_raster.dart';
import 'package:lens/features/selective/selective_mask.dart';

void main() {
  group('selectiveSmoothstep', () {
    test('degenerate edges return 0', () {
      expect(selectiveSmoothstep(1.0, 1.0, 0.5), equals(0.0));
      expect(selectiveSmoothstep(0.0, 0.0, 0.0), equals(0.0));
    });

    test('clamps outside the window', () {
      expect(selectiveSmoothstep(0.2, 0.8, 0.0), equals(0.0));
      expect(selectiveSmoothstep(0.2, 0.8, 1.0), equals(1.0));
    });

    test('midpoint is 0.5', () {
      expect(selectiveSmoothstep(0.0, 1.0, 0.5), closeTo(0.5, 1e-12));
    });
  });

  group('radial', () {
    test('center is 1, far corner is 0', () {
      const g = SelectiveGeometry();
      expect(
        selectiveWeight(0.5, 0.5, g, SelectiveMode.radial),
        closeTo(1.0, 1e-12),
      );
      expect(
        selectiveWeight(0.0, 0.0, g, SelectiveMode.radial),
        closeTo(0.0, 1e-12),
      );
    });

    test('invert flips center and corner', () {
      const g = SelectiveGeometry(invert: true);
      expect(
        selectiveWeight(0.5, 0.5, g, SelectiveMode.radial),
        closeTo(0.0, 1e-12),
      );
      expect(
        selectiveWeight(0.0, 0.0, g, SelectiveMode.radial),
        closeTo(1.0, 1e-12),
      );
    });

    test('feather 0 is a hard step (only 0 or 1)', () {
      const g = SelectiveGeometry(feather: 0.0);
      for (int i = 0; i <= 20; i++) {
        final double w = selectiveWeight(
          i / 20.0,
          0.5,
          g,
          SelectiveMode.radial,
        );
        expect(w == 0.0 || w == 1.0, isTrue, reason: 'x=${i / 20} -> $w');
      }
      // Inside the disc vs outside it.
      expect(selectiveWeight(0.5, 0.5, g, SelectiveMode.radial), equals(1.0));
      expect(selectiveWeight(0.0, 0.5, g, SelectiveMode.radial), equals(0.0));
    });

    test('feather 1 gives a true gradient mid-disc', () {
      const g = SelectiveGeometry(feather: 1.0, radius: 0.35);
      // Half-radius offset: d = 0.5 -> w = 1 - smoothstep(0, 1, 0.5) = 0.5.
      final double w = selectiveWeight(
        0.5 + 0.175,
        0.5,
        g,
        SelectiveMode.radial,
      );
      expect(w, closeTo(0.5, 1e-9));
      expect(w, greaterThan(0.0));
      expect(w, lessThan(1.0));
    });

    test('aspect stretches the disc into an ellipse', () {
      const round = SelectiveGeometry(aspect: 1.0);
      const wide = SelectiveGeometry(aspect: 2.0);
      // Same x-offset: penalized twice as hard with aspect 2.
      final double wRound = selectiveWeight(
        0.6,
        0.5,
        round,
        SelectiveMode.radial,
      );
      final double wWide = selectiveWeight(
        0.6,
        0.5,
        wide,
        SelectiveMode.radial,
      );
      expect(wWide, lessThan(wRound));
      // Same y-offset is unaffected by aspect.
      expect(
        selectiveWeight(0.5, 0.6, wide, SelectiveMode.radial),
        closeTo(selectiveWeight(0.5, 0.6, round, SelectiveMode.radial), 1e-12),
      );
    });
  });

  group('linear', () {
    test('band is symmetric around the center line', () {
      const g = SelectiveGeometry(angle: 90.0, width: 0.5);
      // angle 90 varies along y: symmetric offsets give equal weights.
      expect(
        selectiveWeight(0.5, 0.5 + 0.1, g, SelectiveMode.linear),
        closeTo(
          selectiveWeight(0.5, 0.5 - 0.1, g, SelectiveMode.linear),
          1e-12,
        ),
      );
      // Off-axis x does not matter for a horizontal band.
      expect(
        selectiveWeight(0.2, 0.5, g, SelectiveMode.linear),
        closeTo(selectiveWeight(0.8, 0.5, g, SelectiveMode.linear), 1e-12),
      );
    });

    test('center 1, far outside 0, invert flips', () {
      const g = SelectiveGeometry(angle: 90.0, width: 0.5);
      expect(
        selectiveWeight(0.5, 0.5, g, SelectiveMode.linear),
        closeTo(1.0, 1e-12),
      );
      expect(
        selectiveWeight(0.5, 0.0, g, SelectiveMode.linear),
        closeTo(0.0, 1e-12),
      );
      const inv = SelectiveGeometry(angle: 90.0, width: 0.5, invert: true);
      expect(
        selectiveWeight(0.5, 0.5, inv, SelectiveMode.linear),
        closeTo(0.0, 1e-12),
      );
      expect(
        selectiveWeight(0.5, 0.0, inv, SelectiveMode.linear),
        closeTo(1.0, 1e-12),
      );
    });

    test('brush mode weight is 0 (rasterize instead)', () {
      const g = SelectiveGeometry();
      expect(selectiveWeight(0.5, 0.5, g, SelectiveMode.brush), equals(0.0));
    });
  });

  group('brush raster', () {
    test('empty strokes yield all zeros', () {
      final Float32List m = rasterizeBrushMask(const [], 32);
      expect(m.length, equals(32 * 32));
      for (final double v in m) {
        expect(v, equals(0.0));
      }
    });

    test('single dab is 1 near center, ~0 in the corner', () {
      const stroke = BrushStroke(points: [(0.5, 0.5)], radius: 0.1);
      final Float32List m = rasterizeBrushMask(const [stroke], 64);
      double maxVal = 0.0;
      for (final double v in m) {
        if (v > maxVal) maxVal = v;
      }
      expect(maxVal, closeTo(1.0, 1e-6));
      // Corner texel is ~0.4 uv away from the dab with radius 0.1.
      expect(m[0], closeTo(0.0, 1e-6));
    });

    test('two strokes combine by max', () {
      const a = BrushStroke(points: [(0.25, 0.25)], radius: 0.1);
      const b = BrushStroke(points: [(0.75, 0.75)], radius: 0.1);
      final Float32List both = rasterizeBrushMask(const [a, b], 64);
      final Float32List onlyA = rasterizeBrushMask(const [a], 64);
      // Near b's center, `both` is ~1 while `onlyA` is ~0.
      const int idx = 48 * 64 + 48; // uv ~(0.758, 0.758)
      expect(both[idx], closeTo(1.0, 1e-3));
      expect(onlyA[idx], closeTo(0.0, 1e-3));
      // Near a's center both masks agree (max keeps a's coverage).
      const int idxA = 16 * 64 + 16;
      expect(both[idxA], closeTo(onlyA[idxA], 1e-6));
    });

    test('polyline segment covers its middle', () {
      const stroke = BrushStroke(
        points: [(0.2, 0.5), (0.8, 0.5)],
        radius: 0.08,
      );
      final Float32List m = rasterizeBrushMask(const [stroke], 64);
      const int mid = 32 * 64 + 32; // uv ~(0.508, 0.508), on the segment
      expect(m[mid], closeTo(1.0, 1e-3));
    });
  });

  group('featherBox', () {
    test('smooths a hard step edge', () {
      const int size = 16;
      final Float32List step = Float32List(size * size);
      for (int y = 0; y < size; y++) {
        for (int x = 0; x < size; x++) {
          step[y * size + x] = x < size ~/ 2 ? 0.0 : 1.0;
        }
      }
      final Float32List out = featherBox(step, size, 2);
      // Texels adjacent to the step are strictly inside (0, 1).
      expect(out[8 * size + 7], greaterThan(0.0));
      expect(out[8 * size + 7], lessThan(1.0));
      expect(out[8 * size + 8], greaterThan(0.0));
      expect(out[8 * size + 8], lessThan(1.0));
      // Far from the edge the plateau survives.
      expect(out[8 * size + 0], closeTo(0.0, 1e-9));
      expect(out[8 * size + 15], closeTo(1.0, 1e-9));
    });

    test('radius 0 returns an equal copy', () {
      final Float32List m = Float32List.fromList([0.0, 0.5, 1.0, 0.25]);
      final Float32List out = featherBox(m, 2, 0);
      expect(out, equals(m));
      expect(identical(out, m), isFalse);
    });
  });

  group('value semantics', () {
    test('geometry ==, hashCode, copyWith, defaults', () {
      const a = SelectiveGeometry();
      expect(a.center, equals((0.5, 0.5)));
      expect(a.radius, equals(0.35));
      expect(a.feather, equals(0.5));
      expect(a.angle, equals(90.0));
      expect(a.width, equals(0.5));
      expect(a.invert, isFalse);
      expect(a.aspect, equals(1.0));

      const b = SelectiveGeometry();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      final SelectiveGeometry c = a.copyWith(radius: 0.2, invert: true);
      expect(c.radius, equals(0.2));
      expect(c.invert, isTrue);
      expect(c.center, equals(a.center));
      expect(c, isNot(equals(a)));

      expect(SelectiveGeometry.none, equals(const SelectiveGeometry()));
    });

    test('BrushStroke compares points element-wise', () {
      const a = BrushStroke(points: [(0.1, 0.2), (0.3, 0.4)], radius: 0.1);
      const b = BrushStroke(points: [(0.1, 0.2), (0.3, 0.4)], radius: 0.1);
      const c = BrushStroke(points: [(0.1, 0.2)], radius: 0.1);
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));
      expect(a, isNot(equals(c)));
    });

    test('weights stay in 0..1 over a grid', () {
      const shapes = [
        SelectiveGeometry(),
        SelectiveGeometry(feather: 0.0),
        SelectiveGeometry(feather: 1.0, invert: true, aspect: 1.78),
        SelectiveGeometry(angle: 37.0, width: 0.2, invert: true),
      ];
      const modes = [SelectiveMode.radial, SelectiveMode.linear];
      for (final g in shapes) {
        for (final m in modes) {
          for (int i = 0; i <= 10; i++) {
            for (int j = 0; j <= 10; j++) {
              final double w = selectiveWeight(i / 10, j / 10, g, m);
              expect(w, greaterThanOrEqualTo(0.0));
              expect(w, lessThanOrEqualTo(1.0));
            }
          }
        }
      }
    });
  });
}
