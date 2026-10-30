import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/crop/crop_cpu.dart';
import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

/// True when every corner of [crop] maps back inside the turned photo.
///
/// Comparing only against the rotated bounding box is too weak: that box
/// includes the transparent corners straightening creates.
bool _insideRotatedPhoto(Rect crop, CropSpec spec, Size source) {
  final Size turned = spec.turnedSize(source);
  final Size frame = spec.rotatedSize(source);
  if (!frame.isFinite || frame.isEmpty) return false;
  final double t = spec.angleDegrees * math.pi / 180.0;
  final double c = math.cos(t);
  final double s = math.sin(t);
  final Offset center = Offset(frame.width / 2, frame.height / 2);
  const double eps = 1e-6;
  for (final corner in <Offset>[
    crop.topLeft,
    crop.topRight,
    crop.bottomLeft,
    crop.bottomRight,
  ]) {
    final double dx = corner.dx - center.dx;
    final double dy = corner.dy - center.dy;
    // Inverse of the clockwise screen rotation used by the stage/exporter.
    final double u = dx * c + dy * s;
    final double v = -dx * s + dy * c;
    if (u < -turned.width / 2 - eps ||
        u > turned.width / 2 + eps ||
        v < -turned.height / 2 - eps ||
        v > turned.height / 2 + eps) {
      return false;
    }
  }
  return true;
}

