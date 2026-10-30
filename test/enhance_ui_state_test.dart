import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:lens/features/editor/logic/editor_state.dart';

void main() {
  group('enhance state (Task 3.3)', () {
    test('one-tap sets 70 as exactly one history entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      expect(container.read(editorStateProvider).enhanceStrength, 0);
      n.applyEnhanceOneTap();
      final s = container.read(editorStateProvider);
      expect(s.enhanceStrength, kEnhanceOneTapStrength);
      expect(s.enhanceStrength, 70);
      expect(s.undoDepth, 1);
      expect(s.isDefault, isFalse);
    });

    test('repeat one-tap does not duplicate history', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.applyEnhanceOneTap();
      expect(container.read(editorStateProvider).undoDepth, 1);
      n.applyEnhanceOneTap();
      n.applyEnhanceOneTap();
      final s = container.read(editorStateProvider);
      expect(s.enhanceStrength, 70);
      expect(s.undoDepth, 1);
    });

    test('strength slider drag brackets into one entry', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.beginStroke();
      n.setEnhanceStrength(10);
      n.setEnhanceStrength(40);
      n.setEnhanceStrength(55);
      n.endStroke();
      final s = container.read(editorStateProvider);
      expect(s.enhanceStrength, 55);
      expect(s.undoDepth, 1);
    });

    test('undo restores 0, redo restores the tap', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.applyEnhanceOneTap();
      n.undo();
      expect(container.read(editorStateProvider).enhanceStrength, 0);
      expect(container.read(editorStateProvider).isDefault, isTrue);
      n.redo();
      expect(container.read(editorStateProvider).enhanceStrength, 70);
    });

    test('clearEnhance is one step and no-op when off', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.clearEnhance();
      expect(container.read(editorStateProvider).undoDepth, 0);
      n.applyEnhanceOneTap();
      n.clearEnhance();
      final s = container.read(editorStateProvider);
      expect(s.enhanceStrength, 0);
      expect(s.undoDepth, 2);
      expect(s.isDefault, isTrue);
      n.clearEnhance();
      expect(container.read(editorStateProvider).undoDepth, 2);
    });

    test('setEnhanceStrength clamps 0..100, reset clears enhance', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.setEnhanceStrength(500);
      expect(container.read(editorStateProvider).enhanceStrength, 100);
      n.setEnhanceStrength(-10);
      expect(container.read(editorStateProvider).enhanceStrength, 0);
      n.applyEnhanceOneTap();
      n.reset();
      final s = container.read(editorStateProvider);
      expect(s.enhanceStrength, 0);
      expect(s.isDefault, isTrue);
    });

    test('bumpEnhanceVersion is not undoable', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      final before = container.read(editorStateProvider).enhanceAnalysisVersion;
      n.bumpEnhanceVersion();
      final s = container.read(editorStateProvider);
      expect(s.enhanceAnalysisVersion, before + 1);
      expect(s.undoDepth, 0);
      expect(s.isDefault, isTrue);
    });

    test('toLensParams without analysis is enhance-neutral', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      // Unknown bytes: cache miss -> EnhanceAnalysis.none.
      final unknown = Uint8List.fromList(<int>[9, 8, 7, 6, 5, 4, 3, 2]);
      final n = container.read(editorStateProvider.notifier);
      n.setPreviewBytes(unknown);
      final p = container.read(editorStateProvider).toLensParams();
      expect(p.enhanceStrength, 0.0);
      expect(p.enhR, 1.0);
      expect(p.enhB, 1.0);
      expect(p.enhBlack, 0.0);
      expect(p.enhWhite, 1.0);
      expect(p.enhDehaze, 0.0);
      expect(p.enhHazeR, 0.5);
      expect(p.enhHazeG, 0.5);
      expect(p.enhHazeB, 0.5);
      final u = p.toUniforms();
      expect(u.length, 56);
      expect(u.sublist(10, 19), [1.0, 1.0, 0.0, 1.0, 0.0, 0.5, 0.5, 0.5, 0.0]);
    });

    test('toLensParams maps enhanceStrength/100 into slot 20', () {
      final container = ProviderContainer.test();
      addTearDown(container.dispose);
      final n = container.read(editorStateProvider.notifier);
      n.applyEnhanceOneTap();
      final p = container.read(editorStateProvider).toLensParams();
      expect(p.enhanceStrength, closeTo(0.7, 1e-12));
      expect(p.toUniforms()[18], closeTo(0.7, 1e-12));
    });
  });
}
