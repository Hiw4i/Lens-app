import 'dart:typed_data';

import 'package:flutter/gestures.dart' show kLongPressTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/editor/editor_screen.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The AppBar history affordances: a tap steps the history once, holding
/// replays it step by step until the stack runs dry — at which point the
/// button greys out (nothing left to step) and the opposite button takes
/// over. Follows the contract in editor_screen.dart's [_UndoActions].

Uint8List _tinyPng() {
  final image = img.Image(width: 4, height: 4, numChannels: 3);
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      image.setPixelRgb(x, y, 128, 128, 128);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// Pumps the editor with a photo and returns its container.
Future<ProviderContainer> _pumpEditor(WidgetTester tester) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  container.read(editorStateProvider.notifier).setPreviewBytes(_tinyPng());
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ThemeColors(
          colors: palettes.first.dark,
          duration: Duration.zero,
          child: const Scaffold(body: EditorScreen(photoAspectRatio: 0.75)),
        ),
      ),
    ),
  );
  // The sheet measures itself a frame or two after the route opens.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  return container;
}

Finder _button(IconData icon) => find
    .ancestor(of: find.byIcon(icon), matching: find.byType(AppButton))
    .first;

/// Holds [icon] down long enough for the replay to finish (the long-press
/// fires the first step, then one step per 90ms tick).
Future<void> _holdThroughReplay(WidgetTester tester, IconData icon) async {
  final gesture = await tester.startGesture(
    tester.getCenter(find.byIcon(icon)),
  );
  await tester.pump(kLongPressTimeout + const Duration(milliseconds: 1));
  await tester.pump(const Duration(milliseconds: 90));
  await tester.pump(const Duration(milliseconds: 90));
  await tester.pump(const Duration(milliseconds: 90));
  await gesture.up();
  await tester.pump();
}

void main() {
  group('history buttons', () {
    testWidgets('tap steps once', (tester) async {
      final container = await _pumpEditor(tester);
      final n = container.read(editorStateProvider.notifier);
      n.setExposure(1.0);
      n.setContrast(50);
      n.setSaturation(20);
      await tester.pump();

      await tester.tap(_button(LucideIcons.undo2));
      await tester.pump();
      expect(container.read(editorStateProvider).undoDepth, 2);

      await tester.tap(_button(LucideIcons.redo2));
      await tester.pump();
      expect(container.read(editorStateProvider).undoDepth, 3);
    });

    testWidgets('holding Undo rolls the grade back and grays it out', (
      tester,
    ) async {
      final container = await _pumpEditor(tester);
      final n = container.read(editorStateProvider.notifier);
      n.setExposure(1.0);
      n.setContrast(50);
      n.setSaturation(20);
      await tester.pump();
      expect(tester.widget<AppButton>(_button(LucideIcons.undo2)).onTap,
          isNotNull);

      await _holdThroughReplay(tester, LucideIcons.undo2);

      final s = container.read(editorStateProvider);
      expect(s.isDefault, isTrue, reason: 'every edit was replayed back');
      expect(s.undoDepth, 0);
      expect(s.redoDepth, 3);
      // Nothing left to undo: the button is inert; Redo takes over.
      expect(
        tester.widget<AppButton>(_button(LucideIcons.undo2)).onTap,
        isNull,
      );
      expect(
        tester.widget<AppButton>(_button(LucideIcons.redo2)).onTap,
        isNotNull,
      );
    });

    testWidgets('holding Redo walks the changes back in', (tester) async {
      final container = await _pumpEditor(tester);
      final n = container.read(editorStateProvider.notifier);
      n.setExposure(1.0);
      n.setContrast(50);
      n.setSaturation(20);
      n.undo();
      n.undo();
      n.undo();
      expect(container.read(editorStateProvider).isDefault, isTrue);
      // Rebuild so Redo is live (IgnorePointer lifts) before the tap.
      await tester.pump();

      // One tap restores exactly one step.
      await tester.tap(_button(LucideIcons.redo2));
      await tester.pump();
      expect(container.read(editorStateProvider).redoDepth, 2);

      await _holdThroughReplay(tester, LucideIcons.redo2);

      final s = container.read(editorStateProvider);
      expect(s.redoDepth, 0);
      expect(s.adjust.exposure, 1.0);
      expect(s.adjust.contrast, 50);
      expect(s.adjust.saturation, 20);
      // Fully replayed: Redo is inert, Undo is back.
      expect(
        tester.widget<AppButton>(_button(LucideIcons.redo2)).onTap,
        isNull,
      );
      expect(
        tester.widget<AppButton>(_button(LucideIcons.undo2)).onTap,
        isNotNull,
      );
    });
  });
}