void main() {
  group('CropSpec geometry', () {
    const Size landscape = Size(4000, 3000);
    const Size portrait = Size(3000, 4000);

    test('quarter turns swap the axes, two turns restore the size', () {
      const one = CropSpec(quarterTurns: 1);
      const two = CropSpec(quarterTurns: 2);
      const four = CropSpec(quarterTurns: 4);
      expect(one.turnedSize(landscape), const Size(3000, 4000));
      expect(two.turnedSize(landscape), landscape);
      // Rendered paths normalise mod 4; the spec mirrors that.
      expect(four.turnedSize(landscape), landscape);
    });

    test('straightening grows the rotated frame, 0 degrees does not', () {
      expect(const CropSpec().rotatedSize(landscape), landscape);
      const Size turned = Size(4000, 3000);
      final Size rotated = const CropSpec(angleDegrees: 30)
          .rotatedSize(landscape);
      // Bounding box of a 4000x3000 box rotated 30 degrees:
      // w' = W|cos| + H|sin|, h' = W|sin| + H|cos|.
      expect(
        rotated.width,
        closeTo(
          turned.width * math.cos(math.pi / 6) +
              turned.height * math.sin(math.pi / 6),
          0.5,
        ),
      );
      expect(
        rotated.height,
        closeTo(
          turned.width * math.sin(math.pi / 6) +
              turned.height * math.cos(math.pi / 6),
          0.5,
        ),
      );
      expect(rotated.width, greaterThan(turned.width));
    });

    test('90 degree turn still measures as a plain axis swap', () {
      const spec = CropSpec(quarterTurns: 1);
      expect(spec.rotatedSize(landscape), const Size(3000, 4000));
    });

    test('safeRect is the full frame at 0 and a centred inset at 45', () {
      expect(const CropSpec().safeRect(landscape), CropSpec.kFullRect);

      // A square rotated 45° only covers the centred square with half the
      // side of its bounding box.
      const Size square = Size(1000, 1000);
      final Rect safe = const CropSpec(angleDegrees: 45).safeRect(square);
      expect(safe.left, closeTo(0.25, 1e-9));
      expect(safe.top, closeTo(0.25, 1e-9));
      expect(safe.width, closeTo(0.5, 1e-9));
      expect(safe.height, closeTo(0.5, 1e-9));
      expect(safe.center, const Offset(0.5, 0.5));
    });

    test('straightened refit never leaves the real photo pixels', () {
      for (final angle in <double>[5, 15, 30, 45]) {
        final CropSpec spec = CropSpec(angleDegrees: angle);
        final CropSpec refitted = spec.refitted(landscape);
        expect(
          _insideRotatedPhoto(refitted.pixelRect(landscape), spec, landscape),
          isTrue,
          reason: 'angle $angle',
        );
      }
    });

    test('largestWithRatio height-bounds when bounds are too wide', () {
      const Rect bounds = Rect.fromLTWH(0, 0, 400, 200);
      final Rect square = CropSpec.largestWithRatio(bounds, 1);
      expect(square.width, closeTo(200, 1e-9));
      expect(square.height, closeTo(200, 1e-9));
      expect(square.center.dx, closeTo(200, 1e-9));
      expect(square.center.dy, closeTo(100, 1e-9));
    });

    test('largestWithRatio width-bounds when bounds are too tall', () {
      const Rect bounds = Rect.fromLTWH(0, 0, 200, 400);
      final Rect square = CropSpec.largestWithRatio(bounds, 1);
      expect(square.width, closeTo(200, 1e-9));
      expect(square.height, closeTo(200, 1e-9));
      expect(square.center.dy, closeTo(200, 1e-9));
    });

    test('null ratio returns the bounds untouched', () {
      const Rect bounds = Rect.fromLTWH(10, 20, 300, 400);
      expect(CropSpec.largestWithRatio(bounds, null), bounds);
    });

    test(
      'clamp keeps a free window inside the frame and above the minimum',
      () {
        const spec = CropSpec();
        const Rect bounds = Rect.fromLTWH(0, 0, 1000, 1000);
        // Dragged far past the right edge.
        final Rect out = spec.clamp(
          const Rect.fromLTWH(900, 0, 200, 200),
          bounds,
        );
        expect(out.right, lessThanOrEqualTo(bounds.right));
        expect(out.width, closeTo(200, 1e-9));

        // Collapsed to nothing.
        final Rect tiny = spec.clamp(const Rect.fromLTWH(0, 0, 1, 1), bounds);
        expect(
          tiny.width,
          greaterThanOrEqualTo(bounds.shortestSide * CropSpec.kMinFraction),
        );
        expect(
          tiny.height,
          greaterThanOrEqualTo(bounds.shortestSide * CropSpec.kMinFraction),
        );
      },
    );

    test('clamp in normalized space is the one refitted uses', () {
      const spec = CropSpec();
      // At 0° the safe area is the full frame, so an out-of-range normalized
      // window must be pulled back inside 0..1.
      final Rect out = spec.clamp(
        const Rect.fromLTWH(0.8, 0.8, 0.9, 0.9),
        CropSpec.kFullRect,
      );
      expect(out.right, lessThanOrEqualTo(1.0));
      expect(out.bottom, lessThanOrEqualTo(1.0));
    });

    test('refit after straightening keeps the window inside the new frame', () {
      const spec = CropSpec(angleDegrees: 20);
      final CropSpec refitted = spec.refitted(landscape);
      // Assert in PIXELS. Comparing the normalized rect against the pixel
      // frame passed trivially (0..1 always fits inside 0..3000) and so
      // proved nothing.
      final Size frame = spec.rotatedSize(landscape);
      final Rect pixels = refitted.pixelRect(landscape);
      expect(pixels.left, greaterThanOrEqualTo(0.0));
      expect(pixels.top, greaterThanOrEqualTo(0.0));
      expect(pixels.right, lessThanOrEqualTo(frame.width + 0.5));
      expect(pixels.bottom, lessThanOrEqualTo(frame.height + 0.5));
      // Straightening really did grow the frame past the source.
      expect(frame.width, greaterThan(landscape.width));
    });

    test('withRatio snaps to the largest matching shape', () {
      const spec = CropSpec(rect: Rect.fromLTWH(0.1, 0.1, 0.2, 0.2));
      final CropSpec locked = spec.withRatio(1, portrait);
      expect(locked.ratio, 1);

      final Size frame = locked.rotatedSize(portrait);
      final Rect pixels = locked.pixelRect(portrait);
      expect(pixels.width, closeTo(pixels.height, 1e-6));
      expect(pixels.width, closeTo(math.min(frame.width, frame.height), 1e-6));
      expect(frame, const Size(3000, 4000));
    });

    test('an invalid ratio cannot poison the spec', () {
      const CropSpec locked = CropSpec(ratio: 1);
      final CropSpec invalid = locked.withRatio(double.nan, portrait);
      expect(invalid.ratio, 1);
      final CropSpec cleared = locked.withRatio(null, portrait);
      expect(cleared.ratio, isNull);
    });

    test('refit with a locked ratio preserves the user window', () {
      const spec = CropSpec(ratio: 1, rect: Rect.fromLTWH(0.1, 0.1, 0.2, 0.2));
      final CropSpec refitted = spec.refitted(portrait);
      // The stored rect must stay NORMALIZED. Comparing it straight against
      // the pixel frame is what let the pixel rect leak into this field.
      expect(refitted.rect.width, lessThanOrEqualTo(1.0));
      expect(refitted.rect.height, lessThanOrEqualTo(1.0));
      expect(refitted.rect.left, greaterThanOrEqualTo(0.0));
      expect(refitted.rect.top, greaterThanOrEqualTo(0.0));

      // 0.2 × 3000 = 600 px wide; the locked square keeps that width and
      // centre instead of jumping to the 3000 px maximum.
      final Rect pixels = refitted.pixelRect(portrait);
      expect(pixels.width, closeTo(600, 1e-6));
      expect(pixels.height, closeTo(600, 1e-6));
      expect(pixels.center.dx, closeTo(600, 1e-6));
      expect(pixels.center.dy, closeTo(800, 1e-6));
    });

    test('resizeWindow with a lock scales from the opposite corner', () {
      const spec = CropSpec(ratio: 1);
      const Size source = Size(1000, 1000);
      const Rect start = Rect.fromLTWH(0.2, 0.2, 0.4, 0.4);
      final Rect grown = spec.resizeWindow(
        start: start,
        corner: CropCorner.bottomRight,
        drag: const Offset(0.1, 0),
        source: source,
      );
      expect(grown.left, closeTo(0.2, 1e-9));
      expect(grown.top, closeTo(0.2, 1e-9));
      expect(grown.width, closeTo(0.5, 1e-9));
      expect(grown.height, closeTo(0.5, 1e-9));

      final Rect shrunk = spec.resizeWindow(
        start: start,
        corner: CropCorner.topLeft,
        drag: const Offset(0.1, 0.1),
        source: source,
      );
      expect(shrunk.right, closeTo(0.6, 1e-9));
      expect(shrunk.bottom, closeTo(0.6, 1e-9));
      expect(shrunk.width, closeTo(0.3, 1e-9));
      expect(shrunk.height, closeTo(0.3, 1e-9));
    });

    test('resizeWindow free drag moves only the grabbed edges', () {
      const spec = CropSpec();
      const Rect start = Rect.fromLTWH(0.2, 0.2, 0.4, 0.4);
      final Rect out = spec.resizeWindow(
        start: start,
        corner: CropCorner.bottomRight,
        drag: const Offset(0.1, 0.05),
        source: const Size(1000, 1000),
      );
      expect(out.left, closeTo(0.2, 1e-9));
      expect(out.top, closeTo(0.2, 1e-9));
      expect(out.width, closeTo(0.5, 1e-9));
      expect(out.height, closeTo(0.45, 1e-9));
    });

    test('isDefault only for an untouched spec', () {
      expect(const CropSpec().isDefault, isTrue);
      expect(const CropSpec(quarterTurns: 1).isDefault, isFalse);
      expect(const CropSpec(angleDegrees: 0.5).isDefault, isFalse);
      expect(const CropSpec(ratio: 1).isDefault, isFalse);
      expect(
        const CropSpec(rect: Rect.fromLTWH(0, 0, 0.5, 0.5)).isDefault,
        isFalse,
      );
    });

    test('clearRatio really clears, and set keeps the previous one', () {
      const spec = CropSpec(ratio: 1);
      expect(spec.copyWith().ratio, 1);
      expect(spec.copyWith(clearRatio: true).ratio, isNull);
    });

    test('nominalSource preserves the aspect it was handed', () {
      expect(
        CropSpec.nominalSource(4 / 3).width /
            CropSpec.nominalSource(4 / 3).height,
        closeTo(4 / 3, 1e-9),
      );
      expect(
        CropSpec.nominalSource(0.5).width / CropSpec.nominalSource(0.5).height,
        closeTo(0.5, 1e-9),
      );
    });

    test('resultAspect follows turns, angle and the window', () {
      const Size source = Size(4000, 3000);
      expect(const CropSpec().resultAspect(source), closeTo(4 / 3, 1e-6));
      expect(
        const CropSpec(quarterTurns: 1).resultAspect(source),
        closeTo(3 / 4, 1e-6),
      );
      const CropSpec half = CropSpec(rect: Rect.fromLTWH(0.25, 0, 0.5, 1));
      expect(half.resultAspect(source), closeTo(2 / 3, 1e-6));
      expect(
        const CropSpec(angleDegrees: 45).resultAspect(source).isFinite,
        isTrue,
      );
      // Degenerate input must never become NaN/Infinity in layout.
      expect(const CropSpec().resultAspect(Size.zero), 1);
    });
  });

  group('CropSpec in the editor state', () {
    test('crop is part of isDefault', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      expect(container.read(editorStateProvider).isDefault, isTrue);
      container.read(editorStateProvider.notifier).clearCrop();
      expect(container.read(editorStateProvider).isDefault, isTrue);
    });

    test('a whole crop session collapses into ONE undo entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      final Size source = CropSpec.nominalSource(4 / 3);

      notifier.setTool(EditorTool.crop);
      expect(container.read(editorStateProvider).undoDepth, 0);

      notifier.setCropAngle(6, source);
      notifier.setCropRect(const Rect.fromLTWH(0.1, 0.1, 0.7, 0.7), source);
      notifier.setCropRatio(1, source);
      notifier.rotateCropQuarter(source);
      // Still inside the session: nothing committed yet.
      expect(container.read(editorStateProvider).undoDepth, 0);

      notifier.setTool(EditorTool.adjust);
      expect(container.read(editorStateProvider).undoDepth, 1);

      // And one undo puts everything back.
      notifier.undo();
      expect(container.read(editorStateProvider).crop.isDefault, isTrue);
    });

    test('a crop session that changed nothing commits nothing', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setTool(EditorTool.crop);
      notifier.setTool(EditorTool.adjust);
      expect(container.read(editorStateProvider).undoDepth, 0);
    });

    test('angle is clamped to the straighten range', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      final Size source = CropSpec.nominalSource(1);
      notifier.setCropAngle(400, source);
      expect(
        container.read(editorStateProvider).crop.angleDegrees,
        CropSpec.kMaxAngleDegrees,
      );
      notifier.setCropAngle(-400, source);
      expect(
        container.read(editorStateProvider).crop.angleDegrees,
        -CropSpec.kMaxAngleDegrees,
      );
      notifier.setCropAngle(double.nan, source);
      expect(
        container.read(editorStateProvider).crop.angleDegrees,
        -CropSpec.kMaxAngleDegrees,
      );
    });

    test('a locked window can move and keeps its size', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      final Size source = CropSpec.nominalSource(4 / 3);
      notifier.setCropRatio(1, source);
      final CropSpec before = container.read(editorStateProvider).crop;
      notifier.setCropRect(before.rect.shift(const Offset(0.01, 0)), source);
      final CropSpec after = container.read(editorStateProvider).crop;
      expect(after.ratio, 1);
      expect(after.rect.left, greaterThan(before.rect.left));
      expect(
        after.pixelRect(source).width,
        closeTo(before.pixelRect(source).width, 1e-6),
      );
      expect(
        after.pixelRect(source).height,
        closeTo(before.pixelRect(source).height, 1e-6),
      );
    });

    test('a locked window is not re-maximised by a direct rect edit', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      final Size source = CropSpec.nominalSource(4 / 3);
      notifier.setCropRatio(1, source);
      final Size frame = const CropSpec().rotatedSize(source);
      const double side = 900;
      notifier.setCropRect(
        Rect.fromLTWH(0.2, 0.25, side / frame.width, side / frame.height),
        source,
      );
      final Rect pixels = container
          .read(editorStateProvider)
          .crop
          .pixelRect(source);
      expect(pixels.width, closeTo(side, 1e-6));
      expect(pixels.height, closeTo(side, 1e-6));
      expect(pixels.width, lessThan(3000));
    });

    test('angle changes preserve the window pixel size', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      final Size source = CropSpec.nominalSource(4 / 3);
      notifier.setCropRatio(1, source);
      final Size frame = const CropSpec().rotatedSize(source);
      const double side = 800;
      notifier.setCropRect(
        Rect.fromLTWH(0.3, 0.2, side / frame.width, side / frame.height),
        source,
      );
      final double before = container
          .read(editorStateProvider)
          .crop
          .pixelRect(source)
          .width;
      notifier.setCropAngle(10, source);
      final double after = container
          .read(editorStateProvider)
          .crop
          .pixelRect(source)
          .width;
      expect(after, closeTo(before, 1e-6));
    });

    test('reset preserves photoAspect while clearing crop', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      final Size source = CropSpec.nominalSource(1.5);
      notifier.setPhotoAspect(1.5);
      notifier.setCropAngle(5, source);
      notifier.reset();
      final state = container.read(editorStateProvider);
      expect(state.photoAspect, 1.5);
      expect(state.crop.isDefault, isTrue);
    });

    test('non-finite photo aspects are ignored', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setPhotoAspect(double.nan);
      notifier.setPhotoAspect(double.infinity);
      notifier.setPhotoAspect(0);
      expect(container.read(editorStateProvider).photoAspect, 1);
      notifier.setPhotoAspect(1.5);
      expect(container.read(editorStateProvider).photoAspect, 1.5);
    });

    test('reset clears crop too', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      final Size source = CropSpec.nominalSource(1);
      notifier.setCropAngle(5, source);
      notifier.reset();
      expect(container.read(editorStateProvider).crop.isDefault, isTrue);
    });

    test(
      'encodeCropGeometry is null when untouched, plain doubles otherwise',
      () {
        final container = ProviderContainer.test();
        addTearDown(container.dispose);
        final notifier = container.read(editorStateProvider.notifier);
        expect(
          container.read(editorStateProvider).encodeCropGeometry(),
          isNull,
        );
        notifier.setCropAngle(3, CropSpec.nominalSource(1));
        final geometry = container
            .read(editorStateProvider)
            .encodeCropGeometry();
        expect(geometry, isNotNull);
        expect(geometry!.angleDegrees, 3);
        expect(geometry.quarterTurns, 0);
      },
    );

    test('photoAspect is layout, never an undo entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final notifier = container.read(editorStateProvider.notifier);
      notifier.setPhotoAspect(1.5);
      expect(container.read(editorStateProvider).photoAspect, 1.5);
      expect(container.read(editorStateProvider).undoDepth, 0);
      expect(container.read(editorStateProvider).isDefault, isTrue);
    });
  });

  group('CPU crop', () {
    CropGeometry geom(
      double angle,
      double l,
      double t,
      double w,
      double h, [
      int turns = 0,
    ]) => (
      angleDegrees: angle,
      left: l,
      top: t,
      width: w,
      height: h,
      quarterTurns: turns,
    );

    test('a quarter turn really swaps the output dimensions', () {
      final img.Image src = img.Image(width: 80, height: 40, numChannels: 3);
      final img.Image out = applyCropGeometry(src, geom(0, 0, 0, 1, 1, 1));
      expect(out.width, 40);
      expect(out.height, 80);
    });

    test('a centred half-frame crop cuts the dimensions in half', () {
      final img.Image src = img.Image(width: 100, height: 100, numChannels: 3);
      final img.Image out = applyCropGeometry(
        src,
        geom(0, 0.25, 0.25, 0.5, 0.5),
      );
      expect(out.width, 50);
      expect(out.height, 50);
    });

    test('a whole-frame spec is a no-op passthrough', () {
      final img.Image src = img.Image(width: 60, height: 30, numChannels: 3);
      final img.Image out = applyCropGeometry(src, geom(0, 0, 0, 1, 1));
      expect(identical(out, src), isTrue);
    });

    test('an out-of-range window is pulled back inside the frame', () {
      final img.Image src = img.Image(width: 100, height: 100, numChannels: 3);
      final img.Image out = applyCropGeometry(
        src,
        geom(0, 0.95, 0.95, 0.4, 0.4),
      );
      expect(out.width, greaterThanOrEqualTo(1));
      expect(out.height, greaterThanOrEqualTo(1));
      expect(out.width, lessThanOrEqualTo(100));
      expect(out.height, lessThanOrEqualTo(100));
    });

    test('straightening without cropping only changes the frame size', () {
      final img.Image src = img.Image(width: 100, height: 100, numChannels: 3);
      final img.Image out = applyCropGeometry(src, geom(30, 0, 0, 1, 1));
      // A 45-degree turn of a square needs more room on both axes.
      expect(out.width, greaterThan(100));
      expect(out.height, greaterThan(100));
    });

    test('grade resolves masks in the source frame before crop', () {
      // Mid-gray 64x64 so the only possible pixel difference is the radial
      // mask. The mask sits in the LEFT half at (0.2, 0.5) with r=0.2;
      // the crop keeps the RIGHT half. Grade-first therefore leaves every
      // exported pixel untouched, while crop-first would re-centre the mask
      // inside the 32px result and visibly brighten it.
      final img.Image src = img.Image(width: 64, height: 64, numChannels: 3);
      for (var y = 0; y < 64; y++) {
        for (var x = 0; x < 64; x++) {
          src.setPixelRgb(x, y, 128, 128, 128);
        }
      }
      final Uint8List png = Uint8List.fromList(img.encodePng(src));
      final CropGeometry crop = geom(0, 0.5, 0, 0.5, 1);
      final List<double> armed = const LensParams(
        selMode: 1,
        selCx: 0.2,
        selCy: 0.5,
        selRadius: 0.2,
        selFeather: 0.5,
        selStrength: 1,
        selExp: 2,
      ).toUniforms();
      final Uint8List graded = applyLensGrade(png, armed, 0, null, null, crop);
      final Uint8List neutral = applyLensGrade(
        png,
        LensParams.identity.toUniforms(),
        0,
        null,
        null,
        crop,
      );
      expect(graded, equals(neutral));
    });
  });
}
