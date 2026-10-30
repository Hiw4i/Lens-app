import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/imaging/export/export_service.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

/// 1px vertical stripes: a blur with radius >= 2 averages neighboring
/// columns toward mid-gray, so blurred background pixels differ from raw by
/// ~60+ while sharp (mask = 1) pixels survive the JPEG q95 round-trip
/// within a few LSBs. A flat solid would be a blur fixed point and prove
/// nothing — hence stripes, not solids.
img.Image _stripes(int size) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final int v = x.isEven ? 0 : 255;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// Hard disc mask: 1 within [radius] of ([cx], [cy]) in uv, 0 outside.
Float32List _discMask(int size, double cx, double cy, double radius) {
  final Float32List mask = Float32List(size * size);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double dx = (x + 0.5) / size - cx;
      final double dy = (y + 0.5) / size - cy;
      mask[y * size + x] = math.sqrt(dx * dx + dy * dy) <= radius ? 1.0 : 0.0;
    }
  }
  return mask;
}

img.Image _decoded(Uint8List jpg) => img.decodeImage(jpg)!;

num _redAt(img.Image image, int x, int y) => image.getPixel(x, y).r;

void main() {
  const int size = 64;
  const active = LensParams(
    blurMode: 1,
    blurRadius: 0.05,
    blurFeather: 0.0,
    blurStrength: 1.0,
  );
  late Uint8List srcBytes;
  late Uint8List neutralBytes;
  late img.Image neutralImg;
  late Float32List mask;

  setUp(() {
    srcBytes = img.encodePng(_stripes(size));
    neutralBytes = applyLensGrade(srcBytes, const LensParams().toUniforms());
    neutralImg = _decoded(neutralBytes);
    // Subject disc: radius 16px around the center; corner (0,0) is deep
    // background (dist ~0.70 in uv), center (32,32) deep subject.
    mask = _discMask(size, 0.5, 0.5, 0.25);
  });

  test('blur keeps the subject sharp but blurs the background', () {
    final img.Image out = _decoded(
      applyLensGrade(srcBytes, active.toUniforms(), 0, null, mask),
    );
    // Center is fully masked (t = 1 => raw): identical math, JPEG noise.
    expect(
      (_redAt(out, 32, 32) - _redAt(neutralImg, 32, 32)).abs(),
      lessThanOrEqualTo(8),
    );
    // Corner is unmasked (t = 0 => blurred): 1px stripes average out.
    expect(
      (_redAt(out, 0, 0) - _redAt(neutralImg, 0, 0)).abs(),
      greaterThan(40),
    );
  });

  test('strength 0 is byte-identical to neutral', () {
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(
        blurMode: 1,
        blurRadius: 0.05,
        blurFeather: 0.0,
        blurStrength: 0.0,
      ).toUniforms(),
      0,
      null,
      mask,
    );
    expect(out, equals(neutralBytes));
  });

  test('mode 0 with garbage blur slots is byte-identical to neutral', () {
    final List<double> garbage = List<double>.of(
      const LensParams().toUniforms(),
    );
    // Keep [32] (mode) at 0, trash the rest of the blur block — including
    // a parked invert = 1 and full strength: off must stay off.
    garbage[33] = -5.0; // blurRadius (clamps to 0)
    garbage[34] = 99.0; // blurFeather
    garbage[35] = 5.0; // blurStrength (clamps to 1)
    garbage[36] = 1.0; // blurInvert (parked while off)
    expect(
      applyLensGrade(srcBytes, garbage, 0, null, mask),
      equals(neutralBytes),
    );
    // An inactive stage ignores even a malformed mask (mirrors mode-0
    // selective tolerating garbage slots) instead of throwing.
    expect(
      applyLensGrade(srcBytes, garbage, 0, null, Float32List(10)),
      equals(neutralBytes),
    );
  });

  test('mode != 0 without a mask is neutral (no white stub)', () {
    // Documents the deliberate CPU/shader split: the preview frag samples
    // a 1x1 white stub when no mask is bound (neutral too, except with
    // invert = 1), while the CPU treats a missing mask as "no subject".
    // A parked invert = 1 must NOT blur the whole frame on export.
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(
        blurMode: 1,
        blurRadius: 0.05,
        blurFeather: 0.0,
        blurStrength: 1.0,
        blurInvert: 1,
      ).toUniforms(),
    );
    expect(out, equals(neutralBytes));
  });

  test('radius 0 is neutral even with an active mask', () {
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(
        blurMode: 1,
        blurRadius: 0.0,
        blurStrength: 1.0,
      ).toUniforms(),
      0,
      null,
      mask,
    );
    expect(out, equals(neutralBytes));
  });

  test('legacy 32-slot vectors run blur-free like neutral 44', () {
    final List<double> full = const LensParams().toUniforms();
    expect(full.length, equals(56));
    final List<double> legacy32 = full.sublist(0, 32);
    expect(applyLensGrade(srcBytes, legacy32), equals(neutralBytes));
    // A 32-slot vector ignores even a present mask (no blur block to arm).
    expect(
      applyLensGrade(srcBytes, legacy32, 0, null, mask),
      equals(neutralBytes),
    );
  });

  test('non-square blur mask in an active stage throws', () {
    expect(
      () => applyLensGrade(
        srcBytes,
        active.toUniforms(),
        0,
        null,
        Float32List(10),
      ),
      throwsA(isA<LensCpuException>()),
    );
  });

  test('invert blurs the subject instead of the background', () {
    final img.Image out = _decoded(
      applyLensGrade(
        srcBytes,
        active.copyWith(blurInvert: 1).toUniforms(),
        0,
        null,
        mask,
      ),
    );
    // Center is now background (blurred stripes => mid-gray vs raw black).
    expect(
      (_redAt(out, 32, 32) - _redAt(neutralImg, 32, 32)).abs(),
      greaterThan(40),
    );
    // Corner is now subject (raw): identical math, JPEG noise.
    expect(
      (_redAt(out, 0, 0) - _redAt(neutralImg, 0, 0)).abs(),
      lessThanOrEqualTo(8),
    );
  });

  test('max-radius blur on 512x512 grades in under 3s (O(n) guard)', () {
    // Task 6.3b regression guard: the naive O(n*r) separable gaussian cost
    // ~774 mult-adds/px at the 64px clamp (measured ~2.6s of blur alone on
    // 1280x1280, tens of seconds extrapolated to 12MP). The 3x-box
    // approximation is O(n) per pass, so a 512x512 frame at max radius
    // grades in ~0.1s on desktop — 3s leaves wide margin for slow CI while
    // still catching any return to radius-scaled cost. The correctness
    // assert below keeps the guard honest: a build that skipped the blur
    // would be fast but must fail here.
    final Uint8List bigBytes = img.encodePng(_stripes(512));
    final img.Image bigNeutral = _decoded(
      applyLensGrade(bigBytes, const LensParams().toUniforms()),
    );
    final Float32List bg = Float32List(256 * 256); // all background
    final Stopwatch sw = Stopwatch()..start();
    final img.Image out = _decoded(
      applyLensGrade(bigBytes, active.toUniforms(), 0, null, bg),
    );
    sw.stop();
    expect(sw.elapsedMilliseconds, lessThan(3000));
    // 1px stripes under a real radius-26 blur average to mid-gray.
    expect(
      (_redAt(out, 0, 0) - _redAt(bigNeutral, 0, 0)).abs(),
      greaterThan(40),
    );
  });

  test('ExportService.export carries a 256 subject mask end to end', () async {
    // Production resolution mask over a small frame: sampling is by uv,
    // so geometry matches the 64-mask tests above.
    final Float32List mask256 = _discMask(256, 0.5, 0.5, 0.25);
    final Uint8List out = await ExportService.export(
      srcBytes: srcBytes,
      params: active,
      blurMask256: mask256,
    );
    final img.Image graded = _decoded(out);
    expect(
      (_redAt(graded, 32, 32) - _redAt(neutralImg, 32, 32)).abs(),
      lessThanOrEqualTo(10),
    );
    expect(
      (_redAt(graded, 0, 0) - _redAt(neutralImg, 0, 0)).abs(),
      greaterThan(40),
    );
  });
}
