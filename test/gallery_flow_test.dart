import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/app/router.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';

void main() {
  test('opening another photo clears the previous grade and history', () {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final editor = container.read(editorStateProvider.notifier);
    editor.setPreviewBytes(Uint8List.fromList([1]));
    editor.setExposure(1);
    editor.setShowOriginal(true);
    editor.setPreviewBytes(Uint8List.fromList([2]));
    final state = container.read(editorStateProvider);
    expect(state.adjust.isDefault, isTrue);
    expect(state.undoDepth, 0);
    expect(state.showOriginal, isFalse);
    editor.undo();
    expect(container.read(editorStateProvider).adjust.isDefault, isTrue);
  });

  testWidgets('home has creation actions without bottom navigation', (
    tester,
  ) async {
    await tester.pumpWidget(
      ProviderScope(
        child: MaterialApp(
          builder: (context, child) => ThemeColors(
            colors: palettes.first.light,
            duration: Duration.zero,
            child: HapticsScope(enabled: false, child: child!),
          ),
          home: const LensRouter(),
        ),
      ),
    );
    await tester.pump();
    expect(find.byType(NavigationBar), findsNothing);
    expect(find.text('Edit'), findsOneWidget);
    expect(find.text('Collage'), findsOneWidget);
  });
}
