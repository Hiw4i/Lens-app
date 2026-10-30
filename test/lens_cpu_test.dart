import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

/// Smooth 32x32 gradient: no sharp edges, so a JPEG q95 round-trip stays
/// within a tight per-channel tolerance.
img.Image _gradientImage() {
  final image = img.Image(width: 32, height: 32, numChannels: 3);
  for (int y = 0; y < 32; y++) {
    for (int x = 0; x < 32; x++) {
      image.setPixelRgb(x, y, (x * 255 ~/ 31), (y * 255 ~/ 31), 128);
    }
  }
  return image;
}

img.Image _solidImage(int v) {
  final image = img.Image(width: 32, height: 32, numChannels: 3);
  for (int y = 0; y < 32; y++) {
    for (int x = 0; x < 32; x++) {
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// 64x64 band-limited TEXTURE: mid grey plus a smooth sine product of
/// amplitude 0.08 (the same shape the shared module is tested with). Its
/// energy sits in the band a guided filter treats as detail, NOT at edges,
/// so it is the image where a structure control must do something.
img.Image _textureImage() {
  final image = img.Image(width: 64, height: 64, numChannels: 3);
  for (int y = 0; y < 64; y++) {
    for (int x = 0; x < 64; x++) {
      final int v =
          ((0.5 + 0.08 * math.sin(0.7 * x) * math.sin(0.5 * y)) * 255.0)
              .round()
              .clamp(0, 255);
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// 64x64 image with ONE hard vertical edge (0.25 -> 0.75, i.e. 64 -> 191 in
/// 8-bit units, a 127.5/255 step). The guided filter must keep that step in
/// the base, so structure must NOT amplify it.
img.Image _hardEdgeImage() {
  final image = img.Image(width: 64, height: 64, numChannels: 3);
  for (int y = 0; y < 64; y++) {
    for (int x = 0; x < 64; x++) {
      final int v = x < 32 ? 64 : 191;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

double _meanLuma(img.Image image) {
  double acc = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel p = image.getPixel(x, y);
      acc += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    }
  }
  return acc / (image.width * image.height);
}

/// Standard deviation of the luma around its own mean: the local-contrast
/// budget of a zero-mean texture. A multiplicative structure stage scales
/// it by the stage's multiplier, so it is the direct "did local contrast
/// grow or shrink" probe.
double _lumaStd(img.Image image) {
  final double mean = _meanLuma(image);
  double acc = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel p = image.getPixel(x, y);
      final double luma = 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      acc += (luma - mean) * (luma - mean);
    }
  }
  return math.sqrt(acc / (image.width * image.height));
}

img.Image _decode(Uint8List bytes) {
  final img.Image? decoded = img.decodeImage(bytes);
  expect(decoded, isNotNull);
  return decoded!;
}

void main() {
  test('identity grade round-trips within JPG tolerance', () {
    final img.Image src = _gradientImage();
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

  test('exposure +1 stop increases mean luma', () {
    final Uint8List srcBytes = img.encodePng(_solidImage(100));

    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(exposure: 1).toUniforms(),
    );
    final img.Image? decoded = img.decodeImage(out);
    expect(decoded, isNotNull);

    final double before = _meanLuma(_solidImage(100));
    final double after = _meanLuma(decoded!);
    expect(after, greaterThan(before + 10));
  });

  test('structure 0 is byte-identical to no structure', () {
    final Uint8List srcBytes = img.encodePng(_textureImage());

    final img.Image flat = _decode(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
    );
    final img.Image zero = _decode(
      applyLensGrade(srcBytes, const LensParams(structure: 0).toUniforms()),
    );

    int changed = 0;
    for (int y = 0; y < flat.height; y++) {
      for (int x = 0; x < flat.width; x++) {
        final img.Pixel a = flat.getPixel(x, y);
        final img.Pixel b = zero.getPixel(x, y);
        if (a.r != b.r || a.g != b.g || a.b != b.b) changed++;
      }
    }
    expect(changed, 0, reason: 'structure 0 must be an exact no-op');
  });

  test('structure +100 increases the local contrast of a texture', () {
    final Uint8List srcBytes = img.encodePng(_textureImage());

    final img.Image flat = _decode(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
    );
    final img.Image structured = _decode(
      applyLensGrade(srcBytes, const LensParams(structure: 100).toUniforms()),
    );

    final double flatStd = _lumaStd(flat);
    final double structuredStd = _lumaStd(structured);
    expect(
      structuredStd,
      greaterThan(flatStd * 1.05),
      reason:
          'texture std should grow: flat $flatStd, structured $structuredStd',
    );
  });

  test('structure -100 decreases the local contrast of a texture', () {
    final Uint8List srcBytes = img.encodePng(_textureImage());

    final img.Image flat = _decode(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
    );
    final img.Image soft = _decode(
      applyLensGrade(srcBytes, const LensParams(structure: -100).toUniforms()),
    );

    final double flatStd = _lumaStd(flat);
    final double softStd = _lumaStd(soft);
    expect(
      softStd,
      lessThan(flatStd * 0.95),
      reason: 'texture std should shrink: flat $flatStd, soft $softStd',
    );
  });

  test('structure does not boost hard edges (it is not sharpening)', () {
    final Uint8List srcBytes = img.encodePng(_hardEdgeImage());

    final img.Image flat = _decode(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
    );
    final img.Image structured = _decode(
      applyLensGrade(srcBytes, const LensParams(structure: 100).toUniforms()),
    );

    // The source step is 0.25 -> 0.75 = 127.5/255 in luma units.
    const double step = 127.5;
    double sumAbs = 0;
    double maxAbs = 0;
    for (int y = 0; y < flat.height; y++) {
      for (int x = 0; x < flat.width; x++) {
        final img.Pixel a = flat.getPixel(x, y);
        final img.Pixel b = structured.getPixel(x, y);
        final double lumaA = 0.299 * a.r + 0.587 * a.g + 0.114 * a.b;
        final double lumaB = 0.299 * b.r + 0.587 * b.g + 0.114 * b.b;
        final double d = (lumaB - lumaA).abs();
        sumAbs += d;
        if (d > maxAbs) maxAbs = d;
      }
    }
    final double meanAbs = sumAbs / (flat.width * flat.height);

    // R5: the guided filter keeps the edge in the base, so the stage barely
    // touches an edge-only frame at all. The frame-mean change is about
    // 1 LSB; the strongest single pixel moves far less than a quarter of
    // the step (no sharpening halo).
    expect(
      meanAbs,
      lessThan(3.0),
      reason: 'frame-mean |structured - flat| should stay ~1 LSB: $meanAbs',
    );
    expect(
      maxAbs,
      lessThan(0.25 * step),
      reason: 'no per-pixel change above 25% of the step: $maxAbs',
    );

    // ... and the edge is still there, undiminished.
    expect(
      _halfMeanLuma(structured, 32, 64) - _halfMeanLuma(structured, 0, 32),
      greaterThan(0.9 * step),
    );
  });
}

/// Mean luma of the columns `[from, to)` of [image].
double _halfMeanLuma(img.Image image, int from, int to) {
  double acc = 0;
  int count = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = from; x < to; x++) {
      final img.Pixel p = image.getPixel(x, y);
      acc += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
      count++;
    }
  }
  return acc / count;
}
