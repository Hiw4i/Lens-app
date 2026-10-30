import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/adjust/adjust_panel.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/shared/theme/theme_colors.dart';

void main() {
  testWidgets('selecting a card centres it in the strip', (tester) async {
    // The reveal used to target the LIST's sliver instead of the card, so
    // the strip jumped somewhere else entirely and the card the user just
    // picked could end up off-screen.
    await tester.binding.setSurfaceSize(const Size(400, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));
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
              body: SizedBox(height: 220, child: AdjustPanel()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    const Key card = ValueKey('adjustment-structure');
    await tester.tap(find.byKey(card));
    // Two pumps: the reveal is scheduled after the frame, and the scroll
    // animation needs a tick of its own to move.
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump(const Duration(milliseconds: 300));

    final Rect picked = tester.getRect(find.byKey(card));
    final Rect strip = tester.getRect(
      find.byKey(const ValueKey('adjustment-strip')),
    );
    expect(picked.center.dx, closeTo(strip.center.dx, 2));
    // And the card is fully on screen.
    expect(picked.left, greaterThanOrEqualTo(strip.left - 1));
    expect(picked.right, lessThanOrEqualTo(strip.right + 1));
  });

  testWidgets('horizontal parameter selection controls one shared slider', (
    tester,
  ) async {
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
              body: SizedBox(height: 220, child: AdjustPanel()),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(find.byType(LensSlider), findsOneWidget);
    final strip = find.byKey(const ValueKey('adjustment-strip'));
    await tester.drag(strip, const Offset(-500, 0));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('adjustment-highlights')));
    await tester.pumpAndSettle();
    final slider = tester.widget<LensSlider>(find.byType(LensSlider));
    slider.onChangeStart?.call(slider.value);
    slider.onChanged(75);
    slider.onChangeEnd?.call(75);
    await tester.pump();
    expect(container.read(editorStateProvider).adjust.highlights, 40);
    expect(container.read(editorStateProvider).adjust.exposure, 0);
    expect(container.read(editorStateProvider).undoDepth, 1);
    container.read(editorStateProvider.notifier).undo();
    expect(container.read(editorStateProvider).adjust.highlights, 0);
  });
}
