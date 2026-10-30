import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/filters/lut_definition.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

/// Smooth 32x32 color gradient: no sharp edges, so a JPEG q95 round-trip
/// stays within a tight per-channel tolerance.
img.Image _gradientImage() {
  final image = img.Image(width: 32, height: 32, numChannels: 3);
  for (int y = 0; y < 32; y++) {
    for (int x = 0; x < 32; x++) {
      image.setPixelRgb(x, y, (x * 255 ~/ 31), (y * 255 ~/ 31), 128);
    }
  }
  return image;
}

img.Image _solidImage(int r, int g, int b, [int size = 64]) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

/// Grades PNG [srcBytes] with [params] and decodes the exported JPEG.
img.Image _graded(Uint8List srcBytes, LensParams params) {
  final Uint8List out = applyLensGrade(
    srcBytes,
    params.toUniforms(),
    params.filterId,
  );
  final img.Image? decoded = img.decodeImage(out);
  expect(decoded, isNotNull);
  return decoded!;
}

(double r, double g, double b) _meanChannels(img.Image image) {
  double ar = 0, ag = 0, ab = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel p = image.getPixel(x, y);
      ar += p.r;
      ag += p.g;
      ab += p.b;
    }
  }
  final double n = (image.width * image.height).toDouble();
  return (ar / n, ag / n, ab / n);
}

void main() {
  test('bw filter yields neutral gray on a color gradient', () {
    final Uint8List srcBytes = img.encodePng(_gradientImage());
    final img.Image decoded = _graded(
      srcBytes,
      LensParams(filterId: LensFilterId.bw.index, filterStrength: 1),
    );

    // bw maps every color to rec.709 luma (+S-curve): all three channels
    // must agree. ±4 leaves headroom for JPG q95 + trilinear lattice
    // error on smooth gradients (typical max is ~2).
    for (int y = 0; y < decoded.height; y++) {
      for (int x = 0; x < decoded.width; x++) {
        final img.Pixel p = decoded.getPixel(x, y);
        expect(
          (p.r - p.g).abs(),
          lessThanOrEqualTo(4),
          reason: 'R/G split at ($x,$y)',
        );
        expect(
          (p.g - p.b).abs(),
          lessThanOrEqualTo(4),
          reason: 'G/B split at ($x,$y)',
        );
      }
    }
  });

  test('filter strength 0 equals no filter', () {
    final Uint8List srcBytes = img.encodePng(_gradientImage());

    // Same pixels through the same pipeline (LUT skipped when strength
    // is 0, identity table for none) — means must agree within JPG noise.
    final (double r0, double g0, double b0) = _meanChannels(
      _graded(
        srcBytes,
        LensParams(filterId: LensFilterId.cinematic.index, filterStrength: 0),
      ),
    );
    final (double r1, double g1, double b1) = _meanChannels(
      _graded(srcBytes, const LensParams()),
    );

    expect((r0 - r1).abs(), lessThanOrEqualTo(4), reason: 'mean R drift');
    expect((g0 - g1).abs(), lessThanOrEqualTo(4), reason: 'mean G drift');
    expect((b0 - b1).abs(), lessThanOrEqualTo(4), reason: 'mean B drift');
  });

  test('cinematic shifts hue on an orange patch (r/b ratio grows)', () {
    final Uint8List srcBytes = img.encodePng(_solidImage(220, 120, 40));

    final (double r0, double g0, double b0) = _meanChannels(
      _graded(srcBytes, const LensParams()),
    );
    final (double r1, double g1, double b1) = _meanChannels(
      _graded(
        srcBytes,
        LensParams(filterId: LensFilterId.cinematic.index, filterStrength: 1),
      ),
    );
    // Sanity: the "before" patch survived the JPG round-trip.
    expect(r0, greaterThan(200));
    expect(g1, isNotNaN);

    // Teal-orange + saturation 1.1 + contrast 1.08 push red up and blue
    // down on warm tones; the analytic shift is ~+1.3 in r/b, so +0.2 is
    // a conservative floor far above JPG noise on a flat patch.
    final double before = r0 / b0;
    final double after = r1 / b1;
    expect(after, greaterThan(before + 0.2));
  });

  test('bw at full strength visibly changes a saturated patch', () {
    // Plumbing guard for the Task 2.5 bug (filterId ignored in export):
    // if the id never reached the isolate, both outputs would be equal.
    final Uint8List srcBytes = img.encodePng(_solidImage(200, 30, 30));

    final (double r0, _, _) = _meanChannels(
      _graded(srcBytes, const LensParams()),
    );
    final (double r1, double g1, double b1) = _meanChannels(
      _graded(
        srcBytes,
        LensParams(filterId: LensFilterId.bw.index, filterStrength: 1),
      ),
    );

    // Red (200,30,30) has luma ~81; bw maps it to ~(78,78,78), so mean R
    // drops by ~120. The floor of 30 is far above any JPG artifact.
    expect((r0 - r1).abs(), greaterThan(30));
    // And the bw output is neutral.
    expect((r1 - g1).abs(), lessThanOrEqualTo(4));
    expect((g1 - b1).abs(), lessThanOrEqualTo(4));
  });
}
