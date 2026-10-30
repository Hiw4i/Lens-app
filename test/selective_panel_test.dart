import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/features/selective/selective_mask.dart';
import 'package:lens/features/selective/selective_overlay.dart';
import 'package:lens/features/selective/selective_panel.dart';
import 'package:lens/shared/theme/theme_colors.dart';

Future<ProviderContainer> _pumpPanel(
  WidgetTester tester, {
  Widget body = const SelectivePanel(),
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
          child: Scaffold(body: SizedBox(height: 320, child: body)),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return container;
}

void main() {
  group('selective panel (Task 4.5)', () {
    testWidgets('renders without photo', (tester) async {
      await _pumpPanel(tester);
      expect(find.text('Radial'), findsOneWidget);
      expect(find.text('Linear'), findsOneWidget);
      expect(find.text('Brush'), findsOneWidget);
      expect(find.text('Off'), findsOneWidget);
      expect(find.text('Exposure'), findsWidgets);
      expect(find.text('Strength'), findsOneWidget);
      // Invert is a compact icon toggle sharing the Strength row, not a
      // labelled Switch — it stays visible while the mask is off.
      expect(find.byKey(const ValueKey('invert-toggle')), findsOneWidget);
      expect(find.text('Pick a mask shape to begin'), findsOneWidget);
    });

    testWidgets('tap Radial activates selective', (tester) async {
      final container = await _pumpPanel(tester);
      expect(container.read(editorStateProvider).selective.active, isFalse);
      await tester.tap(find.byKey(const ValueKey('selective-mode-radial')));
      await tester.pump();
      final selective = container.read(editorStateProvider).selective;
      expect(selective.active, isTrue);
      expect(selective.mode, equals(SelectiveMode.radial));
      expect(container.read(editorStateProvider).undoDepth, equals(1));
    });

    testWidgets('invert toggle flips geometry', (tester) async {
      final container = await _pumpPanel(tester);
      container
          .read(editorStateProvider.notifier)
          .setSelectiveMode(SelectiveMode.radial);
      await tester.pump();
      expect(
        container.read(editorStateProvider).selective.geometry.invert,
        isFalse,
      );
      await tester.tap(find.byKey(const ValueKey('invert-toggle')));
      await tester.pump();
      expect(
        container.read(editorStateProvider).selective.geometry.invert,
        isTrue,
      );
    });

    test('brush mode with empty strokes maps to mode 0 (stub guard)', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setSelectiveMode(SelectiveMode.brush);
      final params = container.read(editorStateProvider).toLensParams();
      // Empty brush grades nothing: mode 0 keeps the white stub bound
      // instead of sampling an empty raster.
      expect(params.selMode, equals(0));
      expect(
        container.read(editorStateProvider).encodeSelectiveBrush(),
        isNull,
      );
    });

    testWidgets('shared slider drives exposure as one history entry', (
      tester,
    ) async {
      final container = await _pumpPanel(tester);
      container
          .read(editorStateProvider.notifier)
          .setSelectiveMode(SelectiveMode.radial);
      await tester.pump();
      final slider = tester.widget<LensSlider>(
        find.byWidgetPredicate((w) => w is LensSlider && w.label == 'Exposure'),
      );
      slider.onChangeStart?.call(slider.value);
      slider.onChanged(75);
      slider.onChangeEnd?.call(75);
      await tester.pump();
      // Exposure range is -2..+2 (the state clamps selExp there): 75%
      // maps to +1.0.
      expect(container.read(editorStateProvider).selective.selExp, equals(1.0));
      expect(container.read(editorStateProvider).selective.selCon, equals(0));
      // One entry for the mode pick, one for the slider drag.
      expect(container.read(editorStateProvider).undoDepth, equals(2));
      container.read(editorStateProvider.notifier).undo();
      expect(container.read(editorStateProvider).selective.selExp, equals(0));
    });

    testWidgets('overlay brush drag paints one stroke as one entry', (
      tester,
    ) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      container
          .read(editorStateProvider.notifier)
          .setSelectiveMode(SelectiveMode.brush);
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
                    child: SelectiveOverlay(aspect: 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      await tester.drag(find.byType(SelectiveOverlay), const Offset(50, 30));
      await tester.pump();
      final strokes = container.read(editorStateProvider).selective.strokes;
      expect(strokes, hasLength(1));
      expect(strokes.single.points.length, greaterThanOrEqualTo(2));
      // First dab point lands at the drag start (box center, uv 0.5).
      expect(strokes.single.points.first.$1, closeTo(0.5, 0.05));
      expect(strokes.single.points.first.$2, closeTo(0.5, 0.05));
      // Mode pick + whole drag = two entries.
      expect(container.read(editorStateProvider).undoDepth, equals(2));
    });

    testWidgets('radial drag accumulates moves before the next frame', (
      tester,
    ) async {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      container
          .read(editorStateProvider.notifier)
          .setSelectiveMode(SelectiveMode.radial);
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
                    child: SelectiveOverlay(aspect: 1),
                  ),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();
      final gesture = await tester.startGesture(
        tester.getCenter(find.byType(SelectiveOverlay)),
      );
      // Three moves, ONE pump: the build-time geometry cannot refresh
      // between them, so the overlay must accumulate the deltas itself.
      // The old code kept only the newest delta and landed at 0.6 / 0.55.
      await gesture.moveBy(const Offset(20, 10));
      await gesture.moveBy(const Offset(20, 10));
      await gesture.moveBy(const Offset(20, 10));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      final geometry = container.read(editorStateProvider).selective.geometry;
      expect(geometry.center.$1, closeTo(0.5 + 60 / 200, 0.03));
      expect(geometry.center.$2, closeTo(0.5 + 30 / 200, 0.03));
    });
  });
}
