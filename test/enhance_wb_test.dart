import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_apply.dart';

/// A sunset: a warm orange glow low in the frame, a cool violet sky
/// above it, a dark ground. The warmth is the SUBJECT.
img.Image _sunset() {
  const w = 120;
  const h = 80;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double t = y / (h - 1);
      int r, g, b;
      if (t < 0.45) {
        r = 255;
        g = (150 + 40 * t).round();
        b = (70 + 40 * t).round();
      } else if (t < 0.75) {
        r = (120 - 40 * t).round();
        g = (95 - 25 * t).round();
        b = (160 - 20 * t).round();
      } else {
        r = 45;
        g = 38;
        b = 30;
      }
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

/// A sheet of paper under a tungsten lamp: near-neutral, slightly warm,
/// filling the frame. The warmth is the LIGHT.
img.Image _paper() {
  const w = 120;
  const h = 80;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final double shade = 1.0 - 0.06 * (y / h);
      image.setPixelRgb(
        x,
        y,
        (245 * shade).round(),
        (222 * shade).round(),
        (188 * shade).round(),
      );
    }
  }
  return image;
}

/// A neutral grey card.
img.Image _greyCard() {
  const w = 60;
  const h = 60;
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      final int v = 120 + (x * 40 ~/ (w - 1));
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// Warmth of a colour: (r - b) / (r + b). Positive = warm.
double _warmth(double r, double g, double b) => (r - b) / (r + b);

void main() {
  group('white balance: cast or scene', () {
    test('a sunset is NOT cooled (the warmth is the subject)', () {
      final a = analyzeEnhance(_sunset());
      // The frame mixes warm and cool content, so the balance is left
      // exactly as it was shot.
      expect(a.wbGainR, closeTo(1.0, 1e-9));
      expect(a.wbGainB, closeTo(1.0, 1e-9));
    });

    test('a frame with warm AND cool colour is left alone', () {
      // A warm sky, a cool sky and a dark warm ground: the frame carries
      // colours of its own, so the dark patch must not hijack the balance
      // and cool the whole picture.
      final img.Image scene = img.Image(
        width: 120,
        height: 80,
        numChannels: 3,
      );
      for (int y = 0; y < 80; y++) {
        for (int x = 0; x < 120; x++) {
          final double t = y / 79;
          int r, g, b;
          if (t < 0.45) {
            r = 250;
            g = (150 + 60 * t).round();
            b = (70 + 50 * t).round();
          } else if (t < 0.72) {
            r = (96 - 15 * t).round();
            g = (81 - 5 * t).round();
            b = (148 - 3 * t).round();
          } else {
            r = 52;
            g = 60;
            b = 38;
          }
          scene.setPixelRgb(x, y, r, g, b);
        }
      }
      final a = analyzeEnhance(scene);
      expect(a.wbGainR, closeTo(1.0, 1e-9));
      expect(a.wbGainB, closeTo(1.0, 1e-9));
    });

    test('a tungsten-lit page IS cooled (the warmth is the light)', () {
      final a = analyzeEnhance(_paper());
      expect(a.wbGainB, greaterThan(1.0));
      expect(a.wbGainR, lessThan(1.0));
    });

    test('a neutral card is left alone', () {
      final a = analyzeEnhance(_greyCard());
      expect(a.wbGainR, closeTo(1.0, 1e-9));
      expect(a.wbGainB, closeTo(1.0, 1e-9));
    });

    test('the sunset keeps its warmth after the full grade', () {
      final img.Image src = _sunset();
      final EnhanceAnalysis a = analyzeEnhance(src);
      final img.Pixel p = src.getPixel(src.width ~/ 2, 10);
      final (double r, double g, double b) = applyEnhancePixel(
        p.r / 255,
        p.g / 255,
        p.b / 255,
        a,
        1.0,
      );
      // The warm band is still warm (and warmer than it was shot).
      expect(_warmth(r, g, b), greaterThan(0.5));
      expect(_warmth(r, g, b), greaterThan(_warmth(p.r / 255, p.g / 255, p.b / 255)));
    });

    test('the tungsten page loses its yellow cast after the grade', () {
      final img.Image src = _paper();
      final EnhanceAnalysis a = analyzeEnhance(src);
      final img.Pixel p = src.getPixel(src.width ~/ 2, src.height ~/ 2);
      final (double r, double g, double b) = applyEnhancePixel(
        p.r / 255,
        p.g / 255,
        p.b / 255,
        a,
        1.0,
      );
      // The paper is less yellow than it was: the blue came up.
      expect(b, greaterThan(p.b / 255));
      expect(_warmth(r, g, b), lessThan(_warmth(p.r / 255, p.g / 255, p.b / 255)));
    });
  });

  group('tint damping (the green/magenta axis)', () {
    /// Log-space tint of the analysis gains: `(ln R + ln B) / 2`, i.e. how
    /// far R and B are moved TOGETHER against the G anchor.
    double tintLog(EnhanceAnalysis a) =>
        0.5 * (math.log(a.wbGainR) + math.log(a.wbGainB));

    test('a pink sky keeps its magenta (tint is damped and capped)', () {
      // A uniform pink frame: saturated enough to stay out of the neutral
      // reference population, with no cool counterpart — exactly the case
      // where a raw estimator reads "magenta cast" and neutralises it.
      final img.Image pink = img.Image(width: 80, height: 80, numChannels: 3);
      for (int y = 0; y < 80; y++) {
        for (int x = 0; x < 80; x++) {
          pink.setPixelRgb(x, y, 200, 120, 190);
        }
      }
      final a = analyzeEnhance(pink);
      // The undamped estimate would be ~0.75 on both channels; the damping
      // plus the cap keeps the correction within 9%.
      expect(tintLog(a), greaterThanOrEqualTo(-kTintMaxLog - 1e-9));
      expect(a.wbGainR, greaterThan(0.90));
      expect(a.wbGainB, greaterThan(0.90));

      // And the pixel itself stays pink after the full grade.
      final (double r, double g, double b) = applyEnhancePixel(
        200 / 255,
        120 / 255,
        190 / 255,
        a,
        1.0,
      );
      expect(math.min(r, b) - g, greaterThan(0.1));
    });

    test('greenish skin is not pushed into magenta', () {
      // A warm face under greenish light: the frame mean is slightly green
      // (r + b below 2g). A full tint correction neutralises that mean, so
      // the face flips pink; the damped tint keeps it on the green side.
      final img.Image face = img.Image(width: 80, height: 80, numChannels: 3);
      for (int y = 0; y < 80; y++) {
        for (int x = 0; x < 80; x++) {
          face.setPixelRgb(x, y, 158, 153, 117);
        }
      }
      final a = analyzeEnhance(face);
      // The tint axis stays inside the damped band (a full estimate would
      // be noticeably larger).
      expect(tintLog(a), lessThanOrEqualTo(kTintMaxLog + 1e-9));
      expect(tintLog(a), greaterThan(0.0));

      const double before =
          (158 / 255 + 117 / 255) / 2 - 153 / 255;
      final (double r, double g, double b) = applyEnhancePixel(
        158 / 255,
        153 / 255,
        117 / 255,
        a,
        1.0,
      );
      final double after = (r + b) / 2 - g;
      // Greenish before, and still not magenta after (the skin did not
      // overshoot across neutral).
      expect(before, lessThan(0.0));
      expect(after, lessThan(0.02));
    });

    test('damping still lets the tungsten page go white', () {
      // Temperature is corrected as estimated: the document correction is
      // not weakened by the tint damping.
      final img.Image src = _paper();
      final EnhanceAnalysis a = analyzeEnhance(src);
      final img.Pixel p = src.getPixel(src.width ~/ 2, src.height ~/ 2);
      final (double r, double g, double b) = applyEnhancePixel(
        p.r / 255,
        p.g / 255,
        p.b / 255,
        a,
        1.0,
      );
      final double spread =
          math.max(r, math.max(g, b)) - math.min(r, math.min(g, b));
      // The page ends near-neutral, not as a yellow sheet.
      expect(spread, lessThan(0.08));
      expect(_warmth(r, g, b).abs(), lessThan(0.03));
    });
  });

  group('split tone follows the scene', () {
    test('a warm scene does not get cold shadows', () {
      final a = analyzeEnhance(_sunset());
      // The shadow tint is neutral-ish, not the cinematic cool push a cool
      // scene gets.
      expect(a.toneShadow, greaterThan(-0.15));
    });

    test('a cool scene keeps the cinematic cool shadows', () {
      final img.Image cool = img.Image(width: 60, height: 60, numChannels: 3);
      for (int y = 0; y < 60; y++) {
        for (int x = 0; x < 60; x++) {
          final int v = 120 + (x * 40 ~/ 59);
          cool.setPixelRgb(x, y, v - 25, v, v + 35);
        }
      }
      final a = analyzeEnhance(cool);
      expect(a.toneShadow, lessThan(-0.2));
    });
  });

  group('tone window', () {
    test('a high-key frame keeps its whites (a page stays a page)', () {
      // The frame is bright: crushing its blacks would grey the paper
      // down, so only the white point anchors it.
      final a = analyzeEnhance(_paper());
      expect(a.blackPt, 0.0);
      expect(a.whitePt, greaterThan(0.8));
      expect(a.exposureGain, closeTo(1.0, 1e-9));
      // And the paper ends up white, not grey.
      final (double r, double g, double b) = applyEnhancePixel(
        245 / 255,
        222 / 255,
        188 / 255,
        a,
        1.0,
      );
      expect(r, greaterThan(0.93));
      expect(g, greaterThan(0.93));
      expect(b, greaterThan(0.93));
    });

    test('a low-key frame is lifted and its blacks are crushed', () {
      // A dark gradient: the auto-exposure has to bring the midtone up.
      final img.Image dark = img.Image(width: 64, height: 64, numChannels: 3);
      for (int y = 0; y < 64; y++) {
        for (int x = 0; x < 64; x++) {
          final int v = (18 + (40 * y ~/ 63)).round();
          dark.setPixelRgb(x, y, v, v, v);
        }
      }
      final a = analyzeEnhance(dark);
      // The auto-levels window already brings the midtone up, so the
      // exposure gain stays at 1 (it only lifts frames the window cannot).
      expect(a.exposureGain, greaterThanOrEqualTo(1.0));
      final (double r, double g, double b) = applyEnhancePixel(
        30 / 255,
        30 / 255,
        30 / 255,
        a,
        1.0,
      );
      expect(r, greaterThan(30 / 255));
    });

    test('a very dark frame is lifted by the exposure gain', () {
      // So dark that the tone window cannot lift it on its own.
      final img.Image dark = img.Image(width: 64, height: 64, numChannels: 3);
      for (int y = 0; y < 64; y++) {
        for (int x = 0; x < 64; x++) {
          final int v = (4 + (14 * y ~/ 63)).round();
          dark.setPixelRgb(x, y, v, v, v);
        }
      }
      final a = analyzeEnhance(dark);
      expect(a.exposureGain, greaterThan(1.0));
    });
  });
}
