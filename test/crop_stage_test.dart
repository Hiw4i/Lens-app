import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/crop/crop_stage.dart';

const Key _photoKey = ValueKey('crop-photo');

Future<void> _pumpStage(
  WidgetTester tester, {
  required CropSpec spec,
  required double photoAspect,
  required ValueChanged<Rect> onRectChanged,
}) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Center(
          child: SizedBox(
            width: 400,
            height: 400,
            child: CropStage(
              spec: spec,
              photoAspect: photoAspect,
              photo: const ColoredBox(key: _photoKey, color: Colors.green),
              onRectChanged: onRectChanged,
            ),
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

/// The crop window in screen coordinates, derived the way the stage places
/// it: the picture's rect plus the crop rectangle inside it.
Rect _windowOn(Rect picture, Rect normalized) => Rect.fromLTWH(
  picture.left + normalized.left * picture.width,
  picture.top + normalized.top * picture.height,
  normalized.width * picture.width,
  normalized.height * picture.height,
);

void main() {
  group('crop stage gestures', () {
    testWidgets('a drag moves the picture, not the window', (tester) async {
      Rect? changed;
      final CropSpec spec = const CropSpec(ratio: 1)
          .withRatio(1, CropSpec.nominalSource(4 / 3));
      await _pumpStage(
        tester,
        spec: spec,
        photoAspect: 4 / 3,
        onRectChanged: (rect) => changed = rect,
      );
      final Rect stage = tester.getRect(find.byType(CropStage));
      final Rect picture = tester.getRect(find.byKey(_photoKey));
      await tester.dragFrom(stage.center, const Offset(30, 0));
      await tester.pump();

      expect(changed, isNotNull);
      // The picture travels with the finger, so the crop rectangle moves the
      // other way inside the picture: 30px across a 400px-wide frame is
      // 0.075, applied to the left edge the other way round.
      expect(changed!.left, closeTo(spec.rect.left - 0.075, 0.03));
      expect(changed!.width, closeTo(0.75, 1e-6));
      expect(changed!.height, closeTo(1, 1e-6));
      // The picture itself followed the finger, by the same 30px.
      expect(tester.getRect(find.byKey(_photoKey)).left, picture.left + 30);
    });

    testWidgets('the window keeps its place while the picture moves', (
      tester,
    ) async {
      Rect? changed;
      final CropSpec spec = const CropSpec(ratio: 1)
          .withRatio(1, CropSpec.nominalSource(4 / 3));
      await _pumpStage(
        tester,
        spec: spec,
        photoAspect: 4 / 3,
        onRectChanged: (rect) => changed = rect,
      );
      final Rect stage = tester.getRect(find.byType(CropStage));
      final Rect windowBefore = _windowOn(
        tester.getRect(find.byKey(_photoKey)),
        spec.rect,
      );
      await tester.dragFrom(stage.center, const Offset(30, 0));
      await tester.pump();

      expect(changed, isNotNull);
      final Rect windowAfter = _windowOn(
        tester.getRect(find.byKey(_photoKey)),
        changed!,
      );
      expect(windowAfter.left, closeTo(windowBefore.left, 0.5));
      expect(windowAfter.top, closeTo(windowBefore.top, 0.5));
    });

    testWidgets('a locked window resizes from a corner with its ratio', (
      tester,
    ) async {
      Rect? changed;
      await _pumpStage(
        tester,
        spec: const CropSpec(ratio: 1)
            .withRatio(1, CropSpec.nominalSource(4 / 3)),
        photoAspect: 4 / 3,
        onRectChanged: (rect) => changed = rect,
      );
      final Rect stage = tester.getRect(find.byType(CropStage));
      // The max square window is 300×300 inside the 400×300 frame, so its
      // top-left corner sits 50 px in from the stage's left and top.
      await tester.dragFrom(
        stage.topLeft + const Offset(50, 50),
        const Offset(50, 50),
      );
      await tester.pump();

      expect(changed, isNotNull);
      // The corner must track the finger: a 50px drag in a 400x300 frame
      // shrinks the anchored 300px square to 250px (0.625 normalized width).
      // The old nominal-source divisor shrank it to only ~285px (0.71), the
      // "resize feels stuck" bug found on a real phone.
      expect(changed!.right, closeTo(0.875, 1e-6));
      expect(changed!.bottom, closeTo(1, 1e-6));
      expect(changed!.width, lessThan(0.68));
      expect(changed!.left, greaterThan(0.21));
      expect(changed!.top, greaterThan(0.12));
      final Rect pixels = const CropSpec(ratio: 1)
          .copyWith(rect: changed)
          .pixelRect(CropSpec.nominalSource(4 / 3));
      expect(pixels.width, closeTo(pixels.height, 1e-6));
    });

    testWidgets('a pinch magnifies the picture and tightens the crop', (
      tester,
    ) async {
      Rect? changed;
      await _pumpStage(
        tester,
        spec: const CropSpec(),
        photoAspect: 4 / 3,
        onRectChanged: (rect) => changed = rect,
      );
      final Rect stage = tester.getRect(find.byType(CropStage));
      final Rect picture = tester.getRect(find.byKey(_photoKey));

      // Two fingers parting: the picture must grow under the crop window.
      final Offset center = stage.center;
      final TestGesture left = await tester.startGesture(
        center - const Offset(40, 0),
      );
      final TestGesture right = await tester.startGesture(
        center + const Offset(40, 0),
      );
      await tester.pump();
      await left.moveTo(center - const Offset(90, 0));
      await right.moveTo(center + const Offset(90, 0));
      await tester.pump();
      await left.up();
      await right.up();
      await tester.pump();

      expect(changed, isNotNull);
      // The window kept its place on screen, so the cropped region of the
      // photo got smaller: the pinch is a tighter crop of the same picture.
      // The fingers parted from 80px to 180px, so the picture is 2.25x and
      // the crop keeps 1/2.25 of the frame.
      expect(changed!.width, closeTo(1 / 2.25, 0.02));
      expect(changed!.height, closeTo(1 / 2.25, 0.02));
      // And the picture itself grew by the same factor.
      expect(
        tester.getRect(find.byKey(_photoKey)).width,
        closeTo(picture.width * 2.25, 2),
      );
    });

    testWidgets('a twist does not straighten the photo', (tester) async {
      Rect? changed;
      await _pumpStage(
        tester,
        spec: const CropSpec(),
        photoAspect: 4 / 3,
        onRectChanged: (rect) => changed = rect,
      );
      final Rect stage = tester.getRect(find.byType(CropStage));
      final Offset center = stage.center;
      const double radius = 40;
      // Two fingers turning around the centre, without parting: the photo
      // must stay where it is. Straightening is the panel slider's job.
      final TestGesture a = await tester.startGesture(
        center + const Offset(radius, 0),
      );
      final TestGesture b = await tester.startGesture(
        center - const Offset(radius, 0),
      );
      await tester.pump();
      const double twist = 20 * math.pi / 180;
      await a.moveTo(
        center + Offset(radius * math.cos(twist), radius * math.sin(twist)),
      );
      await b.moveTo(
        center - Offset(radius * math.cos(twist), radius * math.sin(twist)),
      );
      await tester.pump();
      await a.up();
      await b.up();
      await tester.pump();

      // Nothing was cropped and nothing was magnified.
      expect(changed, isNull);
      expect(tester.getRect(find.byKey(_photoKey)).width, 400);
    });
  });

  group('crop stage look', () {
    testWidgets('the area around the photo keeps the editor background', (
      tester,
    ) async {
      // The scrim used to cover the whole stage, so the crop screen turned
      // black instead of showing the editor's background like every other
      // tool. It must stop at the picture's own box.
      final GlobalKey key = GlobalKey();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: RepaintBoundary(
              key: key,
              child: SizedBox(
                width: 400,
                height: 400,
                child: CropStage(
                  // A window in the middle: the photo around it is dimmed,
                  // the photo inside it is not.
                  spec: const CropSpec(
                    rect: Rect.fromLTWH(0.25, 0.25, 0.5, 0.5),
                  ),
                  photoAspect: 4 / 3,
                  photo: const ColoredBox(key: _photoKey, color: Colors.red),
                  onRectChanged: (_) {},
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      await tester.runAsync(() async {
        final RenderRepaintBoundary boundary =
            key.currentContext!.findRenderObject()! as RenderRepaintBoundary;
        final ui.Image image = await boundary.toImage();
        final ByteData? data = await image.toByteData(
          format: ui.ImageByteFormat.rawRgba,
        );
        final Uint8List bytes = data!.buffer.asUint8List();

        int alphaAt(int x, int y) => bytes[(y * image.width + x) * 4 + 3];
        int lumaAt(int x, int y) {
          final int i = (y * image.width + x) * 4;
          return bytes[i] + bytes[i + 1] + bytes[i + 2];
        }

        // The photo frame is 400x300 inside the 400x400 stage: the strip
        // above it belongs to the editor, so nothing is painted there.
        expect(alphaAt(10, 10), 0);
        // The photo around the window is dimmed, the photo inside it is not.
        expect(lumaAt(10, 200), lessThan(lumaAt(200, 200)));
      });
    });
  });
}
