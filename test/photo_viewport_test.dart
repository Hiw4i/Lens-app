import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/editor/widgets/photo_viewport.dart';

/// Pumps a viewport over a fixed canvas and returns the photo's painted
/// frame, which is what the user sees on screen.
Future<Rect> _pump(
  WidgetTester tester, {
  required Size canvas,
  required EdgeInsets visibleInsets,
  required double aspectRatio,
}) async {
  await tester.binding.setSurfaceSize(canvas);
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Center(
        child: SizedBox(
          width: canvas.width,
          height: canvas.height,
          child: PhotoViewport(
            aspectRatio: aspectRatio,
            visibleInsets: visibleInsets,
            child: const SizedBox.expand(key: ValueKey('probe')),
          ),
        ),
      ),
    ),
  );
  return tester.getRect(find.byKey(const ValueKey('probe')));
}

/// Two-finger pinch from [from] to [to] pixels around [center].
Future<void> _pinch(
  WidgetTester tester,
  Offset center,
  double from,
  double to,
) async {
  final TestGesture first = await tester.startGesture(center - Offset(from, 0));
  final TestGesture second = await tester.startGesture(
    center + Offset(from, 0),
  );
  await tester.pump();
  await first.moveTo(center - Offset(to, 0));
  await second.moveTo(center + Offset(to, 0));
  await tester.pump();
  await first.up();
  await second.up();
  await tester.pump();
}

void main() {
  const Size canvas = Size(400, 800);
  const EdgeInsets chrome = EdgeInsets.only(top: 60, bottom: 200);

  group('PhotoViewport', () {
    testWidgets('rests inside the area the chrome leaves free', (tester) async {
      final Rect photo = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      // A square photo in a 400x540 window: 400x400, centred.
      expect(photo, const Rect.fromLTWH(0, 130, 400, 400));
      expect(photo.top, greaterThanOrEqualTo(chrome.top));
      expect(photo.bottom, lessThanOrEqualTo(canvas.height - chrome.bottom));
    });

    testWidgets('zooming in lets the photo cover the canvas', (tester) async {
      await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      final Offset center = tester.getCenter(find.byType(PhotoViewport));
      await _pinch(tester, center, 50, 120);
      await tester.pumpAndSettle();
      final Rect zoomed = tester.getRect(find.byKey(const ValueKey('probe')));
      expect(zoomed.width, greaterThan(400));
      expect(zoomed.height, greaterThan(400));
      // The photo is free to slide under the floating chrome.
      expect(zoomed.top, lessThan(chrome.top));
    });

    testWidgets('returning to 1x snaps the photo home', (tester) async {
      final Rect rest = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      final Offset center = tester.getCenter(find.byType(PhotoViewport));
      await _pinch(tester, center, 50, 120);
      await tester.pumpAndSettle();
      expect(
        tester.getRect(find.byKey(const ValueKey('probe'))),
        isNot(equals(rest)),
      );
      // Back to the original pinch: the release pulls the photo home.
      await _pinch(tester, center, 120, 50);
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const ValueKey('probe'))), rest);
    });

    testWidgets('a tap leaves the photo where it is', (tester) async {
      final Rect rest = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      await tester.tap(find.byType(PhotoViewport));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byKey(const ValueKey('probe'))), rest);
    });

    testWidgets('a growing sheet does not move a photo that still fits', (
      tester,
    ) async {
      final Rect rest = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      final Rect grown = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: const EdgeInsets.only(top: 60, bottom: 240),
        aspectRatio: 1,
      );
      expect(grown, rest);
    });

    testWidgets('a sheet that covers the photo slides it up', (tester) async {
      await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      final Rect moved = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: const EdgeInsets.only(top: 60, bottom: 380),
        aspectRatio: 1,
      );
      // Same size, moved up as far as the top bar allows.
      expect(moved.size, const Size(400, 400));
      expect(moved.top, 60);
    });

    testWidgets('a photo that cannot slide up is re-fitted', (tester) async {
      await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 0.5,
      );
      final Rect fitted = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: const EdgeInsets.only(top: 60, bottom: 300),
        aspectRatio: 0.5,
      );
      // Taller than the window: it is scaled down into it instead.
      expect(fitted.height, 440);
      expect(fitted.width, 220);
      expect(fitted.top, 60);
    });

    testWidgets('a shrinking sheet gives the space back', (tester) async {
      await _pump(
        tester,
        canvas: canvas,
        visibleInsets: const EdgeInsets.only(top: 60, bottom: 380),
        aspectRatio: 1,
      );
      final Rect restored = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      // The photo is back to the canonical frame of the larger window.
      expect(restored, const Rect.fromLTWH(0, 130, 400, 400));
    });

    testWidgets('a photo the user zoomed is left alone', (tester) async {
      await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      final Offset center = tester.getCenter(find.byType(PhotoViewport));
      await _pinch(tester, center, 50, 120);
      await tester.pumpAndSettle();
      final Rect zoomed = tester.getRect(find.byKey(const ValueKey('probe')));
      final Rect after = await _pump(
        tester,
        canvas: canvas,
        visibleInsets: const EdgeInsets.only(top: 60, bottom: 380),
        aspectRatio: 1,
      );
      expect(after, zoomed);
    });

    testWidgets('the photo cannot be dragged out of the canvas', (
      tester,
    ) async {
      await _pump(
        tester,
        canvas: canvas,
        visibleInsets: chrome,
        aspectRatio: 1,
      );
      await tester.drag(find.byType(PhotoViewport), const Offset(0, -600));
      await tester.pumpAndSettle();
      final Rect moved = tester.getRect(find.byKey(const ValueKey('probe')));
      expect(moved.top, greaterThanOrEqualTo(0));
      expect(moved.left, greaterThanOrEqualTo(0));
      expect(moved.right, lessThanOrEqualTo(canvas.width));
      expect(moved.bottom, lessThanOrEqualTo(canvas.height));
    });
  });
}
