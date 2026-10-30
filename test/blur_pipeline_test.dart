import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

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

void main() {
  test('toUniforms is 56 doubles with the blur block before rays', () {
    final u = const LensParams().toUniforms();
    expect(u.length, equals(56));
    expect(u.length, equals(kLensUniformNames.length));
    expect(
      kLensUniformNames.sublist(32, 37),
      equals(<String>[
        'blurMode',
        'blurRadius',
        'blurFeather',
        'blurStrength',
        'blurInvert',
      ]),
    );
  });

  test('identity is blur-neutral (mode off, strength 0)', () {
    const p = LensParams.identity;
    expect(p.blurMode, equals(0));
    expect(p.blurStrength, equals(0.0));
    expect(p.blurInvert, equals(0));
    final u = p.toUniforms();
    // toUniforms indices 32..36 -> shader float slots 34..38 (the Task 7.2
    // rays block follows in indices 37..43, so the slice is bounded).
    expect(
      u.sublist(32, 37),
      equals(<double>[
        0.0, // blurMode -> slot 34
        0.02, // blurRadius -> slot 35
        0.5, // blurFeather -> slot 36
        0.0, // blurStrength -> slot 37
        0.0, // blurInvert -> slot 38
      ]),
    );
  });

  test('slot order carries the blur fields', () {
    const p = LensParams(
      blurMode: 1,
      blurRadius: 0.04,
      blurFeather: 0.7,
      blurStrength: 0.8,
      blurInvert: 1,
    );
    final u = p.toUniforms();
    expect(u[32], equals(1.0)); // blurMode -> slot 34
    expect(u[33], equals(0.04)); // blurRadius -> slot 35
    expect(u[34], equals(0.7)); // blurFeather -> slot 36
    expect(u[35], equals(0.8)); // blurStrength -> slot 37
    expect(u[36], equals(1.0)); // blurInvert -> slot 38
  });

  test('blurStrength clamps into slot 37', () {
    expect(const LensParams(blurStrength: 5).toUniforms()[35], equals(1.0));
    expect(const LensParams(blurStrength: -2).toUniforms()[35], equals(0.0));
  });

  test('blurRadius clamps to 0..0.05 and blurFeather to 0..1', () {
    expect(const LensParams(blurRadius: 0.5).toUniforms()[33], equals(0.05));
    expect(const LensParams(blurRadius: -1).toUniforms()[33], equals(0.0));
    expect(const LensParams(blurFeather: 5).toUniforms()[34], equals(1.0));
    expect(const LensParams(blurFeather: -2).toUniforms()[34], equals(0.0));
  });

  test('blurMode accepts 0..2 and blurInvert accepts 0..1', () {
    // Non-const construction so the asserts fire at runtime (flutter test
    // runs with asserts enabled); const misuse would fail at compile time.
    expect(() => LensParams(blurMode: 3), throwsA(isA<AssertionError>()));
    expect(() => LensParams(blurMode: -1), throwsA(isA<AssertionError>()));
    expect(() => LensParams(blurInvert: 2), throwsA(isA<AssertionError>()));
    expect(const LensParams(blurMode: 2).blurMode, equals(2));
    expect(const LensParams(blurInvert: 1).blurInvert, equals(1));
  });

  test('LensParams ==/copyWith/hashCode cover the blur fields', () {
    const a = LensParams(blurMode: 1, blurStrength: 0.5, blurInvert: 1);
    const b = LensParams(blurMode: 1, blurStrength: 0.5, blurInvert: 1);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(LensParams.identity)));
    expect(LensParams.identity.copyWith(blurMode: 2).blurMode, equals(2));
    expect(
      a.copyWith(blurStrength: 0.0),
      equals(const LensParams(blurMode: 1, blurInvert: 1)),
    );
  });

  test('CPU without a blur mask is neutral (null mask, Task 6.3)', () {
    final Uint8List srcBytes = img.encodePng(_solid(16, 16, 128, 128, 128));
    final Uint8List neutral = applyLensGrade(
      srcBytes,
      const LensParams().toUniforms(),
    );
    // Blur-neutral 44-slot vector grades byte-identical to neutral.
    expect(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
      equals(neutral),
    );
    // Even a blur-ACTIVE vector (mode 1, full strength) grades identical
    // WITHOUT a mask: the CPU stage is neutral without a subject mask
    // (Task 6.3 null-mask rule — no white stub on export). Masked blur is
    // covered in blur_cpu_test.dart.
    // (The legacy 32-slot prefix stays accepted too.)
    final Uint8List active = applyLensGrade(
      srcBytes,
      const LensParams(blurMode: 1, blurStrength: 1.0).toUniforms(),
    );
    expect(active, equals(neutral));
    final List<double> legacy32 = const LensParams().toUniforms().sublist(
      0,
      32,
    );
    expect(legacy32.length, equals(32));
    expect(applyLensGrade(srcBytes, legacy32), equals(neutral));
  });
}
