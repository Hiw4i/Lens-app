import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/crop/crop_viewport.dart';

/// Lays out [CropViewport] in a host box and returns it, so tests can reason
/// about viewport-relative geometry instead of the 800x600 test surface.
Future<Rect> _pumpViewport(
  WidgetTester tester, {
  required CropSpec spec,
  required double photoAspect,
  required Size hostSize,
  required List<Widget> children,
}) async {
  await tester.pumpWidget(
    Directionality(
      textDirection: TextDirection.ltr,
      child: Align(
        alignment: Alignment.topLeft,
        child: SizedBox(
          width: hostSize.width,
          height: hostSize.height,
          child: CropViewport(
            spec: spec,
            photoAspect: photoAspect,
            child: Stack(children: children),
          ),
        ),
      ),
    ),
  );
  return tester.getRect(find.byType(CropViewport));
}

void main() {
  group('CropViewport', () {
    testWidgets('an untouched spec leaves the child alone', (tester) async {
      const Key probe = ValueKey('probe');
      final Rect viewport = await _pumpViewport(
        tester,
        spec: const CropSpec(),
        photoAspect: 2,
        hostSize: const Size(200, 100),
        children: [const Positioned.fill(child: SizedBox.expand(key: probe))],
      );
      expect(
        find.descendant(
          of: find.byType(CropViewport),
          matching: find.byType(ClipRect),
        ),
        findsNothing,
      );
      expect(tester.getRect(find.byKey(probe)), viewport);
    });

    testWidgets('a half crop maps the kept half onto the host', (tester) async {
      const Key probe = ValueKey('probe');
      final Rect viewport = await _pumpViewport(
        tester,
        spec: const CropSpec(rect: Rect.fromLTWH(0.5, 0, 0.5, 1)),
        photoAspect: 2,
        hostSize: const Size(100, 100),
        // Source is laid out at 2000x1000 (aspect 2). The right half is
        // scaled 0.1: child-local x=100..200 maps to viewport x=0..100.
        children: [
          const Positioned(
            left: 100,
            top: 0,
            width: 100,
            height: 100,
            child: SizedBox.expand(key: probe),
          ),
        ],
      );
      final Rect probeRect = tester.getRect(find.byKey(probe));
      expect(probeRect.width, closeTo(viewport.width, 1e-6));
      expect(probeRect.height, closeTo(viewport.height, 1e-6));
      expect(probeRect.left, closeTo(viewport.left, 1e-6));
      expect(probeRect.top, closeTo(viewport.top, 1e-6));
    });

    testWidgets(
      'quarter turn moves the top-left of the source to the top-right',
      (tester) async {
        const Key probe = ValueKey('probe');
        final Rect viewport = await _pumpViewport(
          tester,
          spec: const CropSpec(quarterTurns: 1),
          photoAspect: 2,
          hostSize: const Size(100, 200),
          // Source 2000x1000 -> child 200x100 before the turn. A 200x200
          // source square sits at local (0,0,20,20) after scaling and becomes
          // parent-local (80,0,20,20) after the clockwise turn.
          children: [
            const Positioned(
              left: 0,
              top: 0,
              width: 20,
              height: 20,
              child: SizedBox.expand(key: probe),
            ),
          ],
        );
        final Rect probeRect = tester.getRect(find.byKey(probe));
        expect(probeRect.left - viewport.left, closeTo(80, 1e-6));
        expect(probeRect.top - viewport.top, closeTo(0, 1e-6));
        expect(probeRect.width, closeTo(20, 1e-6));
        expect(probeRect.height, closeTo(20, 1e-6));
      },
    );

    testWidgets('straightening rotates the child about the frame centre', (
      tester,
    ) async {
      const Key probe = ValueKey('probe');
      final Rect viewport = await _pumpViewport(
        tester,
        spec: const CropSpec(angleDegrees: 180),
        photoAspect: 1,
        hostSize: const Size(100, 100),
        // Source 1000x1000 -> child 100x100. A 100x100 source square at
        // top-left becomes 10x10 and lands bottom-right after 180 degrees.
        children: [
          const Positioned(
            left: 0,
            top: 0,
            width: 10,
            height: 10,
            child: SizedBox.expand(key: probe),
          ),
        ],
      );
      final Rect probeRect = tester.getRect(find.byKey(probe));
      expect(probeRect.left - viewport.left, closeTo(90, 1e-6));
      expect(probeRect.top - viewport.top, closeTo(90, 1e-6));
    });

    testWidgets('crop plus turn still rounds-trips a source point', (
      tester,
    ) async {
      const Key probe = ValueKey('probe');
      // Square source, quarter turn, then keep the bottom-left quadrant of
      // the turned frame. The probe covers that same quadrant in source
      // coordinates (source bottom-right quadrant), so it must cover the
      // whole viewport.
      final Rect viewport = await _pumpViewport(
        tester,
        spec: const CropSpec(
          quarterTurns: 1,
          rect: Rect.fromLTWH(0, 0.5, 0.5, 0.5),
        ),
        photoAspect: 1,
        hostSize: const Size(100, 100),
        // Source 1000x1000 scales to 200x200. The crop keeps the turned
        // bottom-left quadrant, which is the source BOTTOM-RIGHT quadrant:
        // child-local (100,100,100,100).
        children: [
          const Positioned(
            left: 100,
            top: 100,
            width: 100,
            height: 100,
            child: SizedBox.expand(key: probe),
          ),
        ],
      );
      final Rect probeRect = tester.getRect(find.byKey(probe));
      expect(probeRect.left, closeTo(viewport.left, 1e-6));
      expect(probeRect.top, closeTo(viewport.top, 1e-6));
      expect(probeRect.width, closeTo(viewport.width, 1e-6));
      expect(probeRect.height, closeTo(viewport.height, 1e-6));
    });

    testWidgets('degenerate geometry falls back to the plain child', (
      tester,
    ) async {
      const Key probe = ValueKey('probe');
      await _pumpViewport(
        tester,
        spec: const CropSpec(rect: Rect.fromLTWH(0, 0, 0, 1)),
        photoAspect: 2,
        hostSize: const Size(100, 50),
        children: [const Positioned.fill(child: SizedBox.expand(key: probe))],
      );
      expect(
        tester.getRect(find.byKey(probe)),
        const Rect.fromLTWH(0, 0, 100, 50),
      );
    });
  });
}
