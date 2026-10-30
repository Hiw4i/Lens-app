import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_apply.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

/// A grey checkerboard: local detail without any colour, so the only thing
/// a structure boost can change is the local contrast.
img.Image _checker({required int lo, required int hi, int size = 64}) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final int v = ((x ~/ 4) + (y ~/ 4)).isEven ? lo : hi;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// A flat colour fill.
img.Image _flat(int r, int g, int b, {int size = 32}) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

Uint8List _export(img.Image src, LensParams params) =>
    applyLensGrade(img.encodePng(src), params.toUniforms());

/// Peak-to-peak luma of one row, in 0..1.
double _rowContrast(img.Image image, int y) {
  int lo = 255;
  int hi = 0;
  for (int x = 0; x < image.width; x++) {
    final int v = image.getPixel(x, y).r.round();
    if (v < lo) lo = v;
    if (v > hi) hi = v;
  }
  return (hi - lo) / 255.0;
}

void main() {
  group('structure boost', () {
    test('a midtone texture gets more local contrast at full Enhance', () {
      final img.Image src = _checker(lo: 102, hi: 140);
      final img.Image off = img.decodeImage(
        _export(src, const LensParams()),
      )!;
      final img.Image on = img.decodeImage(
        _export(src, const LensParams(enhanceStrength: 1)),
      )!;
      final double base = _rowContrast(off, 32);
      final double boosted = _rowContrast(on, 32);
      expect(base, greaterThan(0.1));
      // Subtle: +12 slider units, not a double-dose of clarity.
      expect(boosted, greaterThan(base * 1.05));
      expect(boosted, lessThan(base * 1.8));
    });

    test('the boost is ADDED to the user slider, not a replacement', () {
      final img.Image src = _checker(lo: 102, hi: 140);
      final img.Image softened = img.decodeImage(
        _export(src, const LensParams(structure: -50)),
      )!;
      final img.Image softenedPlus = img.decodeImage(
        _export(src, const LensParams(structure: -50, enhanceStrength: 1)),
      )!;
      // The +0.12 boost offsets part of the user's -0.5, so the result is
      // less soft than the slider alone.
      expect(
        _rowContrast(softenedPlus, 32),
        greaterThan(_rowContrast(softened, 32)),
      );
    });

    test('the boost fades on near-white pixels instead of clipping', () {
      final img.Image mid = _checker(lo: 102, hi: 140);
      final img.Image bright = _checker(lo: 230, hi: 246);
      final img.Image midOff = img.decodeImage(
        _export(mid, const LensParams()),
      )!;
      final img.Image midOn = img.decodeImage(
        _export(mid, const LensParams(enhanceStrength: 1)),
      )!;
      final img.Image brightOff = img.decodeImage(
        _export(bright, const LensParams()),
      )!;
      final img.Image brightOn = img.decodeImage(
        _export(bright, const LensParams(enhanceStrength: 1)),
      )!;

      final double midGain =
          (_rowContrast(midOn, 32) - _rowContrast(midOff, 32)) /
          _rowContrast(midOff, 32);
      final double brightGain =
          (_rowContrast(brightOn, 32) - _rowContrast(brightOff, 32)) /
          _rowContrast(brightOff, 32);
      // Near white the tick is faded out: much less of the gain survives.
      expect(brightGain, lessThan(midGain * 0.5));

      // And no channel is pushed onto the hard 255 wall.
      for (int y = 0; y < brightOn.height; y++) {
        for (int x = 0; x < brightOn.width; x++) {
          final img.Pixel p = brightOn.getPixel(x, y);
          expect(p.r.round(), lessThan(255));
        }
      }
    });
  });

  group('built-in cinematic look', () {
    test('visible at full strength, exact identity at zero', () {
      const EnhanceAnalysis a = EnhanceAnalysis(look: kEnhanceLookStrength);
      final (double r, double g, double b) = applyEnhancePixel(
        0.30,
        0.42,
        0.55,
        a,
        1.0,
      );
      expect((r - 0.30).abs() + (g - 0.42).abs() + (b - 0.55).abs(),
          greaterThan(0.01));

      // Identity when the master strength is off...
      expect(
        applyEnhancePixel(0.30, 0.42, 0.55, a, 0.0),
        (0.30, 0.42, 0.55),
      );
      // ...and for the neutral analysis at full strength.
      expect(
        applyEnhancePixel(0.30, 0.42, 0.55, EnhanceAnalysis.none, 1.0),
        (0.30, 0.42, 0.55),
      );
    });

    test('it is the Cinematic look: cool shadows, warm highlights', () {
      const EnhanceAnalysis a = EnhanceAnalysis(look: kEnhanceLookStrength);
      final (double sr, double sg, double sb) = applyEnhancePixel(
        0.18,
        0.20,
        0.24,
        a,
        1.0,
      );
      // Shadows go teal (blue lifted more than red).
      expect(sb - sr, greaterThan(0.24 - 0.18));

      final (double hr, double hg, double hb) = applyEnhancePixel(
        0.70,
        0.66,
        0.58,
        a,
        1.0,
      );
      // Highlights warm up (red lifted more than blue).
      expect(hr - hb, greaterThan(0.70 - 0.58));
    });

    test('it fades out before pure white (headroom guard)', () {
      const EnhanceAnalysis a = EnhanceAnalysis(look: kEnhanceLookStrength);
      expect(applyEnhancePixel(1.0, 1.0, 1.0, a, 1.0), (1.0, 1.0, 1.0));
    });

    test('the look reaches the CPU export through LensParams.enhLook', () {
      final img.Image src = _flat(110, 130, 150);
      final img.Image off = img.decodeImage(
        _export(src, const LensParams()),
      )!;
      final img.Image on = img.decodeImage(
        _export(
          src,
          const LensParams(enhanceStrength: 1, enhLook: kEnhanceLookStrength),
        ),
      )!;
      final img.Pixel po = off.getPixel(16, 16);
      final img.Pixel pn = on.getPixel(16, 16);
      // A 30/100 teal-shadow mix visibly lifts the blue of a mid-tone.
      expect(pn.b.round(), greaterThan(po.b.round()));
    });

    test('a previous 55-slot vector still grades with Enhance (no look)', () {
      final img.Image src = _checker(lo: 102, hi: 140);
      final List<double> full = const LensParams(
        enhanceStrength: 1,
        enhLook: kEnhanceLookStrength,
      ).toUniforms();
      // Drop the appended look slot: the previous layout must keep every
      // earlier field, including the whole enhance block and tail.
      final Uint8List legacy = applyLensGrade(
        img.encodePng(src),
        full.sublist(0, 55),
      );
      final Uint8List noLook = applyLensGrade(
        img.encodePng(src),
        const LensParams(enhanceStrength: 1).toUniforms(),
      );
      expect(legacy, equals(noLook));
      // And the enhance block was not silently dropped: full strength
      // differs from the neutral vector.
      expect(
        legacy,
        isNot(equals(_export(src, const LensParams()))),
      );
    });

    test('an absent look leaves the export byte-identical', () {
      final img.Image src = _flat(110, 130, 150);
      expect(
        _export(src, const LensParams()),
        equals(_export(src, const LensParams(enhLook: 0, enhanceStrength: 0))),
      );
    });
  });
}
