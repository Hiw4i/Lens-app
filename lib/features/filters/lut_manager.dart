import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:lens/features/filters/lut_definition.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';

/// GPU side of the procedural LUT stage (Task 2.3).
///
/// Builds one sampler atlas per [LensFilterId] from [LutTables.gradePixel]
/// — no baked assets — and caches it for the lifetime of the process.
/// The preview binds the atlas to sampler slot 1 (`setImageSampler(1, …)`).
///
/// Atlas layout (single filter, 512x512 RGBA8, ~1MB GPU):
/// * Effective lattice N=64: 64^3 = 262144 texels = exactly 512x512 px.
/// * 8x8 tiles ([atlasTilesPerSide]), each 64x64 texels ([atlasTilePixels]).
/// * Tile `t = ty * 8 + tx` is one B slice: `b = (t + 0.5) / 64`.
/// * Within a tile: `r = (px + 0.5) / 64` along x, `g = (py + 0.5) / 64`
///   along y (texel centers, matching the shader's half-texel inset so
///   neighboring tiles never bleed into a sample).
///
/// The lattice is pure Dart, so it is evaluated on a worker isolate and the
/// result crosses back as raw RGBA. The UI isolate only uploads that buffer
/// (`decodeImageFromPixels`); it never runs 262k grade evaluations or a PNG
/// encode while the user is dragging, which used to freeze the first filter
/// switch and flash the ungraded CPU fallback.
///
/// Memory concern: holding all 9 atlases costs ~9MB GPU (+1MB each).
/// [prewarm] fills them one at a time after the first frame so the filter
/// strip and the first tap on a look never wait for a build; [clear] drops
/// them on memory pressure — entries rebuild on demand. The coarse N=16
/// [LutTables] (49KB each) are NOT cached here; they are generated on the
/// fly in the export isolate (Task 2.5).
abstract final class LutManager {
  /// Effective LUT lattice dimension packed into the atlas. MUST match
  /// `kLutSize` in `shaders/lens_filter.frag`.
  static const int atlasLutSize = 64;

  /// Tile grid per side. MUST match `kLutTiles` in the shader.
  static const int atlasTilesPerSide = 8;

  /// Pixels per tile side (512 / 8). One tile = one B slice of 64x64 RG.
  static const int atlasTilePixels = 64;

  /// Atlas edge in pixels ([atlasTilesPerSide] * [atlasTilePixels]).
  static const int atlasSize = atlasTilesPerSide * atlasTilePixels; // 512

  static final Map<LensFilterId, ui.Image> _cache = {};
  static final Map<LensFilterId, Future<ui.Image>> _inFlight = {};

  /// Returns the cached (or newly built) atlas for [id].
  ///
  /// The returned future instance is stable per [id] while a build is in
  /// flight, so widgets can hold it across rebuilds without restarting
  /// the build on every slider tick. [LensFilterId.none] resolves to an
  /// identity atlas, which keeps the shader on a single code path
  /// (sample-then-mix) for every filter.
  ///
  /// Images are cache-owned: callers MUST NOT dispose them; use [clear]
  /// to drop everything (e.g. on memory pressure).
  static Future<ui.Image> lutAtlasImage(LensFilterId id) {
    final ui.Image? hit = _cache[id];
    if (hit != null) return Future.value(hit);
    final Future<ui.Image>? pending = _inFlight[id];
    if (pending != null) return pending;
    Future<ui.Image> load() async {
      try {
        final ui.Image image = await _build(id);
        _cache[id] = image;
        return image;
      } finally {
        // The in-flight entry is dropped, not awaited: the callers own the
        // future they were handed.
        _inFlight.remove(id)?.ignore();
      }
    }

    final Future<ui.Image> future = load();
    _inFlight[id] = future;
    return future;
  }

