import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:lens/features/selective/mask_raster.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';

/// Raster → GPU texture bridge for the brush selective mask (Task 4.5).
///
/// The preview shader samples the brush mask from sampler slot 2 (`uSelMask`)
/// unconditionally, so the slot must ALWAYS be bound: analytic modes
/// (radial/linear) keep binding the cached 1x1 white stub owned by
/// [ShaderPreview], brush mode binds the raster built here.
///
/// Pipeline: [rasterizeBrushMask] at [size] (default 128 — bilinear
/// upsampling in the shader smooths the rest, same contract as the CPU
/// export path) → normalized 8-bit gray written straight into an RGBA8
/// buffer → `decodeImageFromPixels` GPU texture. No PNG round-trip: a
/// brush dab used to pay an encodePng + full decode per tick for a 128²
/// opaque texture. No [featherBox] pass either: the per-dab [brushFalloff]
/// kernel plus GPU bilinear filtering already matches the export path
/// (128 preview raster + linear filtering vs 256 in-isolate raster +
/// bilinear sampling), an extra box blur would diverge the two.
///
/// Cache: a 4-entry LRU per key space. An earlier design kept only the
/// latest entry, which rebuilt the mask every time two consumers alternated
/// (selective brush and the blur manual brush both call this class; a photo
/// switch and a tool-switch rebuild could also evict the entry that was
/// still being painted). Four slots keep both the previous and the current
/// raster hot while capping memory at a few hundred KB — brush dabs are
/// append-only, so the live key moves with every dab and the older entry is
/// exactly what the orthogonal tool needs when the user switches back.
///
/// Keys:
/// * [maskImage] — cheap structural hash (stroke count + per-stroke point
///   count/radius/feather + first/last point — NOT a full point scan), so
///   structurally unchanged strokes hit even when a caller rebuilds the
///   list: grade-only ticks return the identical future instance, the
///   preview `FutureBuilder` reuses its snapshot (no flicker) and the
///   shader takes the in-place uniform path. A brush dab extends one
///   stroke point-by-point, which moves the length/last-point hash every
///   tick — exactly the live feedback we want.
/// * [floatMaskImage] — identity of the `Float32List` instance + size. The
///   ML cache holds the same instance until the next prewarm, so repeated
///   ticks with a hot mask return the identical future.
///
/// Ownership (LutManager rule): built images are cache-owned, never
/// disposed by the preview. Evicted entries are not disposed on the spot —
/// the outgoing frame's `FutureBuilder` snapshot and the previous shader
/// sampler binding may still reference them — they retire for
/// [_retireLag] cache generations before disposal, so orphaned GPU
/// textures stay bounded during a long stroke instead of waiting for the
/// engine finalizer. [clear] retires everything the same way.
///
/// Empty input (no strokes, or strokes without points) returns null: the
/// caller then binds the white stub, which keeps a stray brush-mode tick a
/// full-strength no-op-grade instead of a blackout — and matches the
/// `toLensParams` off-fallback (empty brush → selMode 0).
abstract final class MaskManager {
  /// Entries kept per key space. Four covers the two live consumers (the
  /// selective brush and the manual blur brush), the previous revision of
  /// the active one, and one spare across a tool/photo switch.
  static const int maxEntries = 4;

  /// How many cache generations an evicted texture must outlive before its
  /// disposal fires. Two generations cover the frame that still paints the
  /// outgoing image plus the frame the replacement shader binds in.
  static const int _retireLag = 2;

  static final Map<int, Future<ui.Image>> _brushEntries = {};

  /// Value is `(source, future)`: the source identity is re-checked on a
  /// key hit because [identityHashCode] can collide after a `Float32List`
  /// is GC'd and its address reused.
  static final Map<int, (Float32List, Future<ui.Image>)> _floatEntries = {};

  /// `(future, generation)` pairs awaiting disposal. Bounded: entries leave
  /// the queue [_retireLag] generations after entering, and both caches cap
  /// the generation turnover at [maxEntries].
  static final List<(Future<ui.Image>, int)> _retired = [];

  static int _generation = 0;

  /// Rasterizes [strokes] into a GPU texture, or null when there is
  /// nothing to rasterize (see above). The returned future is stable per
  /// structural key — repeated calls with unchanged strokes return the
  /// identical instance.
  static Future<ui.Image>? maskImage(
    List<BrushStroke> strokes, {
    int size = 128,
  }) {
    var hasPaint = false;
    for (final BrushStroke s in strokes) {
      if (s.points.isNotEmpty) {
        hasPaint = true;
        break;
      }
    }
    if (!hasPaint) return null;
    final int key = _structuralKey(strokes, size);
    final Future<ui.Image>? cached = _brushEntries[key];
    if (cached != null) {
      _touch(_brushEntries, key, cached);
      return cached;
    }
    final Future<ui.Image> future = _build(strokes, size);
    _putBrush(key, future);
    return future;
  }

