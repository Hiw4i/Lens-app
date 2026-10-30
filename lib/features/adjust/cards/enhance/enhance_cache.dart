import 'dart:isolate';
import 'dart:typed_data';

import 'package:image/image.dart' as img;

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';

/// Preview-size ceiling for the [prewarm] analysis downscale.
///
/// Matches the analysis contract (`analyzeEnhance` subsamples to a 256px
/// long side itself); decoding full-res just to throw pixels away would
/// waste both time and transient memory in the isolate.
const int kEnhancePrewarmMaxDim = 256;

/// Decode + downscale + analyze entry for the prewarm isolate.
///
/// Top-level so it can be referenced from [Isolate.run]. Never throws:
/// undecodable input yields [EnhanceAnalysis.none] (the caller's read path
/// treats a missing entry as `none` anyway, so "error" and "neutral photo"
/// are indistinguishable downstream by design).
EnhanceAnalysis _analyzePreviewBytes(Uint8List bytes) {
  try {
    if (bytes.isEmpty) return EnhanceAnalysis.none;
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return EnhanceAnalysis.none;
    final int w = decoded.width;
    final int h = decoded.height;
    if (w <= 0 || h <= 0) return EnhanceAnalysis.none;
    final int longSide = w > h ? w : h;
    final img.Image small;
    if (longSide <= kEnhancePrewarmMaxDim) {
      small = decoded;
    } else {
      // Integer aspect-preserving fit: long side lands exactly on 256.
      final int sw = (w * kEnhancePrewarmMaxDim / longSide).round().clamp(1, w);
      final int sh = (h * kEnhancePrewarmMaxDim / longSide).round().clamp(1, h);
      small = img.copyResize(decoded, width: sw, height: sh);
    }
    return analyzeEnhance(small);
  } catch (_) {
    return EnhanceAnalysis.none;
  }
}

/// Fire-and-forget cache of per-photo [EnhanceAnalysis] (Task 3.2).
///
/// Keyed by the imported photo bytes object ([Expando] identity): the same
/// `Uint8List` instance flows from the library grid into the editor
/// preview, so an entry warmed at open time is a hit when the editor (3.3)
/// reads it. Pure-Dart on purpose — no Flutter, no Riverpod — so the
/// analysis can run in an isolate.
///
/// Contract: [prewarm] never throws and never blocks the caller; [get]
/// returns `null` on every miss or failure, and [getOrNone] maps that to
/// [EnhanceAnalysis.none]. Analysis values become [LensParams] enhance
/// uniforms via `EditorStateToLensParams` (3.3); the [prewarm] `onReady`
/// hook notifies state when the async result lands (see below).
abstract final class EnhanceCache {
  static final Expando<EnhanceAnalysis> _entries = Expando<EnhanceAnalysis>(
    'enhance',
  );

  /// In-flight guard: one analysis isolate per bytes object at a time.
  /// A second [prewarm] for the same photo while the first is running is
  /// a no-op instead of a duplicate decode.
  static final Expando<bool> _warming = Expando<bool>('enhance-warming');

  /// Pending completion hooks per bytes object. Multiple openers of the
  /// same photo each register their own `onReady` while the single
  /// in-flight isolate runs; all fire once on success.
  static final Expando<List<void Function()>> _readyHooks =
      Expando<List<void Function()>>('enhance-ready');

  /// Returns the cached analysis for [bytes], or `null` on miss/failure.
  /// Callers map `null` to [EnhanceAnalysis.none].
  static EnhanceAnalysis? get(Uint8List bytes) => _entries[bytes];

  /// Returns the cached analysis for [bytes], or [EnhanceAnalysis.none].
  static EnhanceAnalysis getOrNone(Uint8List bytes) =>
      _entries[bytes] ?? EnhanceAnalysis.none;

  /// Starts the analysis for [bytes] in a background isolate and returns
  /// immediately. Fire-and-forget: failures (undecodable bytes, isolate
  /// errors) leave no entry behind — the read path degrades to `none`.
  /// Never throws, never awaits, never re-warms a known photo.
  ///
  /// [onReady] fires exactly once, on the UI thread, after the analysis
  /// for THIS [bytes] object lands in the cache. The editor passes a
  /// `bumpEnhanceVersion` closure so `toLensParams` (a sync cache read)
  /// re-evaluates once the async result is hot; before that the read
  /// degrades to neutral. Semantics:
  /// * cache already hot → no isolate, no callback (reader already sees
  ///   the analysis; a bump would be a wasted rebuild, deduped by the
  ///   `LensParams==` select anyway);
  /// * isolate already in flight → the hook joins the pending list, no
  ///   duplicate decode;
  /// * isolate failure → no entry, hooks are dropped without firing
  ///   (readers stay neutral by design);
  /// * hook bodies are guarded: a throwing callback never breaks caching
  ///   or the other hooks.
  static void prewarm(Uint8List bytes, {void Function()? onReady}) {
    if (bytes.isEmpty) return;
    if (_entries[bytes] != null) return;
    if (_warming[bytes] == true) {
      if (onReady != null) {
        final List<void Function()> pending =
            _readyHooks[bytes] ?? <void Function()>[];
        pending.add(onReady);
        _readyHooks[bytes] = pending;
      }
      return;
    }
    _warming[bytes] = true;
    if (onReady != null) {
      _readyHooks[bytes] = <void Function()>[onReady];
    }
    Isolate.run(() => _analyzePreviewBytes(bytes))
        .then<void>(
          (EnhanceAnalysis analysis) {
            _entries[bytes] = analysis;
            _warming[bytes] = null;
            _fireHooks(bytes);
          },
          onError: (Object error, StackTrace stackTrace) {
            // Error entries are simply absent: get/getOrNone degrade to
            // none, and readers stay neutral by design — so hooks are
            // dropped without firing (no bump is needed for a neutral
            // read). The flag is cleared so a later open can retry.
            AppLogger.w(
              'Enhance analysis failed; grade stays neutral',
              context: 'enhance_cache',
              error: error,
              stackTrace: stackTrace,
            );
            _warming[bytes] = null;
            _readyHooks[bytes] = null;
          },
        )
        .ignore();
  }

  /// Fires and clears the pending hooks for [bytes]. Hook bodies are
  /// guarded: a throwing callback (disposed provider / dead listener)
  /// never breaks caching or the other hooks.
  static void _fireHooks(Uint8List bytes) {
    final List<void Function()>? hooks = _readyHooks[bytes];
    _readyHooks[bytes] = null;
    if (hooks == null) return;
    for (final void Function() hook in hooks) {
      try {
        hook();
      } catch (error, stackTrace) {
        AppLogger.d(
          'EnhanceCache onReady hook threw',
          context: 'enhance_cache',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }
}
