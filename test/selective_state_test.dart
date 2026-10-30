import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/selective/mask_raster.dart';
import 'package:lens/features/selective/selective_mask.dart';

/// Non-square solid helper: the Task 4.4 aspectOverride recomputes the
/// radial aspect as frame w/h (2.0 here), so garbage in slot 26 must not
/// change the output bytes.
img.Image _solidRect(int w, int h, int v) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (int y = 0; y < h; y++) {
    for (int x = 0; x < w; x++) {
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

void main() {
  group('selective state (Task 4.4)', () {
    test('default is off and maps to selMode 0', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final s = container.read(editorStateProvider);
      expect(s.selective, equals(const SelectiveState()));
      expect(s.selective.isDefault, isTrue);
      expect(s.isDefault, isTrue);
      final p = s.toLensParams();
      expect(p.selMode, equals(0));
      expect(p.selStrength, equals(0.0));
      expect(s.encodeSelectiveBrush(), isNull);
    });

    test('brush mode with empty strokes falls back to off (mode 0)', () {
      // Task 4.3 concern #2: empty brush must grade nothing. The CPU
      // treats a missing raster as neutral, so the mapping emits mode 0
      // for the same reason (not a stray full-frame grade).
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.brush);
      final s = container.read(editorStateProvider);
      expect(s.selective.active, isTrue);
      expect(s.selective.strokes, isEmpty);
      expect(s.toLensParams().selMode, equals(0));
      expect(s.encodeSelectiveBrush(), isNull);
    });

    test('brush drag commits exactly one history entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.brush);
      expect(container.read(editorStateProvider).undoDepth, equals(1));
      n.beginStroke();
      n.addBrushPoint(0.1, 0.1);
      n.addBrushPoint(0.2, 0.2);
      n.addBrushPoint(0.3, 0.3);
      n.endStroke();
      final s = container.read(editorStateProvider);
      expect(s.selective.strokes.length, equals(1));
      expect(s.selective.strokes.single.points.length, equals(3));
      expect(s.undoDepth, equals(2));
      n.undo();
      expect(container.read(editorStateProvider).selective.strokes, isEmpty);
      n.redo();
      expect(
        container.read(editorStateProvider).selective.strokes.single.points,
        hasLength(3),
      );
    });

    test('aspect updates skip history and survive undo', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.radial);
      expect(container.read(editorStateProvider).undoDepth, equals(1));
      n.setSelectiveAspect(1.78);
      // Layout, not grade: no history entry ...
      expect(container.read(editorStateProvider).undoDepth, equals(1));
      expect(
        container.read(editorStateProvider).selective.geometry.aspect,
        equals(1.78),
      );
      n.setSelectiveAspect(1.78);
      expect(container.read(editorStateProvider).undoDepth, equals(1));
      // ... and undo preserves the live aspect instead of restoring the
      // snapshot's one.
      n.undo();
      final s = container.read(editorStateProvider);
      expect(s.selective.active, isFalse);
      expect(s.selective.geometry.aspect, equals(1.78));
    });

    test('aspect-only change inside a stroke commits nothing', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.beginStroke();
      n.setSelectiveAspect(2.0);
      n.endStroke();
      expect(container.read(editorStateProvider).undoDepth, equals(0));
    });

    test('reset clears selective but preserves the live aspect', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.radial);
      n.setSelectiveStrength(50);
      n.setSelectiveAspect(1.78);
      n.reset();
      final s = container.read(editorStateProvider);
      expect(s.selective.active, isFalse);
      expect(s.selective.strength, equals(100));
      expect(s.isDefault, isTrue);
      expect(s.selective.geometry.aspect, equals(1.78));
    });

    test('invert/strength/geometry round-trip through params and undo', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.radial);
      n.setSelectiveInvert(true);
      n.setSelectiveStrength(50);
      n.setSelectiveCenter(0.25, 0.75);
      n.setSelectiveExp(1.5);
      n.setSelectiveCon(50);
      n.setSelectiveSat(-25);
      LensParams p = container.read(editorStateProvider).toLensParams();
      expect(p.selMode, equals(1));
      expect(p.selInvert, equals(1));
      expect(p.selStrength, equals(0.5));
      expect(p.selCx, equals(0.25));
      expect(p.selCy, equals(0.75));
      expect(p.selExp, equals(1.5));
      expect(p.selCon, equals(0.5));
      expect(p.selSat, equals(-0.25));
      n.undo(); // sat
      n.undo(); // con
      n.undo(); // exp
      p = container.read(editorStateProvider).toLensParams();
      expect(p.selExp, equals(0.0));
      expect(p.selCon, equals(0.0));
      expect(p.selSat, equals(0.0));
      expect(p.selInvert, equals(1));
      n.undo(); // center
      n.undo(); // strength
      expect(
        container.read(editorStateProvider).selective.strength,
        equals(100),
      );
      n.undo(); // invert
      expect(
        container.read(editorStateProvider).toLensParams().selInvert,
        equals(0),
      );
    });

    test('selMode mapping: radial 1, linear 2, brush+stroke 3', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.radial);
      expect(
        container.read(editorStateProvider).toLensParams().selMode,
        equals(1),
      );
      n.setSelectiveMode(SelectiveMode.linear);
      expect(
        container.read(editorStateProvider).toLensParams().selMode,
        equals(2),
      );
      n.setSelectiveMode(SelectiveMode.brush);
      // Empty brush still off ...
      expect(
        container.read(editorStateProvider).toLensParams().selMode,
        equals(0),
      );
      n.beginStroke();
      n.addBrushPoint(0.5, 0.5);
      n.endStroke();
      expect(
        container.read(editorStateProvider).toLensParams().selMode,
        equals(3),
      );
    });

    test('strength 0 forces mode 0 (stage skipped)', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setSelectiveMode(SelectiveMode.radial);
      n.setSelectiveStrength(0);
      expect(
        container.read(editorStateProvider).toLensParams().selMode,
        equals(0),
      );
    });

    test('encodeSelectiveBrush null unless brush+active+painted', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      // Radial active: not a brush raster.
      n.setSelectiveMode(SelectiveMode.radial);
      expect(
        container.read(editorStateProvider).encodeSelectiveBrush(),
        isNull,
      );
      // Brush active but empty: nothing to rasterize.
      n.setSelectiveMode(SelectiveMode.brush);
      expect(
        container.read(editorStateProvider).encodeSelectiveBrush(),
        isNull,
      );
      // Painted then deactivated: off means off.
      n.beginStroke();
      n.addBrushPoint(0.5, 0.5);
      n.endStroke();
      n.setSelectiveActive(false);
      expect(
        container.read(editorStateProvider).encodeSelectiveBrush(),
        isNull,
      );
      // Painted + active: flat codec round-trips.
      n.setSelectiveActive(true);
      final List<double>? flat = container
          .read(editorStateProvider)
          .encodeSelectiveBrush();
      expect(flat, isNotNull);
      expect(
        decodeBrushStrokes(flat!),
        equals(container.read(editorStateProvider).selective.strokes),
      );
    });

    test('clearSelective is one push and no-op at default', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.clearSelective();
      expect(container.read(editorStateProvider).undoDepth, equals(0));
      n.setSelectiveMode(SelectiveMode.linear);
      n.setSelectiveStrength(40);
      expect(container.read(editorStateProvider).undoDepth, equals(2));
      n.clearSelective();
      final s = container.read(editorStateProvider);
      expect(s.selective.active, isFalse);
      expect(s.isDefault, isTrue);
      expect(s.undoDepth, equals(3));
      n.clearSelective();
      expect(container.read(editorStateProvider).undoDepth, equals(3));
      n.undo();
      expect(container.read(editorStateProvider).selective.active, isTrue);
    });

    test('addBrushPoint ignored unless brush+active', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      // Inactive brush: no-op, no implicit stroke opened.
      n.setSelectiveActive(false);
      n.addBrushPoint(0.5, 0.5);
      expect(container.read(editorStateProvider).selective.strokes, isEmpty);
      expect(container.read(editorStateProvider).undoDepth, equals(0));
      // Active radial: points are not brush input.
      n.setSelectiveMode(SelectiveMode.radial);
      n.addBrushPoint(0.5, 0.5);
      expect(container.read(editorStateProvider).selective.strokes, isEmpty);
      expect(container.read(editorStateProvider).undoDepth, equals(1));
    });

    test('CPU ignores the aspect slot (frame w/h wins) — parity', () {
      final srcBytes = img.encodePng(_solidRect(64, 32, 128));
      List<double> uniforms(double aspect) =>
          const LensParams(selMode: 1, selStrength: 1.0, selExp: 1.0)
              .copyWith(
                selCx: 0.5,
                selCy: 0.5,
                selRadius: 0.3,
                selFeather: 0.5,
                selAspect: aspect,
              )
              .toUniforms();
      final Uint8List a = applyLensGrade(srcBytes, uniforms(0.2));
      final Uint8List b = applyLensGrade(srcBytes, uniforms(5.0));
      // Slot-26 garbage cannot move the export ellipse: byte-identical ...
      expect(a, equals(b));
      // ... and the stage is really applied (differs from neutral).
      expect(
        a,
        isNot(
          equals(applyLensGrade(srcBytes, const LensParams().toUniforms())),
        ),
      );
    });
  });
}