  /// Converts a ready 0..1 foreground mask ([BlurCache.get] output or the
  /// 6.4 manual 256 raster) into a GPU texture for sampler slot 3
  /// (`uBlurMask`). Values are normalized 0..1 (clamped) and written as
  /// gray into RGB (the shader reads `.r`); alpha stays opaque. The input
  /// is NOT mutated. `mask.length` must equal `size*size` (square, like
  /// `kSubjectMaskSize`); otherwise returns null so the caller binds the
  /// white stub (all-subject = neutral no-op) instead of crashing.
  static Future<ui.Image>? floatMaskImage(Float32List mask, int size) {
    if (size <= 0 || mask.length != size * size) return null;
    final int key = identityHashCode(mask) * 31 + size;
    final (Float32List, Future<ui.Image>)? cached = _floatEntries[key];
    if (cached != null && identical(cached.$1, mask)) {
      _touch(_floatEntries, key, cached);
      return cached.$2;
    }
    final Future<ui.Image> future = _buildFloat(mask, size);
    _putFloat(key, (mask, future));
    return future;
  }

  /// Retires the cached entries (photo change / tool teardown). Textures
  /// leave by the same lagged path as evictions, so a snapshot that is
  /// still painting this frame keeps a valid image.
  static void clear() {
    _generation++;
    for (final Future<ui.Image> future in _brushEntries.values) {
      _retired.add((future, _generation));
    }
    for (final (Float32List, Future<ui.Image>) entry in _floatEntries.values) {
      _retired.add((entry.$2, _generation));
    }
    _brushEntries.clear();
    _floatEntries.clear();
    _drainRetired();
  }

  /// Cheap structural hash: size + stroke count + per-stroke
  /// (point count, radius, feather, first/last point). A dab drag changes
  /// length + last point every tick, so live painting always misses;
  /// grade-only ticks always hit. A middle-point-only edit without a
  /// length/first/last change would NOT miss — acceptable: brush strokes
  /// are append-only in the UI (see `addBrushPoint`).
  static int _structuralKey(List<BrushStroke> strokes, int size) {
    var h = 17;
    h = h * 31 + size;
    h = h * 31 + strokes.length;
    for (final BrushStroke s in strokes) {
      h = h * 31 + s.points.length;
      h = h * 31 + s.radius.hashCode;
      h = h * 31 + s.feather.hashCode;
      if (s.points.isNotEmpty) {
        h = h * 31 + s.points.first.hashCode;
        h = h * 31 + s.points.last.hashCode;
      }
    }
    return h;
  }

  static void _putBrush(int key, Future<ui.Image> value) {
    _generation++;
    final Future<ui.Image>? previous = _brushEntries.remove(key);
    if (previous != null) _retired.add((previous, _generation));
    _brushEntries[key] = value;
    while (_brushEntries.length > maxEntries) {
      final int oldest = _brushEntries.keys.first;
      final Future<ui.Image>? removed = _brushEntries.remove(oldest);
      if (removed != null) _retired.add((removed, _generation));
    }
    _drainRetired();
  }

  static void _putFloat(int key, (Float32List, Future<ui.Image>) value) {
    _generation++;
    final (Float32List, Future<ui.Image>)? previous = _floatEntries.remove(key);
    if (previous != null) _retired.add((previous.$2, _generation));
    _floatEntries[key] = value;
    while (_floatEntries.length > maxEntries) {
      final int oldest = _floatEntries.keys.first;
      final (Float32List, Future<ui.Image>)? removed = _floatEntries.remove(
        oldest,
      );
      if (removed != null) _retired.add((removed.$2, _generation));
    }
    _drainRetired();
  }

  static void _touch<K, V>(Map<K, V> cache, K key, V value) {
    cache.remove(key);
    cache[key] = value;
  }

  /// Disposes the textures that have outlived [_retireLag] generations.
  /// Called from the cache mutations themselves (every dab is one), so no
  /// timer or frame callback is needed; when painting stops the queue just
  /// holds the last two generations — bounded, and they are the live ones.
  static void _drainRetired() {
    while (_retired.isNotEmpty && _generation - _retired.first.$2 > _retireLag) {
      final (Future<ui.Image> stale, _) = _retired.removeAt(0);
      unawaited(
        stale.then(
          (ui.Image image) => image.dispose(),
          onError: (Object error, StackTrace stackTrace) {
            // A failed build has no texture to dispose.
            AppLogger.d(
              'Retired mask future failed; nothing to dispose',
              context: 'mask_manager',
              error: error,
              stackTrace: stackTrace,
            );
          },
        ),
      );
    }
  }

  static Future<ui.Image> _build(List<BrushStroke> strokes, int size) async {
    final Float32List mask = rasterizeBrushMask(strokes, size);
    return _buildFloat(mask, size);
  }

  /// Packs the normalized mask as opaque gray RGBA8 and uploads it through
  /// the descriptor path: every engine handle is disposed in `finally`, and
  /// a failed upload settles the future with an error (the preview's
  /// FutureBuilder then renders the stub path) instead of pending forever.
  static Future<ui.Image> _buildFloat(Float32List mask, int size) async {
    final int texels = size * size;
    final Uint8List rgba = Uint8List(texels * 4);
    for (var i = 0; i < texels; i++) {
      final int v = (mask[i].clamp(0.0, 1.0) * 255.0).round().clamp(0, 255);
      final int o = i * 4;
      rgba[o] = v;
      rgba[o + 1] = v;
      rgba[o + 2] = v;
      rgba[o + 3] = 255;
    }
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      rgba,
    );
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: size,
        height: size,
        pixelFormat: ui.PixelFormat.rgba8888,
      );
      codec = await descriptor.instantiateCodec();
      final ui.FrameInfo frame = await codec.getNextFrame();
      return frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
