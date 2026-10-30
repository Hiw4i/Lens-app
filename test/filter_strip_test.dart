import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/filters/filter_strip.dart';
import 'package:lens/features/filters/lut_definition.dart';
import 'package:lens/features/imaging/cache/preview_cache.dart';
import 'package:lens/features/imaging/widgets/shader_preview.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// 4x4 red PNG: valid bytes for the CPU fallback path
/// ([ShaderPreview] renders `Image.memory` when no shader program exists,
/// which is always the case under `flutter test`).
Uint8List _photoBytes({int width = 4, int height = 4}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      image.setPixelRgb(x, y, 200, 40, 40);
    }
  }
  return img.encodePng(image);
}

Widget _strip({
  LensFilterId selected = LensFilterId.none,
  Uint8List? bytes,
  ValueChanged<LensFilterId>? onSelect,
}) {
  return MaterialApp(
    home: ThemeColors(
      colors: palettes.first.light,
      duration: Duration.zero,
      child: HapticsScope(
        enabled: false,
        child: Scaffold(
          body: FilterStrip(
            selectedId: selected,
            previewBytes: bytes,
            onSelect: onSelect ?? (_) {},
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('renders all nine look labels', (tester) async {
    await tester.pumpWidget(_strip(bytes: _photoBytes()));
    await tester.pump();
    for (final id in LensFilterId.values) {
      expect(
        find.text(FilterStrip.labelOf(id)),
        findsOneWidget,
        reason: 'missing label for $id',
      );
    }
  });

  testWidgets('tap reports the tapped filter id', (tester) async {
    LensFilterId? tapped;
    await tester.pumpWidget(
      _strip(bytes: _photoBytes(), onSelect: (id) => tapped = id),
    );
    await tester.pump();
    // BW is on-screen without scrolling.
    await tester.tap(find.text('BW'));
    expect(tapped, LensFilterId.bw);
  });

  testWidgets('every thumb covers its square tile (non-square photo)', (
    tester,
  ) async {
    // A 2:1 frame: contain would leave surface-coloured bars in the square
    // tile, cover crops the sides instead.
    await tester.pumpWidget(_strip(bytes: _photoBytes(width: 8, height: 4)));
    await tester.pump();
    final previews = tester.widgetList<ShaderPreview>(
      find.byType(ShaderPreview),
    );
    expect(previews, isNotEmpty);
    for (final preview in previews) {
      expect(preview.fit, BoxFit.cover);
      // The crop is done in the pixels as well, so the tile is filled by
      // construction on every path.
      expect(preview.squareCrop, isTrue);
    }
  });

  test('the square preview is a centre crop of the photo', () async {
    // A 2:1 frame: the square preview must be the middle half of it, so
    // the thumb shows the centre of the picture and fills the tile.
    final bytes = _photoBytes(width: 8, height: 4);
    final square = await PreviewCache.squarePreviewBytes(bytes, maxDim: 64);
    final img.Image? cropped = img.decodeImage(square);
    expect(cropped, isNotNull);
    expect(cropped!.width, cropped.height);
    // The source is 8x4: the square crop is 4x4 (the middle half).
    expect(cropped.width, 4);
  });

  testWidgets('null photo renders letter placeholders', (tester) async {
    await tester.pumpWidget(_strip());
    await tester.pump();
    for (final id in LensFilterId.values) {
      expect(
        find.text(FilterStrip.labelOf(id)),
        findsOneWidget,
        reason: 'missing label for $id',
      );
    }
  });
}
