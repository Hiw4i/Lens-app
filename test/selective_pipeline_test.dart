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
  test('toUniforms is 56 doubles with the selective block before blur', () {
    final u = const LensParams().toUniforms();
    expect(u.length, equals(56));
    expect(u.length, equals(kLensUniformNames.length));
    expect(
      kLensUniformNames.sublist(19, 32),
      equals(<String>[
        'selMode',
        'selCx',
        'selCy',
        'selRadius',
        'selFeather',
        'selAngle',
        'selWidth',
        'selAspect',
        'selInvert',
        'selStrength',
        'selExp',
        'selCon',
        'selSat',
      ]),
    );
  });

  test('identity is selective-neutral (mode off, strength 0)', () {
    const p = LensParams.identity;
    expect(p.selMode, equals(0));
    expect(p.selStrength, equals(0.0));
    expect(p.selInvert, equals(0));
    expect(p.selExp, equals(0.0));
    expect(p.selCon, equals(0.0));
    expect(p.selSat, equals(0.0));
    final u = p.toUniforms();
    // toUniforms indices 19..31 -> shader float slots 21..33 (the Task 6.2
    // blur block follows in indices 32..36, so the slice is bounded).
    expect(
      u.sublist(19, 32),
      equals(<double>[
        0.0, // selMode -> slot 21
        0.5, // selCx -> slot 22
        0.5, // selCy -> slot 23
        0.35, // selRadius -> slot 24
        0.5, // selFeather -> slot 25
        90.0, // selAngle -> slot 26
        0.5, // selWidth -> slot 27
        1.0, // selAspect -> slot 28
        0.0, // selInvert -> slot 29
        0.0, // selStrength -> slot 30
        0.0, // selExp -> slot 31
        0.0, // selCon -> slot 32
        0.0, // selSat -> slot 33
      ]),
    );
  });

  test('slot order carries geometry, invert, and local grade', () {
    const p = LensParams(
      selMode: 1,
      selCx: 0.25,
      selCy: 0.75,
      selRadius: 0.2,
      selFeather: 0.3,
      selAngle: 45.0,
      selWidth: 0.4,
      selAspect: 1.78,
      selInvert: 1,
      selStrength: 0.8,
      selExp: 1.0,
      selCon: 0.2,
      selSat: -0.3,
    );
    final u = p.toUniforms();
    expect(u[19], equals(1.0)); // selMode -> slot 21
    expect(u[20], equals(0.25)); // selCx -> slot 22
    expect(u[21], equals(0.75)); // selCy -> slot 23
    expect(u[22], equals(0.2)); // selRadius -> slot 24
    expect(u[23], equals(0.3)); // selFeather -> slot 25
    expect(u[24], equals(45.0)); // selAngle -> slot 26
    expect(u[25], equals(0.4)); // selWidth -> slot 27
    expect(u[26], equals(1.78)); // selAspect -> slot 28
    expect(u[27], equals(1.0)); // selInvert -> slot 29
    expect(u[28], equals(0.8)); // selStrength -> slot 30
    expect(u[29], equals(1.0)); // selExp -> slot 31
    expect(u[30], equals(0.2)); // selCon -> slot 32
    expect(u[31], equals(-0.3)); // selSat -> slot 33
  });

  test('selStrength clamps into slot 30', () {
    expect(const LensParams(selStrength: 5).toUniforms()[28], equals(1.0));
    expect(const LensParams(selStrength: -2).toUniforms()[28], equals(0.0));
  });

  test('LensParams ==/copyWith/hashCode cover the selective fields', () {
    const a = LensParams(selMode: 2, selStrength: 0.5, selInvert: 1);
    const b = LensParams(selMode: 2, selStrength: 0.5, selInvert: 1);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(LensParams.identity)));
    expect(LensParams.identity.copyWith(selMode: 1).selMode, equals(1));
    expect(
      a.copyWith(selStrength: 0.0),
      equals(const LensParams(selMode: 2, selInvert: 1)),
    );
  });

  test('CPU accepts the 44-slot vector (selective applied since 4.3)', () {
    final Uint8List srcBytes = img.encodePng(_solid(16, 16, 128, 128, 128));
    final Uint8List neutral = applyLensGrade(
      srcBytes,
      const LensParams().toUniforms(),
    );
    // Selective-active vector must not throw and — since Task 4.3 applies
    // the stage after the LUT — must DIFFER from the selective-neutral
    // grade (default radial geometry covers the image center, selExp 1.0
    // doubles the luma there).
    final Uint8List selective = applyLensGrade(
      srcBytes,
      const LensParams(
        selMode: 1,
        selStrength: 1.0,
        selExp: 1.0,
        selCon: 0.5,
        selSat: 0.5,
      ).toUniforms(),
    );
    expect(selective, isNot(equals(neutral)));
    // ...while a selective-neutral 44-slot vector stays bit-identical.
    expect(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
      equals(neutral),
    );
    // Legacy 19-slot vectors (pre-4.2, enhance but no selective) still run.
    final legacy19 = const LensParams(enhanceStrength: 1.0)
        .toUniforms()
        .sublist(0, 19);
    expect(legacy19.length, equals(19));
    expect(applyLensGrade(srcBytes, legacy19), isNotEmpty);
  });
}
