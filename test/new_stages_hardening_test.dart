import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/blur/subject_mask.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/imaging/export/export_service.dart';
import 'package:lens/features/imaging/mask_manager.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/rays/rays_math.dart';
import 'package:lens/features/selective/mask_raster.dart';
import 'package:lens/features/selective/selective_mask.dart';

/// Hardening for the new stages (Selective 4 / Blur 6 / Rays 7):
/// cache collisions, parked-value neutrality, clamp discipline,
/// full-stack exports with everything armed.

Uint8List _png(int w, int h, int Function(int x, int y) gray) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      final v = gray(x, y).clamp(0, 255);
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return img.encodePng(image);
}

BrushStroke _dab(double x, double y) =>
    BrushStroke(points: [(x, y)], radius: 0.2, feather: 0.5);

void main() {
  group('mask manager cache', () {
    test('floatMaskImage rejects non-square', () {
      expect(MaskManager.floatMaskImage(Float32List(99), 10), isNull);
    });

    testWidgets(
      'repeat call hits the cache; LRU keeps four stroke keys apart',
      (tester) async {
        // MaskManager rasterises, PNG-encodes and decodes, and the codec
        // completes on the real event loop — which the fake-async zone
        // `testWidgets` installs never pumps. The whole body therefore runs
        // inside `runAsync`, not just the awaits: a future chain STARTED in
        // the fake zone stays bound to it and would hang all the same.
        await tester.runAsync(() async {
          MaskManager.clear();
          addTearDown(MaskManager.clear);
          List<BrushStroke> key(int i) => [_dab(0.1 * i, 0.9 - 0.1 * i)];

          final fa = MaskManager.maskImage(key(1));
          // Unchanged strokes must return the IDENTICAL future: that is what
          // stops a grade-only tick from re-rasterising the mask.
          expect(identical(MaskManager.maskImage(key(1)), fa), isTrue);
          expect(await fa, isNotNull);

          // A second consumer (the manual blur brush) must NOT evict the
          // selective one any more — both stay hot in the LRU.
          final fb = MaskManager.maskImage(key(2));
          expect(identical(fb, fa), isFalse);
          expect(identical(MaskManager.maskImage(key(1)), fa), isTrue);

          // Touch A so B is the least-recently used entry, then overflow.
          unawaited(MaskManager.maskImage(key(1))!);
          final fc = MaskManager.maskImage(key(3));
          final fd = MaskManager.maskImage(key(4));
          expect(await Future.wait([fb!, fc!, fd!]), isNotEmpty);
          unawaited(MaskManager.maskImage(key(5))!);
          expect(identical(MaskManager.maskImage(key(1)), fa), isTrue);
          expect(identical(MaskManager.maskImage(key(2)), fb), isFalse);
        });
      },
    );

    testWidgets(
      'floatMaskImage caches identical mask object and LRU keeps four',
      (tester) async {
        // Same reason as the test above: the codec completes on the real
        // event loop, so the chain is built inside `runAsync`.
        await tester.runAsync(() async {
          MaskManager.clear();
          addTearDown(MaskManager.clear);
          final a = Float32List(16 * 16);
          final b = Float32List(16 * 16);
          final c = Float32List(16 * 16);
          final d = Float32List(16 * 16);
          final e = Float32List(16 * 16);
          final fa = MaskManager.floatMaskImage(a, 16);
          expect(fa, isNotNull);
          // Same Float32List instance + same size must hit the cache, so the
          // preview's FutureBuilder keeps its snapshot across slider ticks.
          expect(identical(MaskManager.floatMaskImage(a, 16), fa), isTrue);
          expect(await fa, isNotNull);
          final fb = MaskManager.floatMaskImage(b, 16);
          final fc = MaskManager.floatMaskImage(c, 16);
          final fd = MaskManager.floatMaskImage(d, 16);
          expect(await Future.wait([fb!, fc!, fd!]), isNotEmpty);
          // Touch A, then overflow: B is the LRU entry and gets evicted.
          unawaited(MaskManager.floatMaskImage(a, 16)!);
          unawaited(MaskManager.floatMaskImage(e, 16)!);
          expect(identical(MaskManager.floatMaskImage(a, 16), fa), isTrue);
          expect(identical(MaskManager.floatMaskImage(b, 16), fb), isFalse);
        });
      },
    );
  });

  group('parked neutrality', () {
    test('all-off with parked values maps to neutral suffix', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      // Park values everywhere, then switch everything off.
      n.setSelectiveMode(SelectiveMode.radial);
      n.setSelectiveStrength(0);
      n.setBlurStrength(0);
      n.applyRaysOneTap();
      n.clearRays();
      final p = container.read(editorStateProvider).toLensParams();
      final u = p.toUniforms();
      expect(u.length, 56);
      // Selective block neutral: mode 0.
      expect(u[19], 0.0);
      // Blur block neutral: mode 0.
      expect(u[32], 0.0);
      // Rays block neutral: on 0.
      expect(u[37], 0.0);
    });

    test('selective geometry clamps to frame via granular setters', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.radial);
      n.setSelectiveCenter(99.0, -5.0);
      n.setSelectiveRadius(5.0);
      final g = container.read(editorStateProvider).selective.geometry;
      expect(g.center.$1, inInclusiveRange(0.0, 1.0));
      expect(g.center.$2, inInclusiveRange(0.0, 1.0));
      expect(g.radius, inInclusiveRange(0.0, 1.0));
    });

    test('rays source clamps to frame', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.applyRaysOneTap();
      n.setRaysSource(9.0, -9.0);
      final s = container.read(editorStateProvider).rays.source;
      expect(s.$1, inInclusiveRange(0.0, 1.0));
      expect(s.$2, inInclusiveRange(0.0, 1.0));
    });
  });

  group('mixed history', () {
    test('25 mixed pushes cap at 20, undo restores all stages', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      for (var i = 1; i <= 25; i++) {
        n.setExposure(i * 0.05);
      }
      n.setSelectiveMode(SelectiveMode.radial);
      n.setBlurStrength(60);
      n.applyRaysOneTap();
      expect(container.read(editorStateProvider).undoDepth, kHistoryLimit);
      // Walk back past the stage switches without throwing.
      for (var i = 0; i < 25; i++) {
        n.undo();
      }
      final back = container.read(editorStateProvider);
      expect(back.selective.isDefault, isTrue);
      expect(back.blur.isDefault, isTrue);
      expect(back.rays.isDefault, isTrue);
    });
  });

  group('selective math edges', () {
    test('brush analytic weight is 0 (raster only)', () {
      expect(
        selectiveWeight(
          0.5,
          0.5,
          const SelectiveGeometry(),
          SelectiveMode.brush,
        ),
        0.0,
      );
    });

    test('radial radius 0 keeps the exact center lit', () {
      const g = SelectiveGeometry(radius: 0.0, feather: 0.0);
      expect(selectiveWeight(0.5, 0.5, g, SelectiveMode.radial), 1.0);
      expect(selectiveWeight(0.9, 0.9, g, SelectiveMode.radial), 0.0);
    });

    test('linear width 0 stays finite off the line', () {
      const g = SelectiveGeometry(width: 0.0, feather: 0.0);
      final w = selectiveWeight(0.9, 0.1, g, SelectiveMode.linear);
      expect(w.isFinite, isTrue);
      expect(w, inInclusiveRange(0.0, 1.0));
    });

    test('full uv grid finite for every mode', () {
      const g = SelectiveGeometry();
      for (final mode in SelectiveMode.values) {
        for (var i = 0; i <= 10; i++) {
          final w = selectiveWeight(i / 10, 1.0 - i / 10, g, mode);
          expect(w.isFinite, isTrue, reason: '$mode @ $i');
          expect(w, inInclusiveRange(0.0, 1.0));
        }
      }
    });
  });

  group('full-stack exports', () {
    test('everything armed differs from neutral end-to-end', () async {
      // White disc subject on dark background with warm tint.
      final png = _png(48, 48, (x, y) {
        final dx = x - 24;
        final dy = y - 24;
        return dx * dx + dy * dy < 100 ? 230 : 25;
      });
      final neutral = await ExportService.export(
        srcBytes: png,
        params: const LensParams(),
      );
      // Selective radial grade + rays, no blur mask (neutral blur).
      final armed = await ExportService.export(
        srcBytes: png,
        params: const LensParams(
          selMode: 1,
          selRadius: 0.4,
          selFeather: 0.5,
          selStrength: 1.0,
          selExp: 1.0,
          rayOn: 1,
          rayX: 0.5,
          rayY: 0.5,
          rayIntensity: 0.8,
          rayLength: 0.8,
        ),
      );
      expect(armed, isNotEmpty);
      expect(armed, isNot(equals(neutral)));
    });

    test('selective brush + blur mask together export', () async {
      final png = _png(32, 32, (x, y) => (x * 8) % 256);
      final strokes = [_dab(0.5, 0.5), _dab(0.2, 0.8)];
      final out = await ExportService.export(
        srcBytes: png,
        params: const LensParams(selMode: 3, selStrength: 1.0),
        brushStrokesFlat: encodeBrushStrokes(strokes),
        blurMask256: Float32List(256 * 256)..fillRange(0, 256 * 256, 1.0),
      );
      expect(out, isNotEmpty);
      expect(out[0], 0xFF);
      expect(out[1], 0xD8);
    });

    test('blur invert mirrors non-invert', () async {
      // Step pattern: blur-invariant linear ramps would hide the difference.
      final png = _png(32, 32, (x, y) => x < 16 ? 20 : 230);
      final mask = Float32List(256 * 256);
      for (var i = 0; i < mask.length; i++) {
        mask[i] = (i % 256) / 255.0;
      }
      final plain = await ExportService.export(
        srcBytes: png,
        params: const LensParams(
          blurMode: 1,
          blurRadius: 0.03,
          blurStrength: 1.0,
        ),
        blurMask256: mask,
      );
      final inv = await ExportService.export(
        srcBytes: png,
        params: const LensParams(
          blurMode: 1,
          blurRadius: 0.03,
          blurStrength: 1.0,
          blurInvert: 1,
        ),
        blurMask256: mask,
      );
      expect(plain, isNot(equals(inv)));
    });

    test('rays zero length glow is local', () async {
      final png = _png(32, 32, (x, y) => 10);
      final glow = await ExportService.export(
        srcBytes: png,
        params: const LensParams(
          rayOn: 1,
          rayX: 0.1,
          rayY: 0.1,
          rayIntensity: 1.0,
          rayLength: 0.0,
        ),
      );
      final neutral = await ExportService.export(
        srcBytes: png,
        params: const LensParams(),
      );
      expect(glow, isNot(equals(neutral)));
    });
  });

  group('rays params', () {
    test('defaults equal off', () {
      expect(const RaysParams(), RaysParams.off);
      expect(RaysParams.off.intensity, 0.0);
    });

    test('white stays white under rays', () {
      const tint = (1.0, 0.75, 0.45);
      final (r, g, b) = applyRaysPixel(1.0, 1.0, 1.0, 1.0, 1.0, 1.0, tint, 1.0);
      expect(r, 1.0);
      expect(g, 1.0);
      expect(b, 1.0);
    });

    test('manual subject mask always signals manual', () async {
      expect(await const ManualSubjectMask().foregroundMask(Uint8List(10)), isNull);
    });
  });
}
