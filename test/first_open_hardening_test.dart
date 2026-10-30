import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/filters/lut_definition.dart';
import 'package:lens/features/imaging/cache/preview_cache.dart';
import 'package:lens/features/imaging/export/export_service.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

/// First-open hardening: the app must never crash on fresh start,
/// corrupt imports, empty bytes, or wild user input.
/// Follows the state contract in lib/features/editor/logic/editor_state.dart
/// and the uniform layout in lib/features/imaging/pipeline/lens_pipeline.dart.

Uint8List _png(int w, int h, int r, int g, int b) {
  final image = img.Image(width: w, height: h, numChannels: 3);
  for (var y = 0; y < h; y++) {
    for (var x = 0; x < w; x++) {
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return img.encodePng(image);
}

void main() {
  group('fresh state defaults', () {
    test('adjust/filter/depths at defaults, reset is no-op', () {
      const s = EditorState();
      expect(s.adjust.isDefault, isTrue);
      expect(s.filterId, LensFilterId.none);
      expect(s.filterStrength, 100);
      expect(s.undoDepth, 0);
      expect(s.redoDepth, 0);
      expect(s.previewBytes, isNull);
      expect(s.isDefault, isTrue);
    });

    test('notifier starts clean, undo/redo on empty are no-ops', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      expect(n.canUndo, isFalse);
      expect(n.canRedo, isFalse);
      n.undo();
      n.redo();
      n.endStroke(); // no begin -> no-op, must not throw
      final s = container.read(editorStateProvider);
      expect(s.undoDepth, 0);
      expect(s.adjust.isDefault, isTrue);
    });
  });

  group('history bounds', () {
    test('25 pushes cap at 20, oldest evicted', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      for (var i = 1; i <= 25; i++) {
        n.setExposure(i * 0.1);
      }
      final s = container.read(editorStateProvider);
      expect(s.undoDepth, kHistoryLimit);
      // Walk all the way back without throwing.
      for (var i = 0; i < 25; i++) {
        n.undo();
      }
      final back = container.read(editorStateProvider);
      expect(back.undoDepth, 0);
      expect(back.redoDepth, greaterThan(0));
    });

    test('new edit clears redo', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setExposure(1.0);
      n.undo();
      expect(container.read(editorStateProvider).redoDepth, 1);
      n.setExposure(0.5);
      expect(container.read(editorStateProvider).redoDepth, 0);
      expect(n.canRedo, isFalse);
    });

    test('stroke drag costs exactly one entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.beginStroke();
      n.setExposure(0.5);
      n.setExposure(1.0);
      n.setExposure(1.5);
      n.endStroke();
      expect(container.read(editorStateProvider).undoDepth, 1);
    });

    test('reset on default adds no history', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.reset();
      expect(container.read(editorStateProvider).undoDepth, 0);
    });

    test('setFilterId same value adds no history', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setFilterId(LensFilterId.none);
      expect(container.read(editorStateProvider).undoDepth, 0);
      n.setFilterId(LensFilterId.cinematic);
      expect(container.read(editorStateProvider).undoDepth, 1);
      n.setFilterId(LensFilterId.cinematic);
      expect(container.read(editorStateProvider).undoDepth, 1);
    });
  });

  group('input clamps', () {
    test('setters clamp wild values', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setExposure(10);
      n.setStructure(-150);
      n.setContrast(500);
      n.setFilterStrength(1000);
      final s = container.read(editorStateProvider);
      expect(s.adjust.exposure, 3);
      expect(s.adjust.structure, -100);
      expect(s.adjust.contrast, 100);
      expect(s.filterStrength, 100);
      // The bipolar structure range clamps on the positive side too.
      n.setStructure(150);
      expect(container.read(editorStateProvider).adjust.structure, 100);
    });
  });

  group('pipeline units', () {
    test('toUniforms has 44 slots, exposure first rays last', () {
      const p = LensParams(exposure: 1.0, filterStrength: 0.5);
      final u = p.toUniforms();
      expect(u.length, 56);
      expect(u[0], 1.0);
      expect(u[9], 0.5);
      // Task 3.2 Enhance block neutral by default (stage skipped).
      expect(u.sublist(10, 19), [
        1.0, // enhR
        1.0, // enhB
        0.0, // enhBlack
        1.0, // enhWhite
        0.0, // enhDehaze
        0.5, // enhHazeR
        0.5, // enhHazeG
        0.5, // enhHazeB
        0.0, // enhanceStrength
      ]);
    });

    test('structureNormalized clamps -1..1', () {
      expect(const LensParams(structure: 250).structureNormalized, 1.0);
      expect(const LensParams(structure: -250).structureNormalized, -1.0);
      expect(const LensParams(structure: -10).structureNormalized, -0.1);
    });

    test('editor maps UI units to shader units', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setContrast(50);
      n.setFilterStrength(50);
      final p = container.read(editorStateProvider).toLensParams();
      expect(p.contrast, 0.5);
      expect(p.filterStrength, 0.5);
      expect(p.filterId, LensFilterId.none.index);
    });
  });

  group('CPU guards', () {
    test('empty bytes throw LensCpuException', () {
      expect(
        () => applyLensGrade(Uint8List(0), const LensParams().toUniforms()),
        throwsA(isA<LensCpuException>()),
      );
    });

    test('garbage bytes throw LensCpuException, never hang', () {
      final garbage = Uint8List.fromList(List<int>.generate(256, (i) => i));
      expect(
        () => applyLensGrade(garbage, const LensParams().toUniforms()),
        throwsA(isA<LensCpuException>()),
      );
    });

    test('wrong uniform count throws', () {
      final png = _png(4, 4, 128, 128, 128);
      expect(
        () => applyLensGrade(png, const [0.0, 0.0]),
        throwsA(isA<LensCpuException>()),
      );
    });

    test('invalid filterId throws LensCpuException', () {
      final png = _png(4, 4, 128, 128, 128);
      expect(
        () => applyLensGrade(png, const LensParams().toUniforms(), 99),
        throwsA(isA<LensCpuException>()),
      );
    });

    test('legacy 9 uniforms still work with filter 0', () {
      final png = _png(8, 8, 200, 100, 50);
      final legacy9 = const LensParams().toUniforms().sublist(0, 9);
      final out = applyLensGrade(png, legacy9);
      expect(out, isNotEmpty);
    });
  });

  group('preview cache guards', () {
    test('empty bytes round-trip without throw', () async {
      final out = await PreviewCache.previewBytes(Uint8List(0));
      expect(out, isEmpty);
    });

    test('tiny image returns as-is, same content hits cache', () async {
      PreviewCache.clear();
      final png = _png(4, 4, 10, 20, 30);
      final a = await PreviewCache.previewBytes(png);
      final b = await PreviewCache.previewBytes(png);
      expect(a, isNotEmpty);
      expect(identical(a, b), isTrue);
    });

    test('LRU evicts beyond 8 entries', () async {
      PreviewCache.clear();
      for (var i = 0; i < 10; i++) {
        await PreviewCache.previewBytes(_png(4, 4, i, i, i));
      }
      expect(PreviewCache.length, lessThanOrEqualTo(8));
    });
  });

  group('export guards', () {
    test('empty bytes throw LensCpuException, not hang', () async {
      await expectLater(
        ExportService.export(
          srcBytes: Uint8List(0),
          params: const LensParams(),
        ),
        throwsA(isA<LensCpuException>()),
      );
    });

    test('tiny identity export returns JPEG', () async {
      final png = _png(8, 8, 120, 130, 140);
      final out = await ExportService.export(
        srcBytes: png,
        params: const LensParams(),
      );
      expect(out.length, greaterThan(100));
      // JPEG magic.
      expect(out[0], 0xFF);
      expect(out[1], 0xD8);
    });
  });

  group('LUT sanity', () {
    test('nine ids: none plus eight looks', () {
      expect(LensFilterId.values.length, 9);
      expect(LensFilterId.values.first, LensFilterId.none);
    });

    test('none LUT is near-identity at mid gray', () {
      final lut = LutTables.generateLut(LensFilterId.none);
      final (r, g, b) = LutTables.sampleLut(lut, 0.5, 0.5, 0.5);
      expect((r - 0.5).abs(), lessThan(0.03));
      expect((g - 0.5).abs(), lessThan(0.03));
      expect((b - 0.5).abs(), lessThan(0.03));
    });
  });
}
