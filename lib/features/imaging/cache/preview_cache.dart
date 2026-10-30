import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

import 'package:lens/shared/diagnostics/app_logger.dart';

/// Downscaled preview bytes for the GPU preview path.
///
/// Never throws: any decode failure returns the original [full] bytes, so
/// the preview always has something to draw (the failure itself is logged —
/// a repeated full-res fallback means the device cannot decode the source
/// at all and the memory budget is broken upstream, not here).
///
/// Cache design:
/// - key: ([maxDim], content hash) — the same photo at different sizes
///   (main 1080p preview vs 192px filter thumbs) MUST NOT collide;
///   the content part is byte length + FNV-1a over the first/last 4 KB,
///   not [identityHashCode] — identity keys collide after GC and miss when
///   the same file is re-imported as a new object;
/// - value: JPEG q88 encoded from the downscaled frame — 3-5x smaller than
///   the previous PNG re-encode, so the cache holds real pixels cheaply;
/// - eviction: LRU over a [maxEntries]-bounded insertion-ordered map
///   (default 8 previews ≈ a few MB), so memory stays flat.
///
/// Dimensions come from `ImageDescriptor.encoded` (a header probe, no
/// pixel decode — the same engine API `StructureCache` already relies on),
/// so an out-of-bounds photo costs one native downscale decode instead of
/// a full-resolution probe decode plus the real one.
class PreviewCache {
  const PreviewCache._();

  /// Bound on memoized previews; the least-recently-used entry is evicted
  /// on overflow ([LinkedHashMap] insertion order = recency after refresh).
  static const int maxEntries = 8;

  /// Bytes sampled from the head and tail for [_stableKey].
  static const int _sampleSize = 4096;

  /// JPEG quality for downscaled previews: visually lossless on a phone
  /// screen, far smaller than PNG.
  static const int _jpegQuality = 88;

  static final Map<int, Uint8List> _cache = <int, Uint8List>{};

  /// Square previews (the filter thumbs) live in their own map: they are a
  /// DIFFERENT raster (centre-cropped) than the plain downscale, so they
  /// must not collide with it.
  static final Map<int, Uint8List> _squareCache = <int, Uint8List>{};

  /// For tests: current entry count.
  static int get length => _cache.length;

  /// For tests: current square-preview entry count.
  static int get squareLength => _squareCache.length;

  /// Returns a SQUARE preview of [full]: the photo centre-cropped to a
  /// square and scaled down so its long side fits [maxDim].
  ///
  /// The filter thumbs live in a square tile, so the crop belongs in the
  /// pixels: a square source fills the tile exactly, and no layout path can
  /// leave surface-coloured bars in it. It is also the same picture the
  /// `BoxFit.cover` layout produced (both are centre crops), so the thumbs
  /// look identical either way — this just makes it structural.
  ///
  /// Never throws: any failure falls back to the plain downscale.
  static Future<Uint8List> squarePreviewBytes(
    Uint8List full, {
    int maxDim = 192,
  }) async {
    if (full.isEmpty) return full;
    final key = Object.hash(maxDim, _stableKey(full), 0x5D);
    final hit = _squareCache.remove(key);
    if (hit != null) {
      _squareCache[key] = hit;
      return hit;
    }
    // A failed path returns the ORIGINAL bytes without caching them: the
    // LRU must hold previews (bounded, small), not a multi-MB fallback
    // that pins full-resolution rasters under a thumbnail key. The next
    // call retries the downscale instead.
    final Uint8List? scaled = await _previewBytesCached(full, maxDim);
    if (scaled == null) return full;
    final Uint8List result;
    try {
      result = await _centreCropSquare(scaled);
    } catch (error, stackTrace) {
      AppLogger.w(
        'Square preview failed; serving the plain preview',
        context: 'preview_cache',
        error: error,
        stackTrace: stackTrace,
      );
      return full;
    }
    if (_squareCache.length >= maxEntries) {
      _squareCache.remove(_squareCache.keys.first);
    }
    _squareCache[key] = result;
    return result;
  }

