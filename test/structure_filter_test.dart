import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';

import 'package:lens/features/imaging/structure/structure_filter.dart';

/// Uniform mid grey (0.5): the guided filter must return the input as its
/// own base, so the detail map is empty.
Float32List _flatImage(int width, int height) {
  final Float32List out = Float32List(width * height * 3);
  for (int i = 0; i < width * height; i++) {
    out[i * 3] = 0.5;
    out[i * 3 + 1] = 0.5;
    out[i * 3 + 2] = 0.5;
  }
  return out;
}

/// One hard vertical edge: the left half is 0.25, the right half 0.75.
Float32List _stepImage(int width, int height) {
  final Float32List out = Float32List(width * height * 3);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final double v = x < width ~/ 2 ? 0.25 : 0.75;
      final int i = (y * width + x) * 3;
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
    }
  }
  return out;
}

/// Smooth band-limited texture around 0.5 (amplitude ~0.08).
Float32List _textureImage(int width, int height) {
  final Float32List out = Float32List(width * height * 3);
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final double v = 0.5 + 0.08 * math.sin(x * 0.7) * math.sin(y * 0.5);
      final int i = (y * width + x) * 3;
      out[i] = v;
      out[i + 1] = v;
      out[i + 2] = v;
    }
  }
  return out;
}

/// The same texture SCALE at any resolution: the pattern is a function of
/// the normalised coordinate, so 128x128 and 512x512 carry the same number
/// of periods and the same relative feature size.
Float32List _normalizedTexture(int width, int height, double periods) {
  final Float32List out = Float32List(width * height * 3);
  for (int y = 0; y < height; y++) {
    final double v = (y + 0.5) / height;
    for (int x = 0; x < width; x++) {
      final double u = (x + 0.5) / width;
      final double value =
          0.5 +
          0.08 *
              math.sin(2 * math.pi * periods * u) *
              math.sin(2 * math.pi * periods * v);
      final int i = (y * width + x) * 3;
      out[i] = value;
      out[i + 1] = value;
      out[i + 2] = value;
    }
  }
  return out;
}

/// The maps the export path would build for [image] (the radius comes from
/// the resolution-relative geometry).
StructureMaps _mapsFor(Float32List image, int width, int height) {
  final StructureGeometry geometry = structureGeometryFor(width, height);
  return computeStructureMapsFromRgb(
    image,
    width,
    height,
    radius: geometry.radius.toDouble(),
  );
}

/// Mean absolute multiplier deviation over the frame: how much local
/// contrast the stage adds to [image] at full strength.
double _meanMultiplierDeviation(Float32List image, int width, int height) {
  final StructureMaps maps = _mapsFor(image, width, height);
  double acc = 0.0;
  for (int y = 0; y < height; y++) {
    for (int x = 0; x < width; x++) {
      final double yraw = image[(y * width + x) * 3];
      final double base = structureBaseAt(maps, x, y, yraw);
      final double multiplier = structureMultiplier(
        yraw: yraw,
        q: base,
        amount: 1.0,
      );
      acc += (multiplier - 1.0).abs();
    }
  }
  return acc / (width * height);
}