  /// Builds every atlas in the background, one at a time.
  ///
  /// Called once after the first frame. Sequential on purpose: nine
  /// concurrent isolate builds would spike CPU and memory for no
  /// user-visible gain, while the UI isolate stays free either way.
  static Future<void> prewarm() async {
    for (final LensFilterId id in LensFilterId.values) {
      try {
        await lutAtlasImage(id);
      } catch (error, stackTrace) {
        // A failed atlas must never break warmup: the lazy path retries.
        AppLogger.w(
          'Atlas prewarm failed for ${id.name}; will retry lazily',
          context: 'lut_manager',
          error: error,
          stackTrace: stackTrace,
        );
      }
      // Give the engine a frame between uploads so warmup never competes
      // with the first paint or with a scroll in the gallery.
      await Future<void>.delayed(Duration.zero);
    }
  }

  /// Number of materialized atlases (0..9). Exposed for diagnostics and
  /// for asserting the ~1MB-per-filter memory budget in tests.
  static int get cachedCount => _cache.length;

  static bool isCached(LensFilterId id) => _cache.containsKey(id);

  /// The already-built atlas for [id], or null while it is still warming.
  ///
  /// Lets a preview render the grade on its very first frame when the atlas
  /// is cached, instead of waiting one [FutureBuilder] tick on a completed
  /// future and flashing the ungraded fallback.
  static ui.Image? cachedAtlas(LensFilterId id) => _cache[id];

  /// Disposes every cached atlas. They rebuild lazily via [lutAtlasImage].
  static void clear() {
    for (final ui.Image image in _cache.values) {
      image.dispose();
    }
    _cache.clear();
  }

  /// Renders [LutTables.gradePixel] at N=64 density on a worker isolate and
  /// uploads the raw RGBA buffer as a GPU image.
  ///
  /// No PNG round-trip: the old path encoded a 512x512 PNG on the UI
  /// isolate (tens of milliseconds) only to decode it again. The isolate
  /// owns the per-texel loop, so a filter switch never blocks a frame.
  static Future<ui.Image> _build(LensFilterId id) async {
    final int filterIndex = id.index;
    final Uint8List rgba = await Isolate.run(() => _atlasRgba(filterIndex));
    return _decodeRgba(rgba);
  }

  /// Evaluates the whole atlas into a top-down RGBA8 buffer.
  ///
  /// Top-level (static) and self-contained so it can run inside
  /// [Isolate.run] with only an `int` captured.
  static Uint8List _atlasRgba(int filterIndex) {
    final LensFilterId id = LensFilterId.values[filterIndex];
    final Uint8List out = Uint8List(atlasSize * atlasSize * 4);
    const double inv = 1.0 / atlasLutSize; // 1/64
    for (var ty = 0; ty < atlasTilesPerSide; ty++) {
      for (var tx = 0; tx < atlasTilesPerSide; tx++) {
        final int slice = ty * atlasTilesPerSide + tx;
        final double b = (slice + 0.5) * inv;
        final int baseX = tx * atlasTilePixels;
        final int baseY = ty * atlasTilePixels;
        for (var py = 0; py < atlasTilePixels; py++) {
          final double g = (py + 0.5) * inv;
          final int row = (baseY + py) * atlasSize;
          for (var px = 0; px < atlasTilePixels; px++) {
            final double r = (px + 0.5) * inv;
            final (double rr, double gg, double bb) = LutTables.gradePixel(
              id,
              r,
              g,
              b,
            );
            final int offset = (row + baseX + px) * 4;
            out[offset] = (rr * 255.0).round().clamp(0, 255);
            out[offset + 1] = (gg * 255.0).round().clamp(0, 255);
            out[offset + 2] = (bb * 255.0).round().clamp(0, 255);
            out[offset + 3] = 255;
          }
        }
      }
    }
    return out;
  }

  /// Uploads a raw RGBA8 buffer as an immutable GPU image.
  ///
  /// The descriptor path (buffer → `ImageDescriptor.raw` → codec) is used
  /// instead of the raw `decodeImageFromPixels` completer dance: every
  /// engine handle is disposed in `finally`, and a failed upload settles
  /// the returned future with an error. Without a settling failure the
  /// sequential [prewarm] chain would stall behind one dead upload.
  static Future<ui.Image> _decodeRgba(Uint8List rgba) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      rgba,
    );
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: atlasSize,
        height: atlasSize,
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
