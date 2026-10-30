import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/adjust/adjust_panel.dart';
import 'package:lens/features/crop/crop_panel.dart';
import 'package:lens/features/crop/crop_stage.dart';
import 'package:lens/features/editor/editor_screen.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/photo_viewport.dart';
import 'package:lens/features/imaging/widgets/shader_preview.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';

Uint8List _tinyPng() {
  final image = img.Image(width: 4, height: 4, numChannels: 3);
  for (var y = 0; y < 4; y++) {
    for (var x = 0; x < 4; x++) {
      image.setPixelRgb(x, y, 128, 128, 128);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// Pumps the editor with a photo.
Future<ProviderContainer> _pumpEditor(
  WidgetTester tester, {
  EditorTool? tool,
  double aspectRatio = 0.75,
}) async {
  await tester.binding.setSurfaceSize(const Size(400, 800));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  final container = ProviderContainer.test();
  addTearDown(container.dispose);
  container.read(editorStateProvider.notifier).setPreviewBytes(_tinyPng());
  if (tool != null) {
    container.read(editorStateProvider.notifier).setTool(tool);
  }
  await tester.pumpWidget(
    UncontrolledProviderScope(
      container: container,
      child: MaterialApp(
        home: ThemeColors(
          colors: palettes.first.dark,
          duration: Duration.zero,
          child: Scaffold(body: EditorScreen(photoAspectRatio: aspectRatio)),
        ),
      ),
    ),
  );
  // The sheet measures itself a frame or two after the route opens, and the
  // photo then glides onto the composition the sheet settled on.
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  await tester.pump(const Duration(milliseconds: 400));
  return container;
}

/// The picture's painted frame.
Rect _photoRect(WidgetTester tester) => tester.getRect(
  find.descendant(
    of: find.byType(PhotoViewport),
    matching: find.byType(ShaderPreview),
  ),
);

void main() {
  group('Editor preview', () {
    testWidgets('the canvas is the whole screen', (tester) async {
      await _pumpEditor(tester);
      expect(
        tester.getRect(find.byType(PhotoViewport)),
        const Rect.fromLTWH(0, 0, 400, 800),
      );
    });

    testWidgets('the photo rests between the top bar and the sheet', (
      tester,
    ) async {
      await _pumpEditor(tester);
      final Rect photo = _photoRect(tester);
      // The top bar floats over the picture: the picture starts below it.
      final Rect back = tester.getRect(find.byType(AppButton).first);
      expect(photo.top, greaterThanOrEqualTo(back.bottom));
      // The sheet owns the bottom of the screen: the picture ends above it.
      final Rect sheet = tester.getRect(find.byType(AdjustPanel));
      expect(photo.bottom, lessThanOrEqualTo(sheet.top));
    });

    testWidgets('the crop stage keeps room beside the screen', (tester) async {
      await _pumpEditor(tester, tool: EditorTool.crop);
      final Rect stage = tester.getRect(find.byType(CropStage));
      // The corner handles of the crop window must stay reachable.
      expect(stage.left, greaterThanOrEqualTo(28));
      expect(stage.right, lessThanOrEqualTo(400 - 28));
      // And the window never hides under the sheet.
      final Rect sheet = tester.getRect(find.byType(CropPanel));
      expect(stage.bottom, lessThanOrEqualTo(sheet.top));
    });

    testWidgets('the photo fills the area the chrome leaves free', (
      tester,
    ) async {
      await _pumpEditor(tester);
      final Rect photo = _photoRect(tester);
      final Rect sheet = tester.getRect(find.byType(AdjustPanel));
      // The picture is composed for the sheet that is really there, so it
      // fills the visible area instead of sitting in a strip of background.
      expect(photo.width, 400);
      expect(photo.height, greaterThan(500));
      expect(photo.bottom, closeTo(sheet.top, 12));
    });

    testWidgets('switching tools leaves the photo where it is', (tester) async {
      // A wide photo leaves room above the sheet, so the growing panel does
      // not reach it and the picture must not move at all.
      final ProviderContainer container = await _pumpEditor(
        tester,
        aspectRatio: 1.5,
      );
      final Rect before = _photoRect(tester);
      container.read(editorStateProvider.notifier).setTool(EditorTool.blur);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.pump(const Duration(milliseconds: 400));
      expect(_photoRect(tester), before);
    });
  });
}