void main() {
  test('geometry adapts the subsample ratio to the radius', () {
    final StructureGeometry phone = structureGeometryFor(1080, 1440);
    expect(phone.radius, 8);
    expect(phone.subsample, 4);
    expect(phone.lowRadius, 2);

    final StructureGeometry big = structureGeometryFor(3000, 4000);
    expect(big.radius, 23);
    expect(big.subsample, 12);
    expect(big.lowRadius, 2);

    final StructureGeometry tiny = structureGeometryFor(16, 16);
    expect(tiny.radius, 2);
    expect(tiny.subsample, 1);
    expect(tiny.lowRadius, 2);
  });

  test('flat image has no detail', () {
    const int width = 64;
    const int height = 64;
    final Float32List image = _flatImage(width, height);
    final StructureMaps maps = _mapsFor(image, width, height);

    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        expect(
          structureBaseAt(maps, x, y, 0.5),
          closeTo(0.5, 1e-3),
          reason: 'base at ($x,$y)',
        );
      }
    }
    expect(structureMultiplier(yraw: 0.5, q: 0.5, amount: 1.0), 1.0);
    expect(structureMultiplier(yraw: 0.5, q: 0.5, amount: -1.0), 1.0);
  });

  test('step edge is protected from halos', () {
    const int width = 64;
    const int height = 64;
    const int edge = width ~/ 2;
    const double low = 0.25;
    const double high = 0.75;
    const double step = high - low;
    final Float32List image = _stepImage(width, height);
    final StructureMaps maps = _mapsFor(image, width, height);

    // The pixels straddling the edge keep the base at their own luma: the
    // guided filter follows the step instead of blurring across it.
    for (final int x in <int>[edge - 1, edge]) {
      final double yraw = x < edge ? low : high;
      final double base = structureBaseAt(maps, x, height ~/ 2, yraw);
      expect(
        (base - yraw).abs(),
        lessThan(0.25 * step),
        reason: 'halo at the edge pixel $x',
      );
    }

    // The flat sides carry no detail at all.
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        if ((x - edge).abs() < 8) continue;
        final double yraw = x < edge ? low : high;
        final double base = structureBaseAt(maps, x, y, yraw);
        expect(
          (base - yraw).abs(),
          lessThan(1e-3),
          reason: 'detail on the flat side at ($x,$y)',
        );
      }
    }
  });

  test('texture produces a non-zero detail map', () {
    const int width = 64;
    const int height = 64;
    final Float32List image = _textureImage(width, height);
    final StructureMaps maps = _mapsFor(image, width, height);

    double maxDetail = 0.0;
    int boosted = 0;
    int softened = 0;
    for (int y = 0; y < height; y++) {
      for (int x = 0; x < width; x++) {
        final double yraw = image[(y * width + x) * 3];
        final double base = structureBaseAt(maps, x, y, yraw);
        final double detail = yraw - base;
        if (detail.abs() > maxDetail) maxDetail = detail.abs();
        final double multiplier = structureMultiplier(
          yraw: yraw,
          q: base,
          amount: 1.0,
        );
        if (detail > 0.01) {
          expect(
            multiplier,
            greaterThan(1.0),
            reason: 'bright texture at ($x,$y)',
          );
          boosted++;
        } else if (detail < -0.01) {
          expect(multiplier, lessThan(1.0), reason: 'dark texture at ($x,$y)');
          softened++;
        }
      }
    }
    expect(maxDetail, greaterThanOrEqualTo(0.01));
    expect(boosted, greaterThan(0));
    expect(softened, greaterThan(0));
  });

  test('midtone mask is parabolic', () {
    // Black and white carry no mask at all: the stage is an exact no-op.
    expect(structureMultiplier(yraw: 0.4, q: 0.0, amount: 1.0), 1.0);
    expect(structureMultiplier(yraw: 0.4, q: 1.0, amount: 1.0), 1.0);
    expect(structureMultiplier(yraw: 0.4, q: 0.0, amount: -1.0), 1.0);
    expect(structureMultiplier(yraw: 0.4, q: 1.0, amount: -1.0), 1.0);

    // The guided filter's local linear model can overshoot past 0..1 near a
    // hard edge; the mask is computed on the clamped base, so it can never
    // go negative and flip the sign of the effect.
    expect(structureMultiplier(yraw: 0.9, q: 1.4, amount: 1.0), 1.0);
    expect(structureMultiplier(yraw: 0.9, q: -0.2, amount: 1.0), 1.0);

    // The same local log-contrast at three base levels: the effect peaks at
    // middle grey and dies out towards the ends.
    const double dEV = 0.2;
    final double atMid = structureMultiplier(
      yraw: 0.5 * math.exp(dEV),
      q: 0.5,
      amount: 1.0,
    );
    final double atQuarter = structureMultiplier(
      yraw: 0.25 * math.exp(dEV),
      q: 0.25,
      amount: 1.0,
    );
    final double atThreeQuarter = structureMultiplier(
      yraw: 0.75 * math.exp(dEV),
      q: 0.75,
      amount: 1.0,
    );
    expect((atMid - 1.0).abs(), greaterThan((atQuarter - 1.0).abs()));
    expect((atMid - 1.0).abs(), greaterThan((atThreeQuarter - 1.0).abs()));
    expect(
      (atQuarter - 1.0).abs(),
      closeTo((atThreeQuarter - 1.0).abs(), 1e-12),
    );
  });

  test('amount is signed', () {
    final double positive = structureMultiplier(
      yraw: 0.62,
      q: 0.5,
      amount: 1.0,
    );
    final double negative = structureMultiplier(
      yraw: 0.62,
      q: 0.5,
      amount: -1.0,
    );
    expect(positive, greaterThan(1.0));
    expect(negative, lessThan(1.0));
    expect(negative, closeTo(1.0 / positive, 1e-6));
  });

  test('stage transfer function is exact', () {
    // Absolute values from the closed form, pinned with literal constants so
    // a change of GAIN, of the log base or of the mask shape cannot pass
    // unnoticed.
    // q = 0.5 -> mask = 4 * 0.5 * 0.5 = 1, dEV = 0.2
    // -> E = 1 * 2.5 * 1 * 0.2 = 0.5.
    expect(
      structureMultiplier(yraw: 0.5 * math.exp(0.2), q: 0.5, amount: 1.0),
      closeTo(math.exp(0.5), 1e-12),
    );
    // q = 0.25 -> mask = 4 * 0.25 * 0.75 = 0.75, dEV = 0.2
    // -> E = 1 * 2.5 * 0.75 * 0.2 = 0.375.
    expect(
      structureMultiplier(yraw: 0.25 * math.exp(0.2), q: 0.25, amount: 1.0),
      closeTo(math.exp(0.375), 1e-12),
    );
    // amount = 0 is an exact no-op even when the pixel is far from its base.
    expect(structureMultiplier(yraw: 0.9, q: 0.2, amount: 0.0), 1.0);
    expect(structureMultiplier(yraw: 0.1, q: 0.8, amount: 0.0), 1.0);
  });

  test('exponent is clamped', () {
    final double multiplier = structureMultiplier(
      yraw: 0.9,
      q: 0.18,
      amount: 1.0,
    );
    // The spec states the bound as "the multiplier in [0.5, 2.0]"; the exact
    // bounds are the exponent clamp: exp(-0.7) = 0.4966, exp(0.7) = 2.0138.
    expect(multiplier, lessThanOrEqualTo(math.exp(kStructureExponentClamp)));
    expect(
      multiplier,
      greaterThanOrEqualTo(math.exp(-kStructureExponentClamp)),
    );
    expect(multiplier, closeTo(math.exp(kStructureExponentClamp), 1e-12));
  });

  test('packed maps round-trip within the documented budget', () {
    const int width = 64;
    const int height = 64;
    final Float32List image = _textureImage(width, height);
    final StructureMaps maps = _mapsFor(image, width, height);
    final Uint8List packed = packStructureMaps(maps);
    expect(packed.length, maps.width * maps.height * 4);

    for (int i = 0; i < maps.width * maps.height; i++) {
      final int o = i * 4;
      final double a = packed[o] / 255.0;
      final double b = (packed[o + 1] * 256 + packed[o + 2]) / 65535.0;
      expect(
        (a - maps.a[i]).abs(),
        lessThanOrEqualTo(1.0 / 255.0),
        reason: 'a at $i',
      );
      expect(
        (b - maps.b[i]).abs(),
        lessThanOrEqualTo(2.0 / 65535.0),
        reason: 'b at $i',
      );
      expect(packed[o + 3], 255);
    }
  });

  test('rgba and rgb inputs agree', () {
    const int width = 64;
    const int height = 64;
    final Float32List texture = _textureImage(width, height);
    // The byte image is the quantised texture and the float image carries
    // that same pixel data, so both inputs describe identical pixels.
    final Uint8List rgba = Uint8List(width * height * 4);
    final Float32List rgb = Float32List(width * height * 3);
    for (int i = 0; i < width * height; i++) {
      for (int c = 0; c < 3; c++) {
        final int byte = (texture[i * 3 + c] * 255.0).round();
        rgb[i * 3 + c] = byte / 255.0;
        rgba[i * 4 + c] = byte;
      }
      rgba[i * 4 + 3] = 255;
    }

    final double radius = structureGeometryFor(width, height).radius.toDouble();
    final StructureMaps fromRgb = computeStructureMapsFromRgb(
      rgb,
      width,
      height,
      radius: radius,
    );
    final StructureMaps fromRgba = computeStructureMapsFromRgba(
      rgba,
      width,
      height,
      radius: radius,
    );
    expect(fromRgba.width, fromRgb.width);
    expect(fromRgba.height, fromRgb.height);
    for (int i = 0; i < fromRgb.width * fromRgb.height; i++) {
      expect(
        (fromRgba.a[i] - fromRgb.a[i]).abs(),
        lessThanOrEqualTo(1.0 / 255.0),
        reason: 'a at $i',
      );
      expect(
        (fromRgba.b[i] - fromRgb.b[i]).abs(),
        lessThanOrEqualTo(1.0 / 255.0),
        reason: 'b at $i',
      );
    }
  });

  test('luma uses the BT.601-style weights on both inputs', () {
    // A uniform pure-red / pure-green / pure-blue frame has no variance, so
    // `a == 0` and `b` is exactly the frame's luma. The weights are
    // 0.299 / 0.587 / 0.114 (BT.601) and the shader hard-codes the same
    // numbers, so a weight regression here would silently break the
    // preview/export parity.
    const int width = 32;
    const int height = 32;
    const List<double> weights = <double>[0.299, 0.587, 0.114];
    final double radius = structureGeometryFor(width, height).radius.toDouble();

    for (int channel = 0; channel < 3; channel++) {
      final Float32List rgb = Float32List(width * height * 3);
      final Uint8List rgba = Uint8List(width * height * 4);
      for (int i = 0; i < width * height; i++) {
        rgb[i * 3 + channel] = 1.0;
        rgba[i * 4 + channel] = 255;
        rgba[i * 4 + 3] = 255;
      }
      final StructureMaps fromRgb = computeStructureMapsFromRgb(
        rgb,
        width,
        height,
        radius: radius,
      );
      final StructureMaps fromRgba = computeStructureMapsFromRgba(
        rgba,
        width,
        height,
        radius: radius,
      );

      for (final StructureMaps maps in <StructureMaps>[fromRgb, fromRgba]) {
        for (int i = 0; i < maps.width * maps.height; i++) {
          expect(maps.a[i], 0.0, reason: 'a for channel $channel');
          expect(
            maps.b[i],
            closeTo(weights[channel], 1e-6),
            reason: 'b for channel $channel',
          );
        }
        expect(
          structureBaseAt(maps, 3, 7, 0.4),
          closeTo(weights[channel], 1e-6),
          reason: 'base for channel $channel',
        );
      }
    }
  });

  test('the base uses the texel-centre sampling convention', () {
    // A 2x2 low-res grid over a 4x4 source. The documented mapping is
    // `fx = (x + 0.5) * lowWidth / sourceWidth - 0.5` with clamped edges,
    // i.e. `fx = 0.5 * x - 0.25` here.
    final StructureMaps slope = StructureMaps(
      a: Float32List.fromList(<double>[0.0, 0.5, 1.0, 1.0]),
      b: Float32List(4),
      width: 2,
      height: 2,
      sourceWidth: 4,
      sourceHeight: 4,
    );
    // x = 0 -> fx = -0.25 -> clamped onto the first texel.
    expect(structureBaseAt(slope, 0, 0, 1.0), closeTo(0.0, 1e-6));
    // x = 1 -> fx = 0.25 -> 0.75 * a0 + 0.25 * a1.
    expect(structureBaseAt(slope, 1, 0, 1.0), closeTo(0.125, 1e-6));
    // x = 2 -> fx = 0.75 -> 0.25 * a0 + 0.75 * a1.
    expect(structureBaseAt(slope, 2, 0, 1.0), closeTo(0.375, 1e-6));
    // x = 3 -> fx = 1.25 -> clamped onto the last texel.
    expect(structureBaseAt(slope, 3, 0, 1.0), closeTo(0.5, 1e-6));
    // The same mapping on the y axis: fy = 0.75 taps row 1 with 0.25.
    expect(structureBaseAt(slope, 0, 2, 1.0), closeTo(0.75, 1e-6));
    expect(structureBaseAt(slope, 0, 3, 1.0), closeTo(1.0, 1e-6));

    // The base is `a * yraw + b`, and `b` is sampled with the same
    // convention.
    final StructureMaps offset = StructureMaps(
      a: Float32List(4),
      b: Float32List.fromList(<double>[0.0, 0.5, 1.0, 1.0]),
      width: 2,
      height: 2,
      sourceWidth: 4,
      sourceHeight: 4,
    );
    expect(structureBaseAt(offset, 1, 0, 2.0), closeTo(0.125, 1e-6));
  });

  test('the effect is resolution relative', () {
    // The pattern is a function of the normalised coordinate, so both
    // frames carry the same texture SCALE. Its period is finer than the
    // filter window in both frames, so the comparison measures the scale
    // invariance of the effect and not the different window-to-period
    // ratio of these two (deliberately small) frame sizes.
    const double periods = 44.0;
    final double small = _meanMultiplierDeviation(
      _normalizedTexture(128, 128, periods),
      128,
      128,
    );
    final double large = _meanMultiplierDeviation(
      _normalizedTexture(512, 512, periods),
      512,
      512,
    );
    expect(small, greaterThan(0.0));
    expect(large, greaterThan(0.0));
    expect(small, closeTo(large, large * 0.3));
  });
}
