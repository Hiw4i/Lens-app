import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/rays/rays_math.dart';

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
  test('toUniforms is 56 doubles with the rays block before the tail', () {
    final u = const LensParams().toUniforms();
    expect(u.length, equals(56));
    expect(u.length, equals(kLensUniformNames.length));
    expect(
      kLensUniformNames.sublist(37, 47),
      equals(<String>[
        'rayOn',
        'rayX',
        'rayY',
        'rayIntensity',
        'rayLength',
        'rayWarmth',
        'rayDensity',
        'rayMode',
        'rayAngle',
        'rayWidth',
      ]),
    );
    // The derived auto-grade tail of the Enhance stage is appended last,
    // so every historical prefix keeps its meaning.
    expect(
      kLensUniformNames.sublist(47),
      equals(<String>[
        'enhExposure',
        'enhContrast',
        'enhShadowLift',
        'enhVibrance',
        'enhSaturation',
        'enhToneShadow',
        'enhToneHighlight',
        'enhHighlightRecover',
        'enhLook',
      ]),
    );
  });

  test('identity is rays-neutral (gate off, intensity 0)', () {
    const p = LensParams.identity;
    expect(p.rayOn, equals(0));
    expect(p.rayIntensity, equals(0.0));
    final u = p.toUniforms();
    // toUniforms indices 37..46 -> shader float slots 39..48.
    expect(
      u.sublist(37, 47),
      equals(<double>[
        0.0, // rayOn -> slot 39
        0.5, // rayX -> slot 40
        0.2, // rayY -> slot 41
        0.0, // rayIntensity -> slot 42
        0.6, // rayLength -> slot 43
        0.7, // rayWarmth -> slot 44
        0.5, // rayDensity -> slot 45
        0.0, // rayMode -> slot 46
        0.0, // rayAngle -> slot 47
        1.0, // rayWidth -> slot 48
      ]),
    );
  });

  test('slot order carries the rays fields', () {
    const p = LensParams(
      rayOn: 1,
      rayX: 0.25,
      rayY: 0.75,
      rayIntensity: 0.8,
      rayLength: 0.4,
      rayWarmth: 0.3,
      rayDensity: 0.9,
    );
    final u = p.toUniforms();
    expect(u[37], equals(1.0)); // rayOn -> slot 39
    expect(u[38], equals(0.25)); // rayX -> slot 40
    expect(u[39], equals(0.75)); // rayY -> slot 41
    expect(u[40], equals(0.8)); // rayIntensity -> slot 42
    expect(u[41], equals(0.4)); // rayLength -> slot 43
    expect(u[42], equals(0.3)); // rayWarmth -> slot 44
    expect(u[43], equals(0.9)); // rayDensity -> slot 45
  });

  test('intensity/length/warmth/density clamp into 0..1', () {
    expect(const LensParams(rayIntensity: 5).toUniforms()[40], equals(1.0));
    expect(const LensParams(rayIntensity: -2).toUniforms()[40], equals(0.0));
    expect(const LensParams(rayLength: 2).toUniforms()[41], equals(1.0));
    expect(const LensParams(rayLength: -1).toUniforms()[41], equals(0.0));
    expect(const LensParams(rayWarmth: 9).toUniforms()[42], equals(1.0));
    expect(const LensParams(rayWarmth: -9).toUniforms()[42], equals(0.0));
    expect(const LensParams(rayDensity: 3).toUniforms()[43], equals(1.0));
    expect(const LensParams(rayDensity: -3).toUniforms()[43], equals(0.0));
  });

  test('source travels to slots 40..41, off-frame passes through', () {
    // In-frame sun maps exactly (uv 0..1, top-left like selective).
    final u = const LensParams(rayX: 0.25, rayY: 0.75).toUniforms();
    expect(u[38], equals(0.25)); // rayX -> slot 40
    expect(u[39], equals(0.75)); // rayY -> slot 41
    // Edges survive exactly too.
    final edges = const LensParams(rayX: 0.0, rayY: 1.0).toUniforms();
    expect(edges[38], equals(0.0));
    expect(edges[39], equals(1.0));
    // An off-frame sun is NOT clamped: the march direction stays valid
    // and the glow branch still shades by normalized distance.
    final outside = const LensParams(rayX: 1.4, rayY: -0.3).toUniforms();
    expect(outside[38], equals(1.4));
    expect(outside[39], equals(-0.3));
  });

  test('rayOn accepts 0..1 only', () {
    // Non-const construction so the asserts fire at runtime (flutter test
    // runs with asserts enabled); const misuse would fail at compile time.
    expect(() => LensParams(rayOn: 2), throwsA(isA<AssertionError>()));
    expect(() => LensParams(rayOn: -1), throwsA(isA<AssertionError>()));
    expect(const LensParams(rayOn: 1).rayOn, equals(1));
    expect(const LensParams(rayOn: 0).rayOn, equals(0));
  });

  test('LensParams ==/copyWith/hashCode cover the rays fields', () {
    const a = LensParams(rayOn: 1, rayX: 0.3, rayIntensity: 0.5);
    const b = LensParams(rayOn: 1, rayX: 0.3, rayIntensity: 0.5);
    expect(a, equals(b));
    expect(a.hashCode, equals(b.hashCode));
    expect(a, isNot(equals(LensParams.identity)));
    expect(LensParams.identity.copyWith(rayOn: 1).rayOn, equals(1));
    expect(
      a.copyWith(rayIntensity: 0.0),
      equals(const LensParams(rayOn: 1, rayX: 0.3)),
    );
  });

  test('LensParams rays defaults mirror RaysParams', () {
    // The preview block parks at the math-core defaults so Task 7.4 only
    // has to flip rayOn/intensity to arm an already-sane sun.
    const p = LensParams();
    expect(p.rayX, equals(const RaysParams().source.$1));
    expect(p.rayY, equals(const RaysParams().source.$2));
    expect(p.rayIntensity, equals(const RaysParams().intensity));
    expect(p.rayLength, equals(const RaysParams().length));
    expect(p.rayWarmth, equals(const RaysParams().warmth));
    expect(p.rayDensity, equals(const RaysParams().density));
  });

  test('rays-neutral 44-slot vector grades like its 32-slot prefix (CPU)', () {
    // The CPU export ignores the rays tail until Task 7.3 (preview-only
    // stage): a rays-neutral vector must grade byte-identical to the
    // legacy 32-slot form, same philosophy as the blur null-mask rule.
    final Uint8List srcBytes = img.encodePng(_solid(16, 16, 128, 128, 128));
    final Uint8List neutral = applyLensGrade(
      srcBytes,
      const LensParams().toUniforms(),
    );
    final List<double> legacy32 = const LensParams().toUniforms().sublist(
      0,
      32,
    );
    expect(legacy32.length, equals(32));
    expect(applyLensGrade(srcBytes, legacy32), equals(neutral));
  });
}
