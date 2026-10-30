import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:lens/features/imaging/structure/structure_filter.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';

/// Builds the low-res guided-filter coefficient maps that the preview
/// uploads as sampler slot 4 (`uStructureMaps`).
///
/// The preview raster is decoded once per photo ([targetWidth] x
/// [targetHeight] come from that raster), the guided filter runs on it, and
/// the packed bytes are uploaded as a texture. Both the filter and the
/// packing live in `structure_filter.dart`, so the preview and the CPU
/// export run the SAME transfer function.
///
/// Cache design mirrors [PreviewCache]:
/// - key: (target size, content hash, square flag) — the same photo at
///   preview vs thumbnail size must not collide, and a square (thumbs) and
///   a plain (editor) raster are different pictures;
/// - value: [packStructureMaps] output, `ceil(w/s) * ceil(h/s) * 4` bytes
///   (a 12 MP preview grid is ~10 KB, the 1080 px preview ~36 KB), so eight
///   entries cost tens of KBs, not MBs;
/// - eviction: LRU over a [maxEntries]-bounded insertion-ordered map.
///
/// Everything here is best effort: any decode or isolate failure returns
/// null and the caller keeps the neutral stub bound (an exact no-op).
class StructureCache {
  const StructureCache._();

  /// Bound on memoized map sets; the least-recently-used entry is evicted
  /// on overflow ([Map] insertion order = recency after refresh).
  static const int maxEntries = 8;

  /// Bytes sampled from the head and tail for [_stableKey].
  static const int _sampleSize = 4096;

  /// The 1x1 NEUTRAL stub: a = 1, b = 0 -> q = luma -> dEV = 0 -> the
  /// stage is an exact no-op.
  static const List<int> _stubValues = <int>[0xFF, 0x00, 0x00, 0xFF];

  static final Map<int, Uint8List> _cache = <int, Uint8List>{};

  /// For tests: current entry count.
  static int get length => _cache.length;

  /// Packed RGBA8888 texture bytes (R = a, G:B = b) for the source scaled
  /// to [targetWidth] x [targetHeight]. Null when the source cannot be
  /// decoded.
  ///
  /// [square] centre-crops the decoded frame to a square BEFORE the guided
  /// filter — the same crop [PreviewCache.squarePreviewBytes] makes for the
  /// filter thumbs, so the maps describe the picture that is actually on
  /// screen.
  static Future<Uint8List?> mapsFor(
    Uint8List sourceBytes, {
    required int targetWidth,
    required int targetHeight,
    bool square = false,
  }) async {
    if (sourceBytes.isEmpty || targetWidth <= 0 || targetHeight <= 0) {
      return null;
    }
    final int key = Object.hash(
      targetWidth,
      targetHeight,
      _stableKey(sourceBytes),
      square,
    );
    final Uint8List? hit = _cache.remove(key);
    if (hit != null) {
      // Refresh recency: re-insert so eviction drops the true LRU entry.
      _cache[key] = hit;
      return hit;
    }
    Uint8List? packed;
    try {
      packed = await _compute(
        sourceBytes,
        targetWidth,
        targetHeight,
        square,
      );
    } catch (error, stackTrace) {
      // Best effort by contract: the caller keeps the neutral stub bound.
      AppLogger.w(
        'Structure maps computation failed',
        context: 'structure_cache',
        error: error,
        stackTrace: stackTrace,
      );
      packed = null;
    }
    if (packed == null) return null;
    if (_cache.length >= maxEntries) {
      _cache.remove(_cache.keys.first);
    }
    _cache[key] = packed;
    return packed;
  }

  /// The 1x1 NEUTRAL stub: a = 1, b = 0 -> q = luma -> dEV = 0 -> the
  /// stage is an exact no-op while the real maps are still computing.
  ///
  /// A fresh copy per call: the byte list belongs to the caller (it is
  /// handed to `decodeImageFromPixels`).
  static Uint8List neutralStubBytes() => Uint8List.fromList(_stubValues);

  /// Drops all memoized maps (e.g. on memory pressure).
  static void clear() => _cache.clear();

