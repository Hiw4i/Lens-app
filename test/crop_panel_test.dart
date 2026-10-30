import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/crop/crop_panel.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/shared/theme/theme_colors.dart';

Future<ProviderContainer> _pumpPanel(WidgetTester tester) async {
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
              child: SizedBox(width: 380, height: 160, child: CropPanel()),
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
  group('crop panel', () {
    testWidgets('builds without the fading-strip controller crash', (
      tester,
    ) async {
      await _pumpPanel(tester);
      expect(tester.takeException(), isNull);
      expect(find.text('Free'), findsOneWidget);
      expect(find.text('1:1'), findsOneWidget);
      expect(find.text('Straighten'), findsOneWidget);
      expect(find.byTooltip('Rotate 90°'), findsOneWidget);
      expect(find.byTooltip('Reset crop'), findsOneWidget);
    });

    testWidgets('ratio chip locks the window and adds history', (tester) async {
      final container = await _pumpPanel(tester);
      await tester.tap(find.byKey(const ValueKey('crop-ratio-1:1')));
      await tester.pump();
      expect(container.read(editorStateProvider).crop.ratio, 1);
      expect(container.read(editorStateProvider).undoDepth, 1);
    });

    testWidgets('quarter-turn button advances the crop rotation', (
      tester,
    ) async {
      final container = await _pumpPanel(tester);
      await tester.tap(find.byTooltip('Rotate 90°'));
      await tester.pump();
      expect(container.read(editorStateProvider).crop.quarterTurns, 1);
    });
  });
}
