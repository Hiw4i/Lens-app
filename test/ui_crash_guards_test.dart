import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/imaging/widgets/shader_preview.dart';
import 'package:lens/features/library/library_screen.dart';
import 'package:lens/features/library/logic/library_provider.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Crash guards for first open: corrupt/empty images degrade to
/// placeholders instead of exception splashes. Regression tests for the
/// Image.memory errorBuilder fixes (library grid + preview CPU fallback)
/// and the addImage empty guard.

Widget _app(Widget child, {ProviderContainer? container}) {
  final scope = container == null
      ? ProviderScope(child: _themed(child))
      : UncontrolledProviderScope(container: container, child: _themed(child));
  return scope;
}

Widget _themed(Widget child) {
  return MaterialApp(
    home: ThemeColors(
      colors: palettes.first.light,
      duration: Duration.zero,
      child: HapticsScope(enabled: false, child: Scaffold(body: child)),
    ),
  );
}

void main() {
  testWidgets('library empty state renders, no crash', (tester) async {
    await tester.pumpWidget(_app(const LibraryScreen()));
    await tester.pump();
    expect(find.text('Library is empty'), findsOneWidget);
  });

  testWidgets('library grid with garbage bytes shows placeholder icon', (
    tester,
  ) async {
    final garbage = Uint8List.fromList(List<int>.generate(64, (i) => i));
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    container.read(libraryImagesProvider.notifier).addImage(garbage);
    await tester.pumpWidget(_app(const LibraryScreen(), container: container));
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    // Placeholder instead of an exception splash.
    expect(find.byIcon(LucideIcons.imageOff), findsOneWidget);
  });

  test('addImage ignores empty bytes', () {
    final container = ProviderContainer.test();
    addTearDown(container.dispose);
    final n = container.read(libraryImagesProvider.notifier);
    n.addImage(Uint8List(0));
    expect(container.read(libraryImagesProvider), isEmpty);
  });

  testWidgets('preview CPU fallback with garbage shows icon, no throw', (
    tester,
  ) async {
    // No shader program under flutter test -> _CpuFallback path.
    final garbage = Uint8List.fromList(List<int>.generate(64, (i) => i * 3));
    await tester.pumpWidget(
      _app(ShaderPreview(imageBytes: garbage, params: const LensParams())),
    );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(find.byIcon(LucideIcons.imageOff), findsOneWidget);
  });
}
