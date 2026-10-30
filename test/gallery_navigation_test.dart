import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/app/router.dart';
import 'package:lens/features/collage/collage_screen.dart';
import 'package:lens/features/editor/editor_screen.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/library/logic/library_provider.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';

Uint8List photo(int red) => img.encodePng(
  img.fill(
    img.Image(width: 180, height: 120),
    color: img.ColorRgb8(red, 90, 140),
  ),
);

Widget app(
  Widget home, {
  ProviderContainer? container,
  bool dark = false,
  double scale = 1,
}) {
  final child = MaterialApp(
    theme: ThemeData(
      useMaterial3: true,
      brightness: dark ? Brightness.dark : Brightness.light,
    ),
    builder: (context, child) => ThemeColors(
      duration: Duration.zero,
      colors: dark ? palettes.first.dark : palettes.first.light,
      child: HapticsScope(
        enabled: false,
        child: MediaQuery(
          data: MediaQuery.of(context)
              .copyWith(textScaler: TextScaler.linear(scale)),
          child: child!,
        ),
      ),
    ),
    home: home,
  );
  return container == null
      ? ProviderScope(child: child)
      : UncontrolledProviderScope(container: container, child: child);
}

void main() {
  testWidgets('photo tap expands to editor and back restores gallery', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    container.read(libraryImagesProvider.notifier).addImage(photo(190));
    await tester.pumpWidget(app(const LensRouter(), container: container));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.bySemanticsLabel('Photo 1'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byType(EditorScreen).evaluate().isNotEmpty) break;
      }
    });
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(EditorScreen), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpAndSettle();
    expect(find.byTooltip('Save'), findsOneWidget);
    // Task 4.5: Selective is a working tool, so the rail shows it.
    expect(find.text('Selective'), findsOneWidget);
    await tester.tap(find.byTooltip('Back'));
    await tester.pumpAndSettle();
    expect(find.text('All photos'), findsOneWidget);
    expect(find.byType(EditorScreen), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the export checkmark closes the editor and shows the gallery', (
    tester,
  ) async {
    await tester.binding.setSurfaceSize(const Size(375, 812));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    container.read(libraryImagesProvider.notifier).addImage(photo(190));
    await tester.pumpWidget(app(const LensRouter(), container: container));
    await tester.pumpAndSettle();
    await tester.runAsync(() async {
      await tester.tap(find.bySemanticsLabel('Photo 1'));
      for (var i = 0; i < 50; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump();
        if (find.byType(EditorScreen).evaluate().isNotEmpty) break;
      }
    });
    await tester.pump(const Duration(milliseconds: 200));
    expect(find.byType(EditorScreen), findsOneWidget);
    await tester.pumpAndSettle();

    // The editor's Save button opens the export screen.
    await tester.tap(find.byTooltip('Save'));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byTooltip('Done'), findsOneWidget);

    // The checkmark means "done": the editor goes away and the gallery —
    // the start window — is what is left.
    await tester.tap(find.byTooltip('Done'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 600));
    await tester.pumpAndSettle();
    expect(find.byType(EditorScreen), findsNothing);
    expect(find.text('All photos'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  for (final size in [const Size(320, 568), const Size(812, 375)]) {
    testWidgets(
      'editor Save and Reset remain reachable at $size with large text',
      (tester) async {
        await tester.binding.setSurfaceSize(size);
        addTearDown(() => tester.binding.setSurfaceSize(null));
        final container = ProviderContainer.test();
        addTearDown(container.dispose);
        container
            .read(editorStateProvider.notifier)
            .setPreviewBytes(photo(190));
        await tester.pumpWidget(
          app(
            const EditorScreen(photoAspectRatio: 1.5),
            container: container,
            dark: true,
            scale: 2,
          ),
        );
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        await tester.tap(find.byTooltip('Save'));
        await tester.pump();
        await tester.pump(const Duration(seconds: 1));
        expect(tester.takeException(), isNull);
        final close = find.byTooltip('Close');
        await tester.ensureVisible(close);
        await tester.tap(close);
        await tester.pumpAndSettle();
        await tester.pumpWidget(const SizedBox());
      },
    );
    testWidgets('collage works at $size with large text in dark mode', (
      tester,
    ) async {
      await tester.binding.setSurfaceSize(size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        app(
          CollageScreen(images: [photo(190), photo(60), photo(120)]),
          dark: true,
          scale: 2,
        ),
      );
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final ratio = find.text('16:9');
      await tester.ensureVisible(ratio);
      await tester.tap(ratio);
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      expect(find.text('Save'), findsOneWidget);
    });
  }
}
