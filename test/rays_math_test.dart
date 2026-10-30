import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';

import 'package:lens/features/rays/rays_math.dart';

void main() {
  group('raysHash', () {
    test('deterministic and in [0, 1)', () {
      for (int i = 0; i < 200; i++) {
        final double n = i * 1.7 - 50.0;
        expect(raysHash(n), equals(raysHash(n)));
        expect(raysHash(n), greaterThanOrEqualTo(0.0));
        expect(raysHash(n), lessThan(1.0));
      }
    });

    test('scatters distinct integers apart', () {
      // Neighboring lattice points must not collapse to one value —
      // otherwise value noise would be flat.
      final Set<double> vals = <double>{};
      for (int i = 0; i < 64; i++) {
        vals.add(raysHash(i.toDouble()));
      }
      expect(vals.length, greaterThan(48));
    });
  });

  group('raysNoise / raysFbm', () {
    test('continuous: small step stays small', () {
      const double eps = 1e-4;
      for (int i = 0; i < 100; i++) {
        final double x = i * 0.37 - 10.0;
        expect(
          (raysNoise(x + eps) - raysNoise(x)).abs(),
          lessThan(0.01),
          reason: 'x=$x',
        );
        expect(
          (raysFbm(x + eps) - raysFbm(x)).abs(),
          lessThan(0.01),
          reason: 'fbm x=$x',
        );
      }
    });

    test('stays in [0, 1] over a wide range', () {
      for (int i = 0; i < 400; i++) {
        final double x = i * 0.31 - 60.0;
        final double n = raysNoise(x);
        final double f = raysFbm(x);
        expect(n, greaterThanOrEqualTo(0.0));
        expect(n, lessThanOrEqualTo(1.0));
        expect(f, greaterThanOrEqualTo(0.0));
        expect(f, lessThanOrEqualTo(1.0));
      }
    });

    test('interpolates between lattice hashes', () {
      // At integers noise equals the lattice hash; halfway it is the
      // Hermite midpoint 0.5*(h0+h1).
      const double x = 7.0;
      expect(raysNoise(x), closeTo(raysHash(x), 1e-12));
      expect(
        raysNoise(x + 0.5),
        closeTo(0.5 * (raysHash(x) + raysHash(x + 1.0)), 1e-12),
      );
    });
  });

  group('raysStreak', () {
    test('stays in [0, 1] over angles and densities', () {
      for (int i = 0; i <= 64; i++) {
        final double a = i / 64.0 * 2.0 * math.pi;
        for (final double d in [0.0, 0.25, 0.5, 0.75, 1.0]) {
          final double s = raysStreak(a, d);
          expect(s, greaterThanOrEqualTo(0.0));
          expect(s, lessThanOrEqualTo(1.0));
        }
      }
    });

    test('density 0 is smoother than density 1 (lower variance)', () {
      double variance(double density) {
        const int n = 256;
        double sum = 0.0;
        double sum2 = 0.0;
        for (int i = 0; i < n; i++) {
          final double s = raysStreak(i / n * 2.0 * math.pi, density);
          sum += s;
          sum2 += s * s;
        }
        final double mean = sum / n;
        return sum2 / n - mean * mean;
      }

      final double v0 = variance(0.0);
      final double v1 = variance(1.0);
      expect(v0, greaterThanOrEqualTo(0.0));
      expect(v1, greaterThan(v0));
    });

    test('density is clamped, time 0 is the static default', () {
      expect(raysStreak(1.0, -2.0), equals(raysStreak(1.0, 0.0)));
      expect(raysStreak(1.0, 99.0), equals(raysStreak(1.0, 1.0)));
      expect(raysStreak(1.0, 0.5), equals(raysStreak(1.0, 0.5, 0.0)));
    });
  });

  group('raysDecay', () {
    test('decay(0)=1, decay(1)=0, monotonic', () {
      expect(raysDecay(0.0), equals(1.0));
      expect(raysDecay(1.0), equals(0.0));
      double prev = double.infinity;
      for (int i = 0; i <= 20; i++) {
        final double v = raysDecay(i / 20.0);
        expect(v, lessThanOrEqualTo(prev));
        prev = v;
      }
      // Quadratic: halfway is exactly 0.25.
      expect(raysDecay(0.5), closeTo(0.25, 1e-12));
    });

    test('clamps outside 0..1', () {
      expect(raysDecay(-3.0), equals(1.0));
      expect(raysDecay(42.0), equals(0.0));
    });
  });

  group('raysTint', () {
    test('warmth 0 is near-white, warmth 1 is golden', () {
      final (double, double, double) cold = raysTint(0.0);
      expect(cold.$1, closeTo(1.0, 1e-12));
      expect(cold.$2, closeTo(0.98, 1e-12));
      expect(cold.$3, closeTo(0.95, 1e-12));

      final (double, double, double) gold = raysTint(1.0);
      expect(gold.$1, closeTo(1.0, 1e-12));
      expect(gold.$2, closeTo(0.75, 1e-12));
      expect(gold.$3, closeTo(0.45, 1e-12));
      // Golden keeps a clear red-over-blue margin (warm, not gray).
      expect(gold.$1 - gold.$3, greaterThan(0.4));
      // Cold is near-achromatic.
      expect(cold.$1 - cold.$3, lessThan(0.1));
    });

    test('midpoint is the linear mix', () {
      final (double, double, double) mid = raysTint(0.5);
      expect(mid.$2, closeTo((0.98 + 0.75) / 2, 1e-12));
      expect(mid.$3, closeTo((0.95 + 0.45) / 2, 1e-12));
    });
  });

  group('applyRaysPixel', () {
    test('intensity 0 is the bit-exact identity', () {
      const tint = (1.0, 0.75, 0.45);
      for (final (double, double, double) c in [
        (0.0, 0.0, 0.0),
        (0.2, 0.5, 0.8),
        (1.0, 1.0, 1.0),
      ]) {
        final out = applyRaysPixel(c.$1, c.$2, c.$3, 1.0, 1.0, 1.0, tint, 0.0);
        expect(out.$1, equals(c.$1));
        expect(out.$2, equals(c.$2));
        expect(out.$3, equals(c.$3));
        expect(identical(out.$1, c.$1), isTrue);
      }
    });

    test('zero light/streak/decay is a no-op at any intensity', () {
      const tint = (1.0, 0.75, 0.45);
      expect(
        applyRaysPixel(0.3, 0.4, 0.5, 0.0, 1.0, 1.0, tint, 1.0),
        equals((0.3, 0.4, 0.5)),
      );
      expect(
        applyRaysPixel(0.3, 0.4, 0.5, 1.0, 0.0, 1.0, tint, 1.0),
        equals((0.3, 0.4, 0.5)),
      );
      expect(
        applyRaysPixel(0.3, 0.4, 0.5, 1.0, 1.0, 0.0, tint, 1.0),
        equals((0.3, 0.4, 0.5)),
      );
    });

    test('screen only brightens and matches the closed form', () {
      const tint = (1.0, 0.75, 0.45);
      const double light = 0.8, streak = 0.6, decay = 0.5, k = 0.9;
      for (final (double, double, double) c in [
        (0.0, 0.0, 0.0),
        (0.2, 0.5, 0.8),
        (0.9, 0.95, 1.0),
      ]) {
        final out = applyRaysPixel(
          c.$1,
          c.$2,
          c.$3,
          light,
          streak,
          decay,
          tint,
          k,
        );
        expect(out.$1, greaterThanOrEqualTo(c.$1));
        expect(out.$2, greaterThanOrEqualTo(c.$2));
        expect(out.$3, greaterThanOrEqualTo(c.$3));
        const double kk = light * streak * decay * k;
        expect(
          out.$1,
          closeTo(1.0 - (1.0 - c.$1) * (1.0 - tint.$1 * kk), 1e-12),
        );
        expect(
          out.$2,
          closeTo(1.0 - (1.0 - c.$2) * (1.0 - tint.$2 * kk), 1e-12),
        );
        expect(
          out.$3,
          closeTo(1.0 - (1.0 - c.$3) * (1.0 - tint.$3 * kk), 1e-12),
        );
      }
    });

    test('white input stays white, black input shows tint * k', () {
      const tint = (1.0, 0.75, 0.45);
      final white = applyRaysPixel(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, tint, 1.0);
      expect(white, equals((1.0, 1.0, 1.0)));
      final black = applyRaysPixel(0.0, 0.0, 0.0, 1.0, 1.0, 1.0, tint, 0.5);
      expect(black.$1, closeTo(0.5 * tint.$1, 1e-12));
      expect(black.$2, closeTo(0.5 * tint.$2, 1e-12));
      expect(black.$3, closeTo(0.5 * tint.$3, 1e-12));
    });
  });

  group('RaysParams value semantics', () {
    test('defaults, off, ==, hashCode, copyWith', () {
      const a = RaysParams();
      expect(a.source, equals((0.5, 0.2)));
      expect(a.intensity, equals(0.0));
      expect(a.length, equals(0.6));
      expect(a.warmth, equals(0.7));
      expect(a.density, equals(0.5));

      expect(RaysParams.off.intensity, equals(0.0));
      expect(RaysParams.off, equals(const RaysParams()));

      const b = RaysParams();
      expect(a, equals(b));
      expect(a.hashCode, equals(b.hashCode));

      final RaysParams c = a.copyWith(intensity: 0.8, source: (0.2, 0.1));
      expect(c.intensity, equals(0.8));
      expect(c.source, equals((0.2, 0.1)));
      expect(c.warmth, equals(a.warmth));
      expect(c, isNot(equals(a)));
    });
  });
}
