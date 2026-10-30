import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/features/rays/rays_overlay.dart';
import 'package:lens/features/rays/rays_panel.dart';
import 'package:lens/shared/theme/theme_colors.dart';

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester, {
  Widget body = const RaysPanel(),
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

Future<ProviderContainer> _pumpOverlay(WidgetTester tester) async {
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ThemeColors(
          colors: palettes.first.dark,
          duration: Duration.zero,
          child: const Scaffold(
            body: Center(
              child: SizedBox(width: 200, height: 200, child: RaysOverlay()),
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('rays panel (Task 7.4)', () {
    testWidgets('renders without photo', (tester) async {
      await _pumpPanel(tester);
      expect(find.text('Add light'), findsOneWidget);
      expect(find.text('Intensity'), findsWidgets);
      expect(find.text('Length'), findsWidgets);
      expect(find.text('Warmth'), findsWidgets);
      expect(find.text('Density'), findsWidgets);
      expect(
        find.text('Add light, then tap the photo to place the sun'),
        findsOneWidget,
      );
    });

    test('one-tap turns on at 65 as one history entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      expect(container.read(editorStateProvider).rays.intensity, equals(0));
      notifier.applyRaysOneTap();
      final s = container.read(editorStateProvider);
      expect(s.rays.intensity, equals(kRaysOneTapStrength));
      expect(s.rays.intensity, equals(65));
      expect(s.undoDepth, equals(1));
      // Float mapping: gate on, parked math-core defaults
      // (intensity .65, length .6, golden warmth .7, density .5).
      final p = s.toLensParams();
      expect(p.rayOn, equals(1));
      expect(p.rayX, equals(0.5));
      expect(p.rayY, equals(0.2));
      expect(p.rayIntensity, closeTo(0.65, 1e-12));
      expect(p.rayLength, closeTo(0.6, 1e-12));
      expect(p.rayWarmth, closeTo(0.7, 1e-12));
      expect(p.rayDensity, closeTo(0.5, 1e-12));
      // Re-tap is a no-op (no duplicate entry).
      notifier.applyRaysOneTap();
      expect(container.read(editorStateProvider).undoDepth, equals(1));
    });

    test('one-tap from parked state keeps the parked sun', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.applyRaysOneTap();
      notifier.setRaysSource(0.1, 0.8);
      notifier.clearRays();
      expect(
        container.read(editorStateProvider).rays.source,
        equals((0.1, 0.8)),
      );
      // Off -> one-tap restores the default sun (parked-off entry point).
      notifier.applyRaysOneTap();
      final s = container.read(editorStateProvider);
      expect(s.rays.source, equals((0.5, 0.2)));
      expect(s.rays.intensity, equals(65));
    });

    testWidgets('tap-to-place updates the source as one entry', (tester) async {
      final container = await _pumpOverlay(tester);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.applyRaysOneTap();
      await tester.pump();
      final center = tester.getCenter(find.byType(RaysOverlay));
      await tester.tapAt(center + const Offset(50, -40));
      await tester.pump();
      final s = container.read(editorStateProvider);
      // 200x200 box: (+50, -40) from center = uv (0.75, 0.3).
      expect(s.rays.source.$1, closeTo(0.75, 1e-9));
      expect(s.rays.source.$2, closeTo(0.3, 1e-9));
      // One-tap + tap-place = two entries.
      expect(s.undoDepth, equals(2));
      expect(s.toLensParams().rayX, closeTo(0.75, 1e-9));
      expect(s.toLensParams().rayY, closeTo(0.3, 1e-9));
    });

    test('intensity 0 forces rayOn 0 (stage skipped)', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.applyRaysOneTap();
      expect(
        container.read(editorStateProvider).toLensParams().rayOn,
        equals(1),
      );
      notifier.clearRays();
      final s = container.read(editorStateProvider);
      expect(s.rays.intensity, equals(0));
      expect(s.toLensParams().rayOn, equals(0));
      expect(s.toLensParams().rayIntensity, equals(0.0));
      // Parked scalars survive the gate (off means off, not forgotten).
      expect(s.toLensParams().rayWarmth, closeTo(0.7, 1e-12));
    });

    test('undo restores source and gate', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.applyRaysOneTap();
      notifier.setRaysSource(0.8, 0.7);
      expect(container.read(editorStateProvider).undoDepth, equals(2));
      notifier.undo();
      var s = container.read(editorStateProvider);
      expect(s.rays.source, equals((0.5, 0.2)));
      expect(s.toLensParams().rayOn, equals(1));
      notifier.undo();
      s = container.read(editorStateProvider);
      expect(s.rays.intensity, equals(0));
      expect(s.toLensParams().rayOn, equals(0));
      notifier.redo();
      expect(container.read(editorStateProvider).rays.intensity, equals(65));
    });

    testWidgets('double-tap resets the sun to the default', (tester) async {
      final container = await _pumpOverlay(tester);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.applyRaysOneTap();
      notifier.setRaysSource(0.1, 0.8);
      await tester.pump();
      expect(
        container.read(editorStateProvider).rays.source,
        equals((0.1, 0.8)),
      );
      // The first tap places the sun at the center, the second tap-down
      // arms the manual double-tap (same real-time instant, same position)
      // and its tap-up resets — the gesture always ends at the default.
      // (`WidgetTester.doubleTap` does not exist in this Flutter version;
      // two back-to-back tapAts are a real double-tap for the overlay.)
      final center = tester.getCenter(find.byType(RaysOverlay));
      await tester.tapAt(center);
      await tester.tapAt(center);
      await tester.pump();
      expect(
        container.read(editorStateProvider).rays.source,
        equals((0.5, 0.2)),
      );
    });

    testWidgets('shared slider drives length as one history entry', (
      tester,
    ) async {
      final container = await _pumpPanel(tester);
      container.read(editorStateProvider.notifier).applyRaysOneTap();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('rays-param-length')));
      await tester.pump();
      final slider = tester.widget<LensSlider>(
        find.byWidgetPredicate((w) => w is LensSlider && w.label == 'Length'),
      );
      slider.onChangeStart?.call(slider.value);
      slider.onChanged(80);
      slider.onChangeEnd?.call(80);
      await tester.pump();
      expect(container.read(editorStateProvider).rays.length, equals(80));
      expect(
        container.read(editorStateProvider).toLensParams().rayLength,
        closeTo(0.8, 1e-12),
      );
      // One-tap + one slider drag = two entries.
      expect(container.read(editorStateProvider).undoDepth, equals(2));
      container.read(editorStateProvider.notifier).undo();
      expect(container.read(editorStateProvider).rays.length, equals(60));
    });

    testWidgets('overlay paints no handle while off', (tester) async {
      final handle = find.descendant(
        of: find.byType(RaysOverlay),
        matching: find.byType(CustomPaint),
      );
      final container = await _pumpOverlay(tester);
      expect(handle, findsNothing);
      container.read(editorStateProvider.notifier).applyRaysOneTap();
      await tester.pump();
      expect(handle, findsOneWidget);
    });
  });
}
