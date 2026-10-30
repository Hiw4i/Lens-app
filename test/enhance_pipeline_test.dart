import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_apply.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_cache.dart';
import 'package:lens/features/imaging/export/export_service.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

img.Image _solid(int w, int h, int r, int g, int b) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

/// Smooth 32x32 gradient: no sharp edges, so a JPEG q95 round-trip stays
/// within a tight per-channel tolerance.
img.Image _gradient() {
  final image = img.Image(width: 32, height: 32, numChannels: 3);
  for (int y = 0; y < 32; y++) {
    for (int x = 0; x < 32; x++) {
      image.setPixelRgb(x, y, (x * 255 ~/ 31), (y * 255 ~/ 31), 128);
    }
  }
  return image;
}

void main() {
  test('toUniforms carries the Enhance block in slots 10..18', () {
    const p = LensParams(
      enhR: 1.2,
      enhB: 0.8,
      enhBlack: 0.1,
      enhWhite: 0.9,
      enhDehaze: 0.4,
      enhHazeR: 0.6,
      enhHazeG: 0.61,
      enhHazeB: 0.62,
      enhanceStrength: 0.7,
    );
    final u = p.toUniforms();
    expect(u.length, 56);
    expect(u.length, kLensUniformNames.length);
    expect(u.sublist(10, 19), [
      1.2, // enhR -> shader slot 12
      0.8, // enhB -> slot 13
      0.1, // enhBlack -> slot 14
      0.9, // enhWhite -> slot 15
      0.4, // enhDehaze -> slot 16
      0.6, // enhHazeR -> slot 17
      0.61, // enhHazeG -> slot 18
      0.62, // enhHazeB -> slot 19
      0.7, // enhanceStrength -> slot 20
    ]);
    expect(kLensUniformNames.sublist(10, 19), [
      'enhR',
      'enhB',
      'enhBlack',
      'enhWhite',
      'enhDehaze',
      'enhHazeR',
      'enhHazeG',
      'enhHazeB',
      'enhanceStrength',
    ]);
  });

  test('identity params are enhance-neutral (stage skipped)', () {
    const p = LensParams.identity;
    expect(p.enhR, 1.0);
    expect(p.enhB, 1.0);
    expect(p.enhBlack, 0.0);
    expect(p.enhWhite, 1.0);
    expect(p.enhDehaze, 0.0);
    expect(p.enhanceStrength, 0.0);
    // Neutral at full strength is also identity (mirrors the shader,
    // where a 0 mix weight is a no-op without branching).
    const samples = [(0.72, 0.52, 0.40), (0.10, 0.20, 0.90)];
    for (final s in samples) {
      final out = applyEnhancePixel(
        s.$1,
        s.$2,
        s.$3,
        const EnhanceAnalysis(
          wbGainR: 1.0,
          wbGainB: 1.0,
          blackPt: 0.0,
          whitePt: 1.0,
          dehaze: 0.0,
        ),
        1.0,
      );
      expect(out.$1, closeTo(s.$1, 1e-12));
      expect(out.$2, closeTo(s.$2, 1e-12));
      expect(out.$3, closeTo(s.$3, 1e-12));
    }
  });

  test('identity 44-slot grade round-trips within JPG tolerance', () {
    final src = _gradient();
    final Uint8List srcBytes = img.encodePng(src);
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams().toUniforms(),
    );
    final img.Image? decoded = img.decodeImage(out);
    expect(decoded, isNotNull);
    expect(decoded!.width, src.width);
    expect(decoded.height, src.height);
    for (int y = 0; y < src.height; y++) {
      for (int x = 0; x < src.width; x++) {
        final img.Pixel a = src.getPixel(x, y);
        final img.Pixel b = decoded.getPixel(x, y);
        expect(
          (b.r - a.r).abs(),
          lessThanOrEqualTo(3),
          reason: 'R drift at ($x,$y)',
        );
        expect(
          (b.g - a.g).abs(),
          lessThanOrEqualTo(3),
          reason: 'G drift at ($x,$y)',
        );
        expect(
          (b.b - a.b).abs(),
          lessThanOrEqualTo(3),
          reason: 'B drift at ($x,$y)',
        );
      }
    }
  });

  test('CPU enhance WB matches applyEnhancePixel', () {
    // Mid-gray solid: WB-only enhance (levels neutral, dehaze 0) so the
    // expected value is closed-form: r * mix(1, gainR, 1).
    final Uint8List srcBytes = img.encodePng(_solid(16, 16, 128, 128, 128));
    const analysis = EnhanceAnalysis(wbGainR: 1.2, wbGainB: 0.8);
    final (double er, double eg, double eb) = applyEnhancePixel(
      128 / 255,
      128 / 255,
      128 / 255,
      analysis,
      1.0,
    );

    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(enhR: 1.2, enhB: 0.8, enhanceStrength: 1.0).toUniforms(),
    );
    final img.Image? decoded = img.decodeImage(out);
    expect(decoded, isNotNull);
    final img.Pixel p = decoded!.getPixel(8, 8);
    // JPEG q95 on a flat field: ±4 covers the codec, the grade itself is
    // exact (checked against the shared helper above).
    expect(p.r, closeTo(er * 255, 4.0));
    expect(p.g, closeTo(eg * 255, 4.0));
    expect(p.b, closeTo(eb * 255, 4.0));
    // And the grade visibly moved red up / blue down vs the source.
    expect(p.r, greaterThan(128 + 10));
    expect(p.b, lessThan(128 - 10));
  });

  test('legacy 10-slot vector skips enhance (no slots 10..18)', () {
    final Uint8List srcBytes = img.encodePng(_solid(16, 16, 128, 128, 128));
    // First 10 of an enhance-active vector: had the CPU read enhance
    // from the wrong indices, this WB would leak through.
    final legacy10 = const LensParams(
      enhR: 1.2,
      enhB: 0.8,
      enhanceStrength: 1.0,
    ).toUniforms().sublist(0, 10);
    final img.Image? decoded = img.decodeImage(
      applyLensGrade(srcBytes, legacy10),
    );
    expect(decoded, isNotNull);
    final img.Pixel p = decoded!.getPixel(8, 8);
    expect((p.r - 128).abs(), lessThanOrEqualTo(4));
    expect((p.g - 128).abs(), lessThanOrEqualTo(4));
    expect((p.b - 128).abs(), lessThanOrEqualTo(4));
  });

  test('ExportService.export applies enhance end to end', () async {
    final Uint8List srcBytes = img.encodePng(_solid(16, 16, 128, 128, 128));
    final Uint8List out = await ExportService.export(
      srcBytes: srcBytes,
      params: const LensParams(enhB: 1.3, enhanceStrength: 1.0),
    );
    final img.Image? decoded = img.decodeImage(out);
    expect(decoded, isNotNull);
    expect(decoded!.width, 16);
    expect(decoded.height, 16);
    final img.Pixel p = decoded.getPixel(8, 8);
    // Blue gain 1.3 at full strength on mid-gray: clearly lifted, and the
    // green anchor untouched (within JPG tolerance).
    expect(p.b, greaterThan(128 + 10));
    expect((p.g - 128).abs(), lessThanOrEqualTo(4));
  });

  test('LensParams ==/copyWith cover the Enhance fields', () {
    const a = LensParams(enhR: 1.1, enhanceStrength: 0.5);
    const b = LensParams(enhR: 1.1, enhanceStrength: 0.5);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(LensParams.identity)));
    expect(LensParams.identity.copyWith(enhDehaze: 0.3).enhDehaze, 0.3);
    expect(
      a.copyWith(enhanceStrength: 0.0),
      equals(const LensParams(enhR: 1.1)),
    );
  });

  test('EnhanceCache miss degrades to none, empty prewarm never throws', () {
    final Uint8List unknown = Uint8List.fromList(<int>[1, 2, 3, 4, 5, 6, 7, 8]);
    expect(EnhanceCache.get(unknown), isNull);
    expect(EnhanceCache.getOrNone(unknown), equals(EnhanceAnalysis.none));
    // Must return void synchronously without throwing.
    EnhanceCache.prewarm(Uint8List(0));
    EnhanceCache.prewarm(unknown);
    expect(EnhanceCache.getOrNone(Uint8List(0)), equals(EnhanceAnalysis.none));
  });

  test('EnhanceCache.prewarm warms a real photo in the background', () async {
    final Uint8List png = img.encodePng(_solid(32, 32, 200, 150, 100));
    expect(EnhanceCache.get(png), isNull);
    EnhanceCache.prewarm(png);
    EnhanceAnalysis? hit;
    for (int i = 0; i < 100 && hit == null; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 100));
      hit = EnhanceCache.get(png);
    }
    expect(hit, isNotNull);
    // Warm cast: blue gain must exceed 1 (same estimator as 3.1).
    expect(hit!.wbGainB, greaterThan(1.0));
  });
}
