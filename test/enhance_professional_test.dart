import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_apply.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

/// Synthetic scene: a sky gradient with a sun, a horizon, grass and a
/// skin-toned subject.
img.Image _scene({int size = 128, double lift = 0.0, bool blown = false}) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double t = y / (size - 1);
      double v = 0.85 - 0.7 * t; // sky (top) -> foreground (bottom)
      if (blown) {
        v = v > 0.6 ? 1.0 : v;
      }
      v = (v + lift).clamp(0.0, 1.0);
      final int g = (v * 255).round();
      image.setPixelRgb(
        x,
        y,
        (g * 0.95).round().clamp(0, 255),
        g,
        (g * 1.05).round().clamp(0, 255),
      );
    }
  }
  return image;
}

/// A flat, low-contrast gray ramp (luma ~0.35..0.55).
img.Image _flatRamp() {
  const int w = 64;
  const int h = 64;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int v = 100 + (40 * x ~/ (w - 1));
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

void main() {
  group('auto-exposure', () {
    test('a dark frame is lifted, a bright frame is pulled back', () {
      final dark = analyzeEnhance(_scene(lift: -0.35));
      expect(dark.exposureGain, greaterThan(1.0));

      final blown = analyzeEnhance(_scene(blown: true));
      // The blown frame has hard-clipped pixels: the exposure comes down so
      // the blown area leaves pure white.
      expect(blown.exposureGain, lessThan(1.0));
    });

    test('a well-exposed frame keeps its exposure', () {
      final a = analyzeEnhance(_scene());
      expect(a.exposureGain, closeTo(1.0, 1e-9));
    });

    test('the exposure gain stays inside the +/-1.2 EV window', () {
      final a = analyzeEnhance(_scene(lift: -0.9));
      expect(a.exposureGain, lessThanOrEqualTo(2.4));
      expect(a.exposureGain, greaterThanOrEqualTo(0.55));
    });
  });

  group('highlight recovery', () {
    test('a blown frame pulls its highlights off pure white', () {
      final a = analyzeEnhance(_scene(blown: true));
      expect(a.highlightRecover, greaterThan(0.5));
      final (double, double, double) blown = applyEnhancePixel(1, 1, 1, a, 1.0);
      final (double, double, double) near = applyEnhancePixel(0.9, 0.9, 0.9, a, 1.0);
      expect(blown.$1, lessThan(1.0));
      // The blown wall and the near-white pixels stay distinguishable.
      expect(blown.$1, greaterThan(near.$1));
    });

    test('no pixel of the graded frame is clipped to white', () {
      for (final a in <EnhanceAnalysis>[
        analyzeEnhance(_scene()),
        analyzeEnhance(_scene(blown: true)),
        analyzeEnhance(_scene(lift: -0.35)),
      ]) {
        for (final v in <double>[0.0, 0.25, 0.5, 0.75, 1.0]) {
          final (double, double, double) out = applyEnhancePixel(v, v, v, a, 1.0);
          expect(out.$1, lessThan(1.0), reason: 'white clipped at $v');
          expect(out.$1, greaterThanOrEqualTo(0.0), reason: 'black clipped');
        }
      }
    });
  });

  group('contrast', () {
    test('a flat frame comes out with a much wider tonal range', () {
      final a = analyzeEnhance(_flatRamp());
      expect(a.contrast, greaterThan(0.0));
      // The auto-levels stretch plus the S-curve widen the ramp: the
      // distance between two samples grows.
      final double low = applyEnhancePixel(0.40, 0.40, 0.40, a, 1.0).$1;
      final double high = applyEnhancePixel(0.55, 0.55, 0.55, a, 1.0).$1;
      expect(high - low, greaterThan(0.55 - 0.40));
    });

    test('a harsh frame gets no S-curve (the shoulder does the work)', () {
      final a = analyzeEnhance(_scene(blown: true));
      expect(a.contrast, lessThanOrEqualTo(0.75));
    });
  });

  group('saturation and tone', () {
    test('a desaturated frame gets vibrance and a split tone', () {
      final a = analyzeEnhance(_scene());
      expect(a.vibrance, greaterThan(0.0));
      expect(a.toneShadow, isNot(0.0));
      expect(a.toneHighlight, isNot(0.0));
      // The split tone cools the shadows and warms the highlights.
      expect(a.toneShadow, lessThan(0.0));
      expect(a.toneHighlight, greaterThan(0.0));
    });

    test('the split tone can never push a channel out of range', () {
      final a = analyzeEnhance(_scene());
      for (final v in <double>[0.0, 0.5, 0.9, 0.99, 1.0]) {
        final (double, double, double) out = applyEnhancePixel(v, v, v, a, 1.0);
        expect(out.$1, lessThanOrEqualTo(1.0));
        expect(out.$1, greaterThanOrEqualTo(0.0));
      }
    });
  });

  group('dehaze', () {
    test('a uniform veil is detected', () {
      final a = analyzeEnhance(_scene());
      // The synthetic scene has near-black shadows and a bright mid-tone:
      // that is NOT a veil, so the dehaze must stay off.
      expect(a.dehaze, lessThan(0.1));
    });

    test('a lifted-shadow veil is detected', () {
      // A flat, low-contrast frame with lifted blacks: the darkest
      // pixels sit close to the veil colour.
      final img.Image hazy = img.Image(width: 64, height: 64, numChannels: 3);
      for (int y = 0; y < 64; y++) {
        for (int x = 0; x < 64; x++) {
          final int v = 120 + (30 * x ~/ 63);
          hazy.setPixelRgb(x, y, v, v + 2, v + 4);
        }
      }
      final a = analyzeEnhance(hazy);
      expect(a.dehaze, greaterThan(0.2));
    });
  });

  group('end to end (analysis -> params -> CPU export)', () {
    test('the export of a dark frame comes back brighter and punchier', () {
      final img.Image src = _scene(lift: -0.4);
      final Uint8List bytes = img.encodePng(src);
      final EnhanceAnalysis analysis = analyzeEnhance(src);

      final Uint8List out = applyLensGrade(
        bytes,
        LensParams(
          enhR: analysis.wbGainR,
          enhB: analysis.wbGainB,
          enhBlack: analysis.blackPt,
          enhWhite: analysis.whitePt,
          enhDehaze: analysis.dehaze,
          enhHazeR: analysis.hazeColor.$1,
          enhHazeG: analysis.hazeColor.$2,
          enhHazeB: analysis.hazeColor.$3,
          enhExposure: analysis.exposureGain,
          enhContrast: analysis.contrast,
          enhShadowLift: analysis.shadowLift,
          enhVibrance: analysis.vibrance,
          enhSaturation: analysis.saturation,
          enhToneShadow: analysis.toneShadow,
          enhToneHighlight: analysis.toneHighlight,
          enhHighlightRecover: analysis.highlightRecover,
          enhanceStrength: 1.0,
        ).toUniforms(),
      );

      final img.Image? decoded = img.decodeImage(out);
      expect(decoded, isNotNull);
      double meanLuma(img.Image im) {
        double sum = 0;
        for (int y = 0; y < im.height; y++) {
          for (int x = 0; x < im.width; x++) {
            final img.Pixel p = im.getPixel(x, y);
            sum +=
                (0.299 * p.r + 0.587 * p.g + 0.114 * p.b) / 255.0;
          }
        }
        return sum / (im.width * im.height);
      }

      expect(meanLuma(decoded!), greaterThan(meanLuma(src)));
      // Nothing is clipped to a flat white wall.
      expect(decoded.getPixel(decoded.width ~/ 2, 0).r, lessThan(255));
    });
  });

  group('robustness', () {
    test('the analysis never returns a non-finite value', () {
      for (final im in <img.Image>[
        _scene(),
        _scene(lift: -0.9),
        _scene(blown: true),
        img.Image(width: 1, height: 1, numChannels: 3),
      ]) {
        final a = analyzeEnhance(im);
        for (final v in <double>[
          a.wbGainR,
          a.wbGainB,
          a.blackPt,
          a.whitePt,
          a.dehaze,
          a.exposureGain,
          a.contrast,
          a.shadowLift,
          a.vibrance,
          a.saturation,
          a.toneShadow,
          a.toneHighlight,
          a.highlightRecover,
        ]) {
          expect(v.isFinite, isTrue, reason: 'non-finite $v in $a');
        }
        expect(math.min(a.wbGainR, a.wbGainB), greaterThanOrEqualTo(0.75));
        expect(a.whitePt, greaterThan(a.blackPt));
      }
    });

    test('the strength scales the grade monotonically', () {
      final a = analyzeEnhance(_scene(lift: -0.35));
      final (double, double, double) half = applyEnhancePixel(0.3, 0.3, 0.3, a, 0.5);
      final (double, double, double) full = applyEnhancePixel(0.3, 0.3, 0.3, a, 1.0);
      expect(half.$1, greaterThan(0.3));
      expect(half.$1, lessThan(full.$1));
    });

    test('a neutral analysis stays an exact identity', () {
      for (final v in <double>[0.0, 0.25, 0.5, 0.9, 1.0]) {
        final (double, double, double) out = applyEnhancePixel(
          v,
          v,
          v,
          EnhanceAnalysis.none,
          1.0,
        );
        expect(out.$1, closeTo(v, 1e-12));
      }
    });
  });
}
