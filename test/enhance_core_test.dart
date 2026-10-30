import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_apply.dart';

img.Image _solid(int r, int g, int b, {int size = 64}) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

/// Low-contrast gray ramp: luma spans ~0.35..0.55 (values 90..140).
img.Image _lowContrastRamp() {
  const int w = 64;
  const int h = 8;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int v = 90 + (50 * x ~/ (w - 1));
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// Fully-saturated hue wheel: every pixel has max-min == 1, so nothing
/// looks like haze whatever the luma band.
img.Image _saturatedWheel() {
  const int w = 72;
  const int h = 8;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double hue = x / w; // 0..1
      final double hh = hue * 6.0;
      const double c = 1.0;
      final double xx = c * (1.0 - ((hh % 2.0) - 1.0).abs());
      double r = 0.0, g = 0.0, b = 0.0;
      if (hh < 1) {
        r = c;
        g = xx;
      } else if (hh < 2) {
        r = xx;
        g = c;
      } else if (hh < 3) {
        g = c;
        b = xx;
      } else if (hh < 4) {
        g = xx;
        b = c;
      } else if (hh < 5) {
        r = xx;
        b = c;
      } else {
        r = c;
        b = xx;
      }
      image.setPixelRgb(
        x,
        y,
        (r * 255).round(),
        (g * 255).round(),
        (b * 255).round(),
      );
    }
  }
  return image;
}

double _delta((double, double, double) a, (double, double, double) b) {
  final double dr = a.$1 - b.$1;
  final double dg = a.$2 - b.$2;
  final double db = a.$3 - b.$3;
  return math.sqrt(dr * dr + dg * dg + db * db);
}

void main() {
  test('neutral gray yields unity white-balance gains', () {
    final EnhanceAnalysis a = analyzeEnhance(_solid(128, 128, 128));
    expect(a.wbGainR, closeTo(1.0, 1e-12));
    expect(a.wbGainB, closeTo(1.0, 1e-12));
  });

  test('warm cast pushes the blue gain above 1', () {
    final EnhanceAnalysis a = analyzeEnhance(_solid(200, 150, 100));
    expect(a.wbGainB, greaterThan(1.0));
    expect(a.wbGainR, lessThan(1.0));
  });

  test('near-monochrome warm scene keeps gains at exactly 1', () {
    // Channel-mean spread (170-155)/255 ~= 0.059 < 0.08 guard.
    final EnhanceAnalysis a = analyzeEnhance(_solid(170, 160, 155));
    expect(a.wbGainR, equals(1.0));
    expect(a.wbGainB, equals(1.0));
  });

  test('saturated sunset orange is preserved by the hue guard', () {
    // sat = (255-20)/255 ~= 0.92 > 0.65, hue ~= 25 deg (warm sector).
    final EnhanceAnalysis a = analyzeEnhance(_solid(255, 120, 20));
    expect(a.wbGainR, equals(1.0));
    expect(a.wbGainB, equals(1.0));
  });

  test('saturated red neon is preserved by the hue guard', () {
    final EnhanceAnalysis a = analyzeEnhance(_solid(230, 30, 30));
    expect(a.wbGainR, equals(1.0));
    expect(a.wbGainB, equals(1.0));
  });

  test('saturated cool cast is still corrected (warm sector only)', () {
    // hue ~= 227 deg — outside the warm sector, so gray-world applies.
    final EnhanceAnalysis a = analyzeEnhance(_solid(30, 80, 255));
    expect(a.wbGainR, greaterThan(1.0));
  });

  test('levels tighten around low-contrast content', () {
    final EnhanceAnalysis a = analyzeEnhance(_lowContrastRamp());
    expect(a.blackPt, greaterThan(0.05));
    expect(a.whitePt, lessThan(0.95));
    expect(a.blackPt, inInclusiveRange(0.30, 0.42));
    expect(a.whitePt, inInclusiveRange(0.50, 0.63));
    expect(a.whitePt - a.blackPt, greaterThanOrEqualTo(0.19));
  });

  test('strength 0 is bit-exact identity on buffers', () {
    const int w = 8;
    const int h = 8;
    final Float32List rgb = Float32List(w * h * 3);
    for (int i = 0; i < rgb.length; i++) {
      rgb[i] = ((i * 37 + 11) % 251) / 255.0;
    }
    final Float32List before = Float32List.fromList(rgb);
    const EnhanceAnalysis warm = EnhanceAnalysis(
      wbGainR: 0.75,
      wbGainB: 1.33,
      blackPt: 0.1,
      whitePt: 0.9,
      dehaze: 0.5,
      hazeColor: (0.6, 0.62, 0.65),
    );
    applyEnhanceToBuffers(rgb, w, h, warm, 0.0);
    for (int i = 0; i < rgb.length; i++) {
      expect(rgb[i], equals(before[i]), reason: 'float $i drifted');
    }
  });

  test('gray veil reports dehaze, saturated wheel reports ~0', () {
    final EnhanceAnalysis hazy = analyzeEnhance(_solid(150, 152, 155));
    expect(hazy.dehaze, greaterThan(0.2));

    final EnhanceAnalysis clean = analyzeEnhance(_saturatedWheel());
    expect(clean.dehaze, lessThan(0.05));
  });

  test('EnhanceAnalysis.none is identity at full strength', () {
    const samples = [
      (0.72, 0.52, 0.40),
      (0.10, 0.20, 0.90),
      (0.0, 0.0, 0.0),
      (1.0, 1.0, 1.0),
    ];
    for (final s in samples) {
      final (double, double, double) out = applyEnhancePixel(
        s.$1,
        s.$2,
        s.$3,
        EnhanceAnalysis.none,
        1.0,
      );
      expect(out.$1, closeTo(s.$1, 1e-12));
      expect(out.$2, closeTo(s.$2, 1e-12));
      expect(out.$3, closeTo(s.$3, 1e-12));
    }
  });

  test('skin pixel moves less than background at the same strength', () {
    const EnhanceAnalysis a = EnhanceAnalysis(
      blackPt: 0.2,
      whitePt: 0.8,
      dehaze: 0.5,
      hazeColor: (0.6, 0.62, 0.65),
    );
    const skin = (0.72, 0.52, 0.40);
    const bg = (0.35, 0.50, 0.62);

    // Sanity: the test pixels sit on opposite sides of the mask.
    expect(enhanceSkinMask(skin.$1, skin.$2, skin.$3), greaterThan(0.9));
    expect(enhanceSkinMask(bg.$1, bg.$2, bg.$3), lessThan(0.1));

    final double skinDelta = _delta(
      skin,
      applyEnhancePixel(skin.$1, skin.$2, skin.$3, a, 1.0),
    );
    final double bgDelta = _delta(
      bg,
      applyEnhancePixel(bg.$1, bg.$2, bg.$3, a, 1.0),
    );
    expect(bgDelta, greaterThan(0.05));
    expect(skinDelta, lessThan(bgDelta * 0.7));
  });

  test('value semantics: ==, hashCode, none', () {
    const a = EnhanceAnalysis(wbGainR: 1.1, dehaze: 0.3);
    const b = EnhanceAnalysis(wbGainR: 1.1, dehaze: 0.3);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(EnhanceAnalysis.none, equals(const EnhanceAnalysis()));
    expect(a, isNot(equals(EnhanceAnalysis.none)));
  });
}