  /// Centre-crops [bytes] to a square and re-encodes them.
  ///
  /// Runs on the already-downscaled preview, so the decode is tiny (a
  /// couple of hundred pixels) and the crop costs nothing measurable.
  static Future<Uint8List> _centreCropSquare(Uint8List bytes) async {
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null) return bytes;
    final int w = decoded.width;
    final int h = decoded.height;
    if (w <= 0 || h <= 0) return bytes;
    if (w == h) return bytes;
    final int side = math.min(w, h);
    final int left = (w - side) ~/ 2;
    final int top = (h - side) ~/ 2;
    final img.Image square = img.copyCrop(
      decoded,
      x: left,
      y: top,
      width: side,
      height: side,
    );
    return img.encodeJpg(square, quality: _jpegQuality);
  }

  /// Returns a copy of [full] whose longest side fits [maxDim] (default
  /// 1080). Images already within bounds are returned as-is (no re-encode,
  /// no quality loss). Never throws: a failure returns the original bytes
  /// UNCACHED (see [_previewBytesCached]).
  static Future<Uint8List> previewBytes(
    Uint8List full, {
    int maxDim = 1080,
  }) async =>
      (await _previewBytesCached(full, maxDim)) ?? full;

  /// The caching core of [previewBytes]: null means the downscale failed
  /// and nothing was memoized (the caller serves [full] directly); a
  /// non-null result (including the in-bounds original) is cached and
  /// returned. Splitting the two outcomes keeps multi-megabyte failure
  /// fallbacks out of the LRU.
  static Future<Uint8List?> _previewBytesCached(
    Uint8List full,
    int maxDim,
  ) async {
    if (full.isEmpty) return full;
    final key = Object.hash(maxDim, _stableKey(full));
    final hit = _cache.remove(key);
    if (hit != null) {
      // Refresh recency: re-insert so eviction drops the true LRU entry.
      _cache[key] = hit;
      return hit;
    }
    final Uint8List? result = await _downscale(full, maxDim);
    if (result == null) return null;
    if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = result;
    return result;
  }

  /// Drops all memoized previews (e.g. on memory pressure).
  static void clear() {
    _cache.clear();
    _squareCache.clear();
  }

  /// Content hash: length mixed with FNV-1a over the first and last
  /// [_sampleSize] bytes. O(8 KB) regardless of image size — no full-body
  /// scan — yet distinct files (or same pixels re-encoded) hash distinctly,
  /// unlike [identityHashCode] which collides and misses across imports.
  static int _stableKey(Uint8List bytes) {
    var hash = 0x811c9dc5;
    final n = bytes.length;
    final head = math.min(n, _sampleSize);
    for (var i = 0; i < head; i++) {
      hash = ((hash ^ bytes[i]) * 16777619) & 0xFFFFFFFF;
    }
    final tailStart = math.max(0, n - _sampleSize);
    for (var i = tailStart; i < n; i++) {
      hash = ((hash ^ bytes[i]) * 16777619) & 0xFFFFFFFF;
    }
    hash = ((hash ^ (n & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF;
    return hash;
  }

  /// The downscale worker. Returns null on failure (caller serves the
  /// original uncached); returns [full] unchanged when the image already
  /// fits [maxDim] (a legitimate, cacheable result). Never throws.
  static Future<Uint8List?> _downscale(Uint8List full, int maxDim) async {
    final ui.ImmutableBuffer buffer;
    try {
      buffer = await ui.ImmutableBuffer.fromUint8List(full);
    } catch (error, stackTrace) {
      AppLogger.w(
        'Preview decode rejected; serving the original bytes',
        context: 'preview_cache',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      // Header probe only: width/height without decoding any pixels.
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int w = descriptor.width;
      final int h = descriptor.height;
      if (w <= 0 || h <= 0) return null;
      // Already within bounds: the original IS the preview (no re-encode,
      // no quality loss) — a legitimate cacheable result, unlike a failure.
      if (math.max(w, h) <= maxDim) return full;

      final int targetW;
      final int targetH;
      if (w >= h) {
        targetW = maxDim;
        targetH = (h * maxDim / w).round().clamp(1, maxDim);
      } else {
        targetH = maxDim;
        targetW = (w * maxDim / h).round().clamp(1, maxDim);
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: targetW,
        targetHeight: targetH,
      );
      final frame = await codec.getNextFrame();
      image = frame.image;
      final byteData = await image.toByteData(
        format: ui.ImageByteFormat.rawRgba,
      );
      final outW = image.width;
      final outH = image.height;
      if (byteData == null) return null;
      final rgba = byteData.buffer.asUint8List(
        byteData.offsetInBytes,
        byteData.lengthInBytes,
      );
      if (rgba.length != outW * outH * 4) return null;
      // image 4.x takes the raw ByteBuffer; copy only when the ByteData
      // view is offset into a larger buffer (rare, but must stay exact).
      final ByteBuffer pixelBuffer =
          (byteData.offsetInBytes == 0 &&
              byteData.lengthInBytes == byteData.buffer.lengthInBytes)
          ? byteData.buffer
          : Uint8List.fromList(rgba).buffer;
      final pixels = img.Image.fromBytes(
        width: outW,
        height: outH,
        bytes: pixelBuffer,
        numChannels: 4,
        order: img.ChannelOrder.rgba,
      );
      return img.encodeJpg(pixels, quality: _jpegQuality);
    } catch (error, stackTrace) {
      AppLogger.w(
        'Preview downscale failed; serving the original bytes',
        context: 'preview_cache',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    } finally {
      image?.dispose();
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
  }
}
