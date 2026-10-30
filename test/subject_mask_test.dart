import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/blur/blur_cache.dart';
import 'package:lens/features/blur/subject_mask.dart';

/// Configurable fake: returns [mask], or throws synchronously when
/// [throws] (non-async throw — the nastiest provider behavior).
class FakeSubjectMask implements SubjectMaskProvider {
  FakeSubjectMask({this.mask, this.throws = false});

  final Float32List? mask;
  final bool throws;

  @override
  Future<Float32List?> foregroundMask(
    Uint8List bytes, {
    int size = kSubjectMaskSize,
  }) {
    if (throws) throw StateError('fake failure');
    return Future<Float32List?>.value(mask);
  }
}

/// Distinct bytes object per test: [BlurCache] keys on identity, so fresh
/// objects keep the static cache isolated between tests.
Uint8List _pngBytes() {
  final img.Image image = img.Image(width: 8, height: 8, numChannels: 3);
  for (int y = 0; y < 8; y++) {
    for (int x = 0; x < 8; x++) {
      image.setPixelRgb(x, y, 200, 100, 50);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

void main() {
  group('SafeSubjectMask', () {
    test('maps a throwing provider to null instead of throwing', () async {
      final SubjectMaskProvider safe = SafeSubjectMask(
        FakeSubjectMask(throws: true),
      );
      await expectLater(safe.foregroundMask(_pngBytes()), completion(isNull));
    });

    test('passes a valid mask through untouched', () async {
      final Float32List mask = Float32List.fromList(<double>[
        0.0,
        0.5,
        0.75,
        1.0,
      ]);
      final SubjectMaskProvider safe = SafeSubjectMask(
        FakeSubjectMask(mask: mask),
      );
      final Float32List? got = await safe.foregroundMask(_pngBytes(), size: 2);
      expect(got, isNotNull);
      expect(got, mask);
      expect(got, <double>[0.0, 0.5, 0.75, 1.0]);
    });
  });

  group('ManualSubjectMask', () {
    test('always returns null (manual-brush signal)', () async {
      const SubjectMaskProvider manual = ManualSubjectMask();
      expect(await manual.foregroundMask(_pngBytes()), isNull);
      expect(
        await manual.foregroundMask(Uint8List.fromList(<int>[0, 1, 2, 3])),
        isNull,
      );
    });
  });

  group('MlKitSubjectMask (no native plugin on test host)', () {
    test('valid JPEG bytes degrade to null without throwing', () async {
      const SubjectMaskProvider mlKit = MlKitSubjectMask();
      await expectLater(mlKit.foregroundMask(_pngBytes()), completion(isNull));
    });

    test('garbage bytes degrade to null without throwing', () async {
      const SubjectMaskProvider mlKit = MlKitSubjectMask();
      await expectLater(
        mlKit.foregroundMask(Uint8List.fromList(<int>[0, 1, 2, 3])),
        completion(isNull),
      );
      await expectLater(mlKit.foregroundMask(Uint8List(0)), completion(isNull));
    });

    test('invalid size degrades to null without throwing', () async {
      const SubjectMaskProvider mlKit = MlKitSubjectMask();
      expect(await mlKit.foregroundMask(_pngBytes(), size: 0), isNull);
      expect(await mlKit.foregroundMask(_pngBytes(), size: -4), isNull);
    });
  });

  group('BlurCache', () {
    test('miss returns null', () {
      expect(BlurCache.get(_pngBytes()), isNull);
    });

    test('prewarm stores the mask and fires onReady once', () async {
      final Uint8List bytes = _pngBytes();
      final Float32List mask = Float32List(256 * 256)
        ..fillRange(0, 256 * 256, 1.0);
      int calls = 0;
      final Completer<void> done = Completer<void>();
      BlurCache.prewarm(
        bytes,
        FakeSubjectMask(mask: mask),
        onReady: () {
          calls++;
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(const Duration(seconds: 5));
      // Let any stray duplicate callbacks land before asserting "once".
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      expect(BlurCache.get(bytes), mask);
    });

    test('hot cache skips work and skips the callback', () async {
      final Uint8List bytes = _pngBytes();
      final Float32List mask = Float32List(4)..[0] = 1.0;
      final Completer<void> done = Completer<void>();
      BlurCache.prewarm(
        bytes,
        FakeSubjectMask(mask: mask),
        onReady: () {
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(const Duration(seconds: 5));
      int calls = 0;
      BlurCache.prewarm(
        bytes,
        FakeSubjectMask(mask: mask),
        onReady: () => calls++,
      );
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 0);
      expect(BlurCache.get(bytes), mask);
    });

    test('null mask settles with no entry but still fires onReady', () async {
      // Deviation from EnhanceCache (documented in blur_cache.dart): there
      // is no neutral subject, so the caller needs the settle signal to
      // fall back to the manual brush.
      final Uint8List bytes = _pngBytes();
      int calls = 0;
      final Completer<void> done = Completer<void>();
      BlurCache.prewarm(
        bytes,
        FakeSubjectMask(),
        onReady: () {
          calls++;
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      expect(BlurCache.get(bytes), isNull);
    });

    test('throwing provider cannot break the cache', () async {
      final Uint8List bytes = _pngBytes();
      int calls = 0;
      final Completer<void> done = Completer<void>();
      BlurCache.prewarm(
        bytes,
        FakeSubjectMask(throws: true),
        onReady: () {
          calls++;
          if (!done.isCompleted) done.complete();
        },
      );
      await done.future.timeout(const Duration(seconds: 5));
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, 1);
      expect(BlurCache.get(bytes), isNull);
    });
  });
}
