import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/blur/blur_overlay.dart';
import 'package:lens/features/blur/blur_panel.dart';
import 'package:lens/features/blur/subject_mask.dart' show SubjectSource;
import 'package:lens/features/editor/editor_screen.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/shared/theme/theme_colors.dart';

Uint8List _tinyPng() {
  final image = img.Image(width: 4, height: 4, numChannels: 3);
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      image.setPixelRgb(x, y, 128, 128, 128);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester, {
  Widget body = const BlurPanel(),
}) async {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ThemeColors(
          colors: palettes.first.dark,
          duration: Duration.zero,
          child: Scaffold(body: SizedBox(height: 360, child: body)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('blur panel (Task 6.4)', () {
    testWidgets('renders without photo', (tester) async {
      await _pumpPanel(tester);
      expect(find.text('Auto'), findsOneWidget);
      expect(find.text('Manual'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Blur'), findsWidgets);
      expect(find.text('Feather'), findsWidgets);
      // Blur is off, so the Strength/Invert row is replaced by the one-tap
      // button — the sheet keeps a single fixed height in both states.
      expect(find.text('Blur background'), findsOneWidget);
      expect(find.byKey(const ValueKey('invert-toggle')), findsNothing);
      expect(
        find.text('Tap Blur background or pick a mask source'),
        findsOneWidget,
      );
    });

    testWidgets('strength and invert appear once blur is on', (tester) async {
      final container = await _pumpPanel(tester);
      await tester.tap(find.text('Blur background'));
      await tester.pump();
      expect(container.read(editorStateProvider).blur.strength, greaterThan(0));
      expect(find.text('Strength'), findsOneWidget);
      expect(find.byKey(const ValueKey('invert-toggle')), findsOneWidget);
      expect(find.text('Blur background'), findsNothing);
    });

    test('one-tap turns on at 60 as one history entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      expect(container.read(editorStateProvider).blur.strength, equals(0));
      notifier.applyBlurOneTap();
      final s = container.read(editorStateProvider);
      expect(s.blur.strength, equals(kBlurOneTapStrength));
      expect(s.blur.strength, equals(60));
      expect(s.undoDepth, equals(1));
      // Float mapping: auto source (default) -> mode 1, strength 0.6,
      // radius 40 -> 0.02, feather 50 -> 0.5.
      final p = s.toLensParams();
      expect(p.blurMode, equals(1));
      expect(p.blurStrength, closeTo(0.6, 1e-12));
      expect(p.blurRadius, closeTo(0.02, 1e-12));
      expect(p.blurFeather, closeTo(0.5, 1e-12));
      expect(p.blurInvert, equals(0));
      // Re-tap is a no-op (no duplicate entry).
      notifier.applyBlurOneTap();
      expect(container.read(editorStateProvider).undoDepth, equals(1));
    });

    test('manual without strokes maps to mode off and null mask', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setBlurSource(SubjectSource.manual);
      final s = container.read(editorStateProvider);
      // Picking Manual turns on (one-tap 60) but empty manual grades nothing.
      expect(s.blur.source, equals(SubjectSource.manual));
      expect(s.blur.strength, equals(kBlurOneTapStrength));
      expect(s.toLensParams().blurMode, equals(0));
      expect(s.toLensParams().blurStrength, equals(0.0));
      expect(s.resolveBlurMask256(), isNull);
    });

    test('painted manual stroke lifts the mode fallback to 2', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setBlurSource(SubjectSource.manual);
      expect(container.read(editorStateProvider).undoDepth, equals(1));
      notifier.beginStroke();
      notifier.addBlurBrushPoint(0.5, 0.5);
      notifier.addBlurBrushPoint(0.6, 0.6);
      notifier.endStroke();
      final s = container.read(editorStateProvider);
      expect(s.blur.strokes, hasLength(1));
      expect(s.blur.strokes.single.points, hasLength(2));
      expect(s.toLensParams().blurMode, equals(2));
      expect(s.toLensParams().blurStrength, closeTo(0.6, 1e-12));
      expect(s.resolveBlurMask256(), isNotNull);
      expect(s.resolveBlurMask256()!.length, equals(256 * 256));
      // Source pick + whole drag = two entries.
      expect(s.undoDepth, equals(2));
      notifier.undo();
      expect(
        container.read(editorStateProvider).toLensParams().blurMode,
        equals(0),
      );
    });

    test('invert flips the shader flag and survives undo', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.applyBlurOneTap();
      notifier.setBlurInvert(true);
      expect(
        container.read(editorStateProvider).toLensParams().blurInvert,
        equals(1),
      );
      notifier.undo();
      expect(
        container.read(editorStateProvider).toLensParams().blurInvert,
        equals(0),
      );
    });

    test('strength 0 forces mode 0 (stage skipped)', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.applyBlurOneTap();
      expect(
        container.read(editorStateProvider).toLensParams().blurMode,
        equals(1),
      );
      notifier.clearBlur();
      final s = container.read(editorStateProvider);
      expect(s.blur.strength, equals(0));
      expect(s.toLensParams().blurMode, equals(0));
      expect(s.toLensParams().blurStrength, equals(0.0));
      expect(s.resolveBlurMask256(), isNull);
    });

    test('desktop fallback: ML miss resolves null without crashing', () {
      // No prewarm in tests -> BlurCache miss -> null (honest manual
      // fallback, never a full-frame blur, never a throw).
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setPreviewBytes(_tinyPng());
      notifier.applyBlurOneTap();
      final s = container.read(editorStateProvider);
      expect(s.blur.source, equals(SubjectSource.auto));
      expect(s.toLensParams().blurMode, equals(1));
      expect(s.resolveBlurMask256(), isNull);
    });

    testWidgets('auto-miss shows honest hint with Manual button, no crash', (
      tester,
    ) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      container.read(editorStateProvider.notifier).setPreviewBytes(_tinyPng());
      container.read(editorStateProvider.notifier).applyBlurOneTap();
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ThemeColors(
              colors: palettes.first.dark,
              duration: Duration.zero,
              child: const Scaffold(body: EditorScreen()),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Honest fallback (concern 6.1#4): no spinner, hint + Manual action.
      expect(find.text('Finding subject… Paint manually'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('blur-fallback-manual')));
      await tester.pump();
      expect(
        container.read(editorStateProvider).blur.source,
        equals(SubjectSource.manual),
      );
    });

    testWidgets('manual overlay paints one stroke as one entry', (
      tester,
    ) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      container
          .read(editorStateProvider.notifier)
          .setBlurSource(SubjectSource.manual);
      await tester.pumpWidget(
        UncontrolledProviderScope(
          container: container,
          child: MaterialApp(
            home: ThemeColors(
              colors: palettes.first.dark,
              duration: Duration.zero,
              child: const Scaffold(
                body: Center(
                  child: SizedBox(
                    width: 200,
                    height: 200,
                    child: BlurOverlay(),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(BlurOverlay), const Offset(50, 30));
      await tester.pump();
      final strokes = container.read(editorStateProvider).blur.strokes;
      expect(strokes, hasLength(1));
      expect(strokes.single.points.length, greaterThanOrEqualTo(2));
      expect(strokes.single.points.first.$1, closeTo(0.5, 0.05));
      expect(strokes.single.points.first.$2, closeTo(0.5, 0.05));
      // Source pick + whole drag = two entries.
      expect(container.read(editorStateProvider).undoDepth, equals(2));
    });

    testWidgets('shared slider drives radius as one history entry', (
      tester,
    ) async {
      final container = await _pumpPanel(tester);
      container.read(editorStateProvider.notifier).applyBlurOneTap();
      await tester.pump();
      final slider = tester.widget<LensSlider>(
        find.byWidgetPredicate((w) => w is LensSlider && w.label == 'Blur'),
      );
      slider.onChangeStart?.call(slider.value);
      slider.onChanged(80);
      slider.onChangeEnd?.call(80);
      await tester.pump();
      expect(container.read(editorStateProvider).blur.radius, equals(80));
      expect(
        container.read(editorStateProvider).toLensParams().blurRadius,
        closeTo(0.04, 1e-12),
      );
      // One-tap + one slider drag = two entries.
      expect(container.read(editorStateProvider).undoDepth, equals(2));
      container.read(editorStateProvider.notifier).undo();
      expect(container.read(editorStateProvider).blur.radius, equals(40));
    });
  });
}
