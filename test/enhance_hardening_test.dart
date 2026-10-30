import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/adjust/adjust_panel.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_apply.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_cache.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/imaging/export/save_service.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// Stage-3 hardening: degenerate inputs, cache races, strength clamps,
/// save-name edges. The app must degrade to neutral, never throw at the
/// user, on anything from 1px black frames to garbage bytes.

img.Image _solid(int w, int h, int r, int g, int b) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return image;
}

Uint8List _pngBytes(img.Image image) => img.encodePng(image);

void main() {
  group('analyzeEnhance degenerate inputs', () {
    test('1x1 black: gains 1, valid window, finite', () {
      final a = analyzeEnhance(_solid(1, 1, 0, 0, 0));
      expect(a.wbGainR, 1.0);
      expect(a.wbGainB, 1.0);
      expect(a.whitePt, greaterThan(a.blackPt));
      expect(a.wbGainR.isFinite, isTrue);
    });

    test('1x1 white: gains 1, no NaN', () {
      final a = analyzeEnhance(_solid(1, 1, 255, 255, 255));
      expect(a.wbGainR, 1.0);
      expect(a.wbGainB, 1.0);
      expect(a.dehaze.isNaN, isFalse);
    });

    test('uniform mid-gray: mono guard holds gains at 1', () {
      final a = analyzeEnhance(_solid(8, 8, 128, 128, 128));
      expect(a.wbGainR, 1.0);
      expect(a.wbGainB, 1.0);
    });

    test('2x2 extremes: finite, ordered window', () {
      final image = img.Image(width: 2, height: 2, numChannels: 3);
      image.setPixelRgb(0, 0, 0, 0, 0);
      image.setPixelRgb(1, 0, 255, 255, 255);
      image.setPixelRgb(0, 1, 255, 0, 0);
      image.setPixelRgb(1, 1, 0, 0, 255);
      final a = analyzeEnhance(image);
      for (final v in [a.wbGainR, a.wbGainB, a.blackPt, a.whitePt, a.dehaze]) {
        expect(v.isFinite, isTrue, reason: 'non-finite $v in $a');
      }
      expect(a.whitePt, greaterThan(a.blackPt));
      expect(a.wbGainR, inInclusiveRange(0.7, 1.33));
    });

    test('512px uniform exercises subsample path without throw', () {
      final a = analyzeEnhance(_solid(512, 200, 90, 100, 110));
      expect(a.wbGainR, 1.0); // near-mono spread
      expect(a.dehaze, inInclusiveRange(0.0, 0.6));
    });
  });

  group('apply strength edges', () {
    test('strength 0 is bit-exact', () {
      const a = EnhanceAnalysis(
        wbGainR: 1.3,
        wbGainB: 0.75,
        blackPt: 0.1,
        whitePt: 0.9,
        dehaze: 0.6,
      );
      expect(applyEnhancePixel(0.2, 0.5, 0.7, a, 0), (0.2, 0.5, 0.7));
    });

    test('negative strength clamps to 0', () {
      const a = EnhanceAnalysis(wbGainR: 1.3, whitePt: 0.9, blackPt: 0.1);
      expect(
        applyEnhancePixel(0.2, 0.5, 0.7, a, -2),
        applyEnhancePixel(0.2, 0.5, 0.7, a, 0),
      );
    });

    test('strength 2 clamps to 1', () {
      const a = EnhanceAnalysis(wbGainR: 1.3, whitePt: 0.9, blackPt: 0.1);
      expect(
        applyEnhancePixel(0.2, 0.5, 0.7, a, 2),
        applyEnhancePixel(0.2, 0.5, 0.7, a, 1),
      );
    });

    test('degenerate window (white==black) never yields NaN', () {
      const a = EnhanceAnalysis(blackPt: 0.5, whitePt: 0.5);
      final (r, g, b) = applyEnhancePixel(0.9, 0.1, 0.4, a, 1);
      expect(r.isNaN || g.isNaN || b.isNaN, isFalse);
    });

    test('buffers guards: bad length and zero dims throw ArgumentError', () {
      expect(
        () => applyEnhanceToBuffers(
          Float32List(5),
          2,
          2,
          EnhanceAnalysis.none,
          1,
        ),
        throwsArgumentError,
      );
      expect(
        () => applyEnhanceToBuffers(
          Float32List(0),
          0,
          4,
          EnhanceAnalysis.none,
          1,
        ),
        throwsArgumentError,
      );
    });
  });

  group('enhance cache races', () {
    test('prewarm empty bytes never throws, reads neutral', () {
      EnhanceCache.prewarm(Uint8List(0), onReady: () {});
      expect(EnhanceCache.getOrNone(Uint8List(0)), EnhanceAnalysis.none);
    });

    test('prewarm garbage never throws and settles to none', () async {
      final garbage = Uint8List.fromList(List<int>.generate(128, (i) => i));
      var fired = 0;
      EnhanceCache.prewarm(garbage, onReady: () => fired++);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(EnhanceCache.getOrNone(garbage), EnhanceAnalysis.none);
      expect(fired, 1);
    });

    test('double prewarm fires both hooks once', () async {
      final png = _pngBytes(_solid(32, 32, 200, 120, 80));
      var a = 0;
      var b = 0;
      EnhanceCache.prewarm(png, onReady: () => a++);
      EnhanceCache.prewarm(png, onReady: () => b++);
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(a, 1);
      expect(b, 1);
      expect(EnhanceCache.get(png), isNotNull);
    });

    test('throwing onReady does not break caching', () async {
      final png = _pngBytes(_solid(24, 24, 60, 140, 200));
      EnhanceCache.prewarm(
        png,
        onReady: () => throw StateError('dead listener'),
      );
      await Future<void>.delayed(const Duration(seconds: 3));
      expect(EnhanceCache.get(png), isNotNull);
    });
  });

  group('pipeline enhance wiring', () {
    test('enhanceStrength clamps into slot 20', () {
      final u = const LensParams(enhanceStrength: 5).toUniforms();
      expect(u.length, 56);
      expect(u[18], 1.0);
    });

    test('CPU enhance uniforms change output end-to-end', () {
      final png = _pngBytes(_solid(16, 16, 200, 120, 60));
      final base = applyLensGrade(png, const LensParams().toUniforms());
      final enhanced = applyLensGrade(
        png,
        const LensParams(
          enhR: 1.2,
          enhB: 0.85,
          enhBlack: 0.08,
          enhWhite: 0.92,
          enhanceStrength: 1.0,
        ).toUniforms(),
      );
      expect(enhanced, isNotEmpty);
      expect(enhanced, isNot(equals(base)));
    });

    test('toLensParams with no photo is enhance-neutral', () {
      const s = EditorState(); // enhanceStrength 0, no bytes
      final p = s.toLensParams();
      expect(p.enhanceStrength, 0.0);
      expect(p.enhR, 1.0);
      expect(p.enhDehaze, 0.0);
    });
  });

  group('save-name edges', () {
    test('100-char name caps at 64', () {
      expect(sanitizeFileName('a' * 100).length, lessThanOrEqualTo(64));
    });

    test('all-unsafe name falls back', () {
      expect(sanitizeFileName('///:::???'), 'lens-photo');
    });

    test('temp path always ends with .jpg', () {
      expect(buildShareTempPath('/tmp', 'pic'), endsWith('.jpg'));
    });
  });

  group('enhance card with no photo', () {
    Widget panel(ProviderContainer container) {
      return UncontrolledProviderScope(
        container: container,
        child: MaterialApp(
          home: ThemeColors(
            colors: palettes.first.light,
            duration: Duration.zero,
            child: const HapticsScope(
              enabled: false,
              child: Scaffold(
                body: SizedBox(height: 220, child: AdjustPanel()),
              ),
            ),
          ),
        ),
      );
    }

    testWidgets('renders the enhance card without a photo', (tester) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      await tester.pumpWidget(panel(container));
      await tester.pump();
      expect(find.text('Enhance'), findsOneWidget);
    });

    testWidgets('tapping the enhance card selects it without applying', (
      tester,
    ) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      await tester.pumpWidget(panel(container));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('adjustment-enhance')));
      await tester.pump();
      // Selecting the card is NOT applying it: the grade stays off until
      // the strength slider moves (the one-tap lives on the notifier).
      expect(container.read(editorStateProvider).enhanceStrength, 0);
      expect(tester.takeException(), isNull);
    });
  });
}
