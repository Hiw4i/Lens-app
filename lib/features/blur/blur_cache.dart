import 'dart:typed_data';

import 'package:lens/features/blur/subject_mask.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';

/// Fire-and-forget cache of per-photo ML subject masks (Task 6.1).
///
/// Same shape as [EnhanceCache] (identity-keyed [Expando] entries, a
/// warming guard, `onReady` hooks) minus the isolate: ML Kit talks over a
/// method channel, which only exists on the platform thread, so the
/// segmentation runs as a plain async call instead of `Isolate.run`.
///
/// One deliberate deviation from `EnhanceCache`: hooks fire when the
/// attempt *settles*, even when the mask came back `null`. `EnhanceCache`
/// drops hooks on failure because neutral defaults exist; here there is no
/// neutral subject — the caller needs the signal to fall back to the
/// manual brush (`get` still reads `null`).
///
/// Contract: [prewarm] never throws and never blocks the caller; [get]
/// returns `null` on every miss or failure. Feather is NOT applied here —
/// the stored mask is the hard ML output (plus bilinear smoothing); edge
/// softness is a 6.2 apply-side `smoothstep` uniform.
abstract final class BlurCache {
  static final Expando<Float32List> _entries = Expando<Float32List>(
    'subject-mask',
  );

  /// In-flight guard: one segmentation per bytes object at a time. A second
  /// [prewarm] for the same photo while the first is running joins the
  /// pending hook list instead of duplicating the native call.
  static final Expando<bool> _warming = Expando<bool>('subject-mask-warming');

  /// Pending completion hooks per bytes object. All fire exactly once when
  /// the attempt for THIS bytes object settles (mask or null).
  static final Expando<List<void Function()>> _readyHooks =
      Expando<List<void Function()>>('subject-mask-ready');

  /// Returns the cached `size × size` foreground mask for [bytes], or
  /// `null` on miss/failure. Callers map `null` to the manual brush.
  static Float32List? get(Uint8List bytes) => _entries[bytes];

  /// Starts the segmentation for [bytes] and returns immediately.
  /// Fire-and-forget: failures and `null` masks simply leave no entry
  /// behind — the read path degrades to manual. Never throws, never awaits,
  /// never re-warms a known photo. Every call routes through
  /// [SafeSubjectMask], so even a throwing [provider] cannot break the
  /// cache.
  ///
  /// [onReady] fires exactly once, on the UI thread, when the attempt for
  /// THIS [bytes] object settles — mask or `null`. The caller re-reads
  /// [get]: non-null → sharp-subject path, null → manual brush. Semantics:
  /// * cache already hot → no work, no callback (the reader already sees
  ///   the mask);
  /// * segmentation already in flight → the hook joins the pending list,
  ///   no duplicate native call;
  /// * hook bodies are guarded: a throwing callback never breaks caching
  ///   or the other hooks.
  static void prewarm(
    Uint8List bytes,
    SubjectMaskProvider provider, {
    void Function()? onReady,
  }) {
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
    // Future() (not a direct call) so even a synchronously-throwing
    // provider lands in onError instead of escaping prewarm.
    Future<Float32List?>(
          () =>
              SafeSubjectMask(provider)
                  .foregroundMask(bytes, size: kSubjectMaskSize),
        )
        .then<void>(
          (Float32List? mask) {
            _warming[bytes] = null;
            if (mask != null) _entries[bytes] = mask;
            _fireHooks(bytes);
          },
          onError: (Object error, StackTrace stackTrace) {
            // Error entries are simply absent: get degrades to manual. The
            // flag is cleared so a later open can retry. Per the contract
            // above, hooks still fire: the auto path settling with failure
            // is exactly the signal the caller needs to offer the manual
            // brush instead of waiting forever.
            AppLogger.w(
              'Subject-mask segmentation failed; degrading to manual brush',
              context: 'blur_cache',
              error: error,
              stackTrace: stackTrace,
            );
            _warming[bytes] = null;
            _fireHooks(bytes);
          },
        )
        .ignore();
  }

  /// Fires and clears the pending hooks for [bytes]. Hook bodies are
  /// guarded: a throwing callback (disposed listener) never breaks caching
  /// or the other hooks. Per-frame safe: hooks fire once per settle.
  static void _fireHooks(Uint8List bytes) {
    final List<void Function()>? hooks = _readyHooks[bytes];
    _readyHooks[bytes] = null;
    if (hooks == null) return;
    for (final void Function() hook in hooks) {
      try {
        hook();
      } catch (error, stackTrace) {
        AppLogger.d(
          'BlurCache onReady hook threw',
          context: 'blur_cache',
          error: error,
          stackTrace: stackTrace,
        );
      }
    }
  }
}