  /// Decodes [sourceBytes] to the request box, optionally centre-crops a
  /// square, and packs the guided-filter maps of the result.
  ///
  /// Nothing here upscales: a source smaller than the box decodes at its own
  /// size, so the maps stay aligned with the preview raster.
  static Future<Uint8List?> _compute(
    Uint8List sourceBytes,
    int targetWidth,
    int targetHeight,
    bool square,
  ) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      sourceBytes,
    );
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    ui.Image? image;
    try {
      descriptor = await ui.ImageDescriptor.encoded(buffer);
      final int intrinsicWidth = descriptor.width;
      final int intrinsicHeight = descriptor.height;
      if (intrinsicWidth <= 0 || intrinsicHeight <= 0) return null;
      int? requestWidth;
      int? requestHeight;
      if (!square) {
        // Exact box. The preview raster was decoded from the same source with
        // both target dimensions, and the codec stretches to the box (it does
        // NOT preserve the aspect when both are given) — so requesting the
        // same box reproduces the preview raster pixel for pixel.
        requestWidth = math.min(targetWidth, intrinsicWidth);
        requestHeight = math.min(targetHeight, intrinsicHeight);
      } else if (intrinsicWidth >= intrinsicHeight) {
        // Landscape: pin the SHORT side and let the wide side follow. Passing
        // both dimensions would stretch the photo into a square; the "centre
        // square" of the stretched frame is the WHOLE frame, not the centre
        // crop the preview shows. One pinned dimension keeps the aspect.
        requestHeight = math.min(targetHeight, intrinsicHeight);
      } else {
        requestWidth = math.min(targetWidth, intrinsicWidth);
      }
      codec = await descriptor.instantiateCodec(
        targetWidth: requestWidth,
        targetHeight: requestHeight,
      );
      final ui.FrameInfo frame = await codec.getNextFrame();
      image = frame.image;
    } finally {
      codec?.dispose();
      descriptor?.dispose();
      buffer.dispose();
    }
    int width = image.width;
    int height = image.height;
    late final ByteData? data;
    try {
      data = await image.toByteData(format: ui.ImageByteFormat.rawRgba);
    } finally {
      image.dispose();
    }
    if (data == null || width <= 0 || height <= 0) return null;
    Uint8List pixels = data.buffer.asUint8List(
      data.offsetInBytes,
      data.lengthInBytes,
    );
    if (pixels.length < width * height * 4) return null;

    if (square) {
      final int side = math.min(width, height);
      if (side <= 0) return null;
      final int left = (width - side) ~/ 2;
      final int top = (height - side) ~/ 2;
      pixels = _cropSquare(pixels, width, left, top, side);
      width = side;
      height = side;
    }

    // The guided filter is O(pixels); keep it off the UI isolate. The
    // closure captures only the pixels and the size, so the isolate
    // boundary carries plain data (`structure_filter.dart` is pure Dart).
    final int radius = structureGeometryFor(width, height).radius;
    final StructureMaps maps = await Isolate.run<StructureMaps>(
      () => computeStructureMapsFromRgba(
        pixels,
        width,
        height,
        radius: radius.toDouble(),
      ),
    );
    return packStructureMaps(maps);
  }

  /// Copies the centred [side] x [side] square of [rgba] starting at
  /// ([left], [top]).
  static Uint8List _cropSquare(
    Uint8List rgba,
    int sourceWidth,
    int left,
    int top,
    int side,
  ) {
    final int rowBytes = side * 4;
    final Uint8List out = Uint8List(rowBytes * side);
    for (int y = 0; y < side; y++) {
      final int srcStart = ((top + y) * sourceWidth + left) * 4;
      out.setRange(y * rowBytes, y * rowBytes + rowBytes, rgba, srcStart);
    }
    return out;
  }

  /// Content hash: length mixed with FNV-1a over the first and last
  /// [_sampleSize] bytes. O(8 KB) regardless of image size — no full-body
  /// scan — yet distinct files (or same pixels re-encoded) hash distinctly,
  /// unlike [identityHashCode] which collides and misses across imports.
  static int _stableKey(Uint8List bytes) {
    var hash = 0x811c9dc5;
    final int n = bytes.length;
    final int head = math.min(n, _sampleSize);
    for (var i = 0; i < head; i++) {
      hash = ((hash ^ bytes[i]) * 16777619) & 0xFFFFFFFF;
    }
    final int tailStart = math.max(0, n - _sampleSize);
    for (var i = tailStart; i < n; i++) {
      hash = ((hash ^ bytes[i]) * 16777619) & 0xFFFFFFFF;
    }
    hash = ((hash ^ (n & 0xFFFFFFFF)) * 16777619) & 0xFFFFFFFF;
    return hash;
  }
}
