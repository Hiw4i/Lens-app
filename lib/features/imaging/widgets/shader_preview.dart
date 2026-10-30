import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:lens/features/filters/lut_definition.dart';
import 'package:lens/features/filters/lut_manager.dart';
import 'package:lens/features/imaging/cache/preview_cache.dart';
import 'package:lens/features/imaging/cache/structure_cache.dart';
import 'package:lens/features/imaging/mask_manager.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/imaging/shaders/lens_controller.dart';
import 'package:lens/features/imaging/structure/structure_filter.dart';
import 'package:lens/features/selective/mask_raster.dart' show BrushStroke;
import 'package:lens/shared/diagnostics/app_logger.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// GPU preview of [imageBytes] graded by [params] through
/// `shaders/lens_filter.frag`.
///
/// Fallback chain (never blanks the preview):
/// 1. shader program ready -> [CustomPaint] with the [ui.FragmentShader];
/// 2. program null / decode failed / paint threw -> [Image.memory] (CPU).
class ShaderPreview extends StatefulWidget {
  const ShaderPreview({
    super.key,
    required this.imageBytes,
    required this.params,
    this.brushStrokes,
    this.blurMaskImage,
    this.fit = BoxFit.contain,
    this.previewMaxDim = 1080,
    this.fallbackBytes,
    this.squareCrop = false,
  });

  final Uint8List imageBytes;

  /// Predecoded transition raster keeps the photograph visible during warmup.
  final Uint8List? fallbackBytes;
  final LensParams params;

  /// Painted brush spines for the selective brush mask (sampler slot 2).
  /// Null (or empty) means "no brush" — the white stub stays bound, which
  /// matches the `toLensParams` off-fallback (empty brush → selMode 0).
  /// Grade-only ticks keep the same list identity, so [MaskManager] returns
  /// the identical future and the shader takes the in-place uniform path.
  final List<BrushStroke>? brushStrokes;

  /// Pre-decoded subject mask for the blur stage (sampler slot 3).
  ///
  /// Task 6.2 plumbing only: the real 256 foreground mask
  /// (BlurCache/ML or the manual raster, `MaskManager`-style `ui.Image`)
  /// arrives in Task 6.4 and is passed here ready-bound. Null binds the
  /// shared 1x1 white stub (all-subject = neutral no-op, same rationale
  /// as the `uSelMask` stub): with the default `blurMode 0` the shader
  /// skips before any mask read, so the stub is never sampled; a stray
  /// blur-active tick with no mask then degrades to "all sharp" instead
  /// of a full-frame blur or a blackout. A gray stub would NOT be
  /// neutral (m = 0.5 half-blurs the frame at full strength).
  final ui.Image? blurMaskImage;

  /// How the photo is placed in the available box.
  ///
  /// [BoxFit.cover] fills the box edge to edge and crops the overflow — the
  /// square filter thumbs use it so a non-square photo never leaves empty
  /// bars in the tile. Every other value lays the photo out at its own
  /// aspect inside the box (the editor preview's letterbox).
  final BoxFit fit;

  /// Centre-crop the photo to a SQUARE before it is graded.
  ///
  /// The filter thumbs live in a square tile, so the crop is done in the
  /// pixels: the source is already square, so the tile is filled edge to
  /// edge no matter which layout path draws it (the CPU fallback and the
  /// GPU path show the same picture, and neither can leave bars).
  /// Off by default — the editor preview shows the whole frame.
  final bool squareCrop;

  /// Longest side of the decoded preview texture. The main preview keeps
  /// the default 1080; filter-strip thumbs pass ~192 so nine live previews
  /// cost ~1MB of GPU textures instead of ~70MB. Must stay in sync with
  /// [PreviewCache.previewBytes], whose key includes this value.
  final int previewMaxDim;

  @override
  State<ShaderPreview> createState() => _ShaderPreviewState();
}

class _ShaderPreviewState extends State<ShaderPreview> {
  Future<ui.Image>? _decoded;

  /// Cached shader for the current (program, params, image, lut) tuple.
  ///
  /// [ui.FragmentShader] is single-use mutable state: allocating one per
  /// [CustomPainter.paint] (60Hz during slider drags) costs a native
  /// handle + 10 uniform writes + 2 sampler binds + a dispose every frame.
  /// Instead the shader is created here once per (program, params, image,
  /// lut) change — exactly the moments a [_LensFilterPainter] is rebuilt —
  /// and the painter only re-points the resolution uniforms (paint size can
  /// change with layout while params/image stay fixed) and issues the
  /// draw. The previous shader is disposed synchronously on replace and
  /// in [dispose], so no native handle ever leaks.
  ///
  /// Strength/intensity ticks do NOT recreate the shader (that would be a
  /// native alloc per 60Hz tick): when program/image/lut are identical and
  /// only [LensParams] moved, the floats are rewritten in place on the
  /// live shader (~20 setFloat calls, no handle churn). Recreation happens
  /// only on program/photo/filter switches. Measured shader creation is
  /// sub-millisecond, but the in-place path removes even that from drags.
  ui.FragmentShader? _shader;
  ui.FragmentProgram? _shaderProgram;
  LensParams? _shaderParams;
  ui.Image? _shaderImage;
  ui.Image? _shaderLut;
  ui.Image? _shaderMask;
  ui.Image? _shaderBlurMask;
  ui.Image? _shaderStructureMaps;

  /// LUT atlas future for the current filter id. The future instance is
  /// stable per id ([LutManager] caches + dedupes in-flight builds), so
  /// holding it across rebuilds never restarts the build on slider ticks.
  /// LUT images are cache-owned — never disposed here (see [dispose]).
  Future<ui.Image>? _lutFuture;
  int? _lutId;

  /// The last atlas that actually produced a frame, together with the params
  /// it was graded for.
  ///
  /// A filter switch replaces [params] immediately, but a new atlas may
  /// still be uploading (or a cached future may need one microtask before
  /// `FutureBuilder` reports it). Falling back to the CPU image in that
  /// window flashes the ungraded photograph — the previous complete grade is
  /// kept on screen until the new atlas is ready instead.
  ui.Image? _boundLut;
  LensParams? _boundParams;

  /// Structure maps (sampler slot 4) for the current preview raster.
  ///
  /// The maps do NOT depend on any slider value, so the future is stable per
  /// decoded preview ([_structureMapsPreview]): a structure tick reuses the
  /// completed snapshot and only rewrites the `uStructure` float in place.
  /// [_structureMapsImage] is owned by this state (a texture decoded from
  /// [StructureCache] bytes) and is disposed when the photo changes; the
  /// neutral stub is process-cached and never disposed here.
  Future<ui.Image>? _structureMapsFuture;
  ui.Image? _structureMapsPreview;
  ui.Image? _structureMapsImage;

  /// The 1x1 neutral stub as a ready `ui.Image`, filled in by [initState].
  ///
  /// While the real maps are still computing (a few ms on a 1080 px raster)
  /// or when they cannot be built at all, this stub stays bound: `a = 1,
  /// b = 0` makes the stage an exact no-op, so the preview shows the graded
  /// photo with no structure instead of flashing the CPU fallback.
  ui.Image? _stubStructureMaps;

  @override
  void initState() {
    super.initState();
    // Lazily created in build when the shader program is actually ready:
    // starting the decode here unconditionally leaves an unlistened future
    // (unhandled async error → crash-report noise) whenever the program
    // is null and the CPU fallback renders instead.
    _decoded = null;
    // A prewarmed atlas can grade the very first frame; without this the
    // first FutureBuilder tick would show the raw photo.
    final int id = widget.params.filterId.clamp(
      0,
      LensFilterId.values.length - 1,
    );
    _boundLut = LutManager.cachedAtlas(LensFilterId.values[id]);
    if (_boundLut != null) _boundParams = widget.params;
    // The structure stub is a 1x1 texture: decoding it takes a microtask, so
    // starting it here means the shader has something neutral to bind on its
    // very first frame, before the real maps finish computing.
    _neutralStructureImage().then<void>(
      (ui.Image image) {
        if (!mounted) return;
        setState(() => _stubStructureMaps = image);
      },
      onError: (Object _) {},
    );
  }

  @override
  void didUpdateWidget(ShaderPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.imageBytes, widget.imageBytes) ||
        oldWidget.previewMaxDim != widget.previewMaxDim ||
        oldWidget.squareCrop != widget.squareCrop) {
      // Drop the sampler-bound shader BEFORE the old image is disposed
      // (disposal itself is async via the future below).
      _disposeShader();
      _disposeStructureMaps();
      _disposeDecoded();
      // Created on demand in build (see _ensureDecoded) so an unconsumed
      // future never escapes while the CPU fallback is showing.
    } else if (!identical(oldWidget.blurMaskImage, widget.blurMaskImage)) {
      // The mask never changes the decoded photo: keep it so a mask swap
      // (blur on/off, or the crop-stage hand-off that drops the mask) does
      // not re-decode and flash the CPU fallback. _ensureShader rebinds the
      // sampler on the next build.
      _disposeShader();
    }
  }

  /// Returns the decode future, creating it on first use. Called only from
  /// paths that actually consume it ([FutureBuilder] in [build]), so a
  /// failing decode always has a listener (snapshot.hasError -> fallback)
  /// and never surfaces as an unhandled async error.
  Future<ui.Image> _ensureDecoded() =>
      _decoded ??= _load(
        widget.imageBytes,
        widget.previewMaxDim,
        square: widget.squareCrop,
      );

  static Future<ui.Image> _load(
    Uint8List bytes,
    int maxDim, {
    bool square = false,
  }) async {
    final preview = square
        ? await PreviewCache.squarePreviewBytes(bytes, maxDim: maxDim)
        : await PreviewCache.previewBytes(bytes, maxDim: maxDim);
    return _decode(preview);
  }

  // Framework wrapper (mockable via PaintingBinding), not the raw
  // dart:ui entrypoint whose arity changed in recent engines.
  static Future<ui.Image> _decode(Uint8List bytes) =>
      decodeImageFromList(bytes);

  void _disposeDecoded() {
    // Swallow decode errors: a failed future has already rendered the CPU
    // fallback via snapshot.hasError — disposal must never re-raise it as
    // an unhandled async error (same crash-report noise class as the lazy
    // _ensureDecoded fix above).
    _decoded?.then<void>((image) => image.dispose(), onError: (_) {}).ignore();
    _decoded = null;
  }

  void _disposeShader() {
    _shader?.dispose();
    _shader = null;
    _shaderProgram = null;
    _shaderParams = null;
    _shaderImage = null;
    _shaderLut = null;
    // Mask atlas is stub-owned (see _whiteMaskImage) — never disposed here,
    // same ownership rule as the LutManager atlas above.
    _shaderMask = null;
    // Blur-mask image is caller-owned (Task 6.4 passes it ready-bound) or
    // the shared white stub — never disposed here either.
    _shaderBlurMask = null;
    // Structure maps are state-owned ([_disposeStructureMaps]) or the shared
    // neutral stub — never disposed here.
    _shaderStructureMaps = null;
  }

  /// Drops the structure maps of the outgoing preview raster.
  ///
  /// The maps image is decoded from [StructureCache] bytes, so this state
  /// owns it (the cached bytes are not a GPU resource); the in-flight future
  /// is only forgotten — its completion disposes the stale image itself when
  /// the preview it was built for is no longer current.
  void _disposeStructureMaps() {
    _structureMapsImage?.dispose();
    _structureMapsImage = null;
    _structureMapsFuture = null;
    _structureMapsPreview = null;
  }

  /// 1x1 white brush-mask stub for Task 4.2 (Task 4.5 builds MaskManager).
  ///
  /// The `uSelMask` sampler (slot 2) must ALWAYS be bound — the frag samples
  /// it unconditionally so the slot survives elimination (analytic modes
  /// ignore the texel, brush mode reads `.r`). Until brush strokes exist,
  /// every preview binds this cached stub: white so that a stray brush-mode
  /// tick with no raster is a full-strength no-op-grade rather than a
  /// blackout. Process-wide cached, LutManager-style: one 1x1 GPU texture.
  static Future<ui.Image>? _whiteMaskFuture;
  static Future<ui.Image> _whiteMaskImage() {
    final Future<ui.Image>? cached = _whiteMaskFuture;
    if (cached != null) return cached;
    late final Future<ui.Image> future;
    future = () async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 1, 1),
        Paint()..color = const Color(0xFFFFFFFF),
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(1, 1);
      picture.dispose();
      return image;
    }().catchError((Object error, StackTrace stackTrace) {
      if (identical(_whiteMaskFuture, future)) _whiteMaskFuture = null;
      AppLogger.w(
        'White brush-mask stub creation failed',
        context: 'shader_preview',
        error: error,
        stackTrace: stackTrace,
      );
      throw error;
    });
    _whiteMaskFuture = future;
    return future;
  }

  /// Stable blur-mask image: the Task 6.4 mask ([blurMaskImage],
  /// MaskManager/BlurCache 256 raster as a `ui.Image`) when provided, else
  /// the cached 1x1 white stub (all-subject = neutral no-op — with the
  /// default `blurMode 0` the shader skips before any mask read, so the
  /// stub is never sampled). A [Future] so it composes with [_maskFor] in
  /// the same `FutureBuilder` pattern; the completed value is part of the
  /// [_ensureShader] tuple.
  Future<ui.Image> _blurMaskFor() {
    final ui.Image? provided = widget.blurMaskImage;
    if (provided != null) return Future<ui.Image>.value(provided);
    return _whiteMaskImage();
  }

  /// Stable mask future: the rasterized 128 brush mask in brush mode
  /// (selMode 3, `MaskManager`-cached per structural stroke key), the
  /// cached 1x1 white stub everywhere else — including brush mode with an
  /// empty stroke list (the `toLensParams` off-fallback emits selMode 0
  /// there, so the stub is never sampled with an empty raster).
  /// [MaskManager] returns the identical future for unchanged strokes, so
  /// grade ticks reuse the completed snapshot with no flicker and keep the
  /// in-place uniform path (mask image identity is part of the
  /// [_ensureShader] tuple).
  Future<ui.Image> _maskFor() {
    final List<BrushStroke>? strokes = widget.brushStrokes;
    if (widget.params.selMode == 3 && strokes != null) {
      final Future<ui.Image>? raster = MaskManager.maskImage(strokes);
      if (raster != null) return raster;
    }
    return _whiteMaskImage();
  }

  /// Stable structure-maps future for [preview] (sampler slot 4).
  ///
  /// Keyed by the decoded preview image identity: the maps depend on the
  /// raster (its size and square crop), NEVER on a slider value, so a
  /// structure tick keeps the completed snapshot and the shader is reused
  /// with only `uStructure` rewritten in place.
  Future<ui.Image> _structureMapsFor(ui.Image preview) {
    final Future<ui.Image>? cached = _structureMapsFuture;
    if (cached != null && identical(_structureMapsPreview, preview)) {
      return cached;
    }
    final Future<ui.Image> future = _loadStructureMaps(preview);
    _structureMapsFuture = future;
    _structureMapsPreview = preview;
    return future;
  }

  /// Builds the maps for [preview] and uploads them as an image.
  ///
  /// Never throws: a cache miss that cannot decode, or an unexpected upload
  /// failure, resolves to the neutral stub, so the shader always has a
  /// texture in slot 4 and the stage degrades to a no-op (not to a blackout
  /// or a CPU fallback flicker).
  Future<ui.Image> _loadStructureMaps(ui.Image preview) async {
    final Future<ui.Image> stub = _neutralStructureImage();
    ui.Image? maps;
    try {
      final Uint8List? packed = await StructureCache.mapsFor(
        widget.imageBytes,
        targetWidth: preview.width,
        targetHeight: preview.height,
        square: widget.squareCrop,
      );
      if (packed != null) {
        final (int lowWidth, int lowHeight) = _mapsGrid(preview, packed.length);
        // Byte-length must match the declared grid exactly: a packing
        // contract drift would otherwise either throw inside the engine
        // (short buffer) or decode stale pixels as if they were current
        // (long buffer). Both degrade to the neutral stub instead.
        if (lowWidth > 0 &&
            lowHeight > 0 &&
            packed.length == lowWidth * lowHeight * 4) {
          final ui.Image uploaded = await _imageFromPacked(
            packed,
            lowWidth,
            lowHeight,
          );
          // The photo changed while the filter was running: this texture
          // belongs to a raster that is no longer on screen.
          if (!mounted || !identical(_structureMapsPreview, preview)) {
            uploaded.dispose();
          } else {
            _structureMapsImage = uploaded;
            maps = uploaded;
          }
        } else {
          AppLogger.w(
            'Structure maps rejected: grid $lowWidth×$lowHeight does not '
            'match ${packed.length} packed bytes',
            context: 'shader_preview',
          );
        }
      }
    } catch (error, stackTrace) {
      // Fall through to the neutral stub below: the structure stage
      // degrades to a no-op, never to a blackout.
      AppLogger.w(
        'Structure maps unavailable; stage degraded to no-op',
        context: 'shader_preview',
        error: error,
        stackTrace: stackTrace,
      );
    }
    return maps ?? await stub;
  }

  /// The low-res grid of the packed [byteLength], in texels.
  ///
  /// A square crop packs a square grid, so its side is recoverable from the
  /// byte length; the plain raster always has the grid the shared geometry
  /// derives for the preview size.
  (int, int) _mapsGrid(ui.Image preview, int byteLength) {
    final int texels = byteLength ~/ 4;
    if (texels <= 0) return (0, 0);
    if (widget.squareCrop) {
      final int side = math.sqrt(texels).round();
      return side * side == texels ? (side, side) : (0, 0);
    }
    final StructureGeometry geometry = structureGeometryFor(
      preview.width,
      preview.height,
    );
    return (
      (preview.width / geometry.subsample).ceil(),
      (preview.height / geometry.subsample).ceil(),
    );
  }

  /// Uploads packed RGBA8888 [bytes] as a `ui.Image` (sampler slot 4).
  ///
  /// The descriptor path (buffer → `ImageDescriptor.raw` → codec) is used
  /// instead of the raw `decodeImageFromPixels` completer dance: every
  /// engine handle is disposed in `finally` and a failure settles the
  /// returned future with an error the caller maps to the neutral stub,
  /// instead of pending forever.
  static Future<ui.Image> _imageFromPacked(
    Uint8List bytes,
    int width,
    int height,
  ) async {
    final ui.ImmutableBuffer buffer = await ui.ImmutableBuffer.fromUint8List(
      bytes,
    );
    ui.ImageDescriptor? descriptor;
    ui.Codec? codec;
    try {
      descriptor = ui.ImageDescriptor.raw(
        buffer,
        width: width,
        height: height,
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

  /// Process-wide 1x1 neutral structure stub (a = 1, b = 0), LutManager-style
  /// cached: one texture for every preview in the app, never disposed.
  ///
  /// A failed stub upload is NOT memoized: the memo clears so the next
  /// preview retries instead of inheriting the failure for the process
  /// lifetime.
  static Future<ui.Image>? _neutralStructureFuture;
  static Future<ui.Image> _neutralStructureImage() {
    final Future<ui.Image>? cached = _neutralStructureFuture;
    if (cached != null) return cached;
    // `late` lets the error path clear the memo by comparing identities:
    // a failed stub upload must not stay memoized for the process lifetime.
    late final Future<ui.Image> future;
    future = _imageFromPacked(
      StructureCache.neutralStubBytes(),
      1,
      1,
    ).catchError((Object error, StackTrace stackTrace) {
      if (identical(_neutralStructureFuture, future)) {
        _neutralStructureFuture = null;
      }
      AppLogger.w(
        'Neutral structure stub upload failed',
        context: 'shader_preview',
        error: error,
        stackTrace: stackTrace,
      );
      throw error;
    });
    _neutralStructureFuture = future;
    return future;
  }

  /// Stable atlas future for [filterId] (0..8, clamped). Same id returns
  /// the same future instance, so the inner FutureBuilder in [build] keeps
  /// its snapshot across slider ticks (no spinner flicker mid-drag).
  Future<ui.Image> _lutFor(int filterId) {
    final int id = filterId.clamp(0, LensFilterId.values.length - 1);
    final Future<ui.Image>? cached = _lutFuture;
    if (cached != null && _lutId == id) return cached;
    final Future<ui.Image> future = LutManager.lutAtlasImage(
      LensFilterId.values[id],
    );
    _lutFuture = future;
    _lutId = id;
    return future;
  }

  /// Writes the grade floats of [params] onto [shader]:
  /// `toUniforms()[0..8]` -> slots 0..8, `toUniforms()[9]` -> slot 11
  /// (slots 9..10 are uResolution, owned by the painter/creation site),
  /// `toUniforms()[10..18]` -> slots 12..20 (the Enhance core block),
  /// `toUniforms()[19..31]` -> slots 21..33 (Task 4.2 Selective block),
  /// `toUniforms()[32..36]` -> slots 34..38 (Task 6.2 Blur block),
  /// `toUniforms()[37..46]` -> slots 39..48 (Task 7.2 Rays block),
  /// `toUniforms()[47..54]` -> slots 49..56 (the derived auto-grade tail
  /// of the Enhance stage) and `toUniforms()[55]` -> slot 57 (`uEnhLook`,
  /// the built-in cinematic finish — omitting it left the GPU preview
  /// without the look the CPU export applies).
  /// Safe to call on an already-bound live shader for the in-place tick
  /// path — sampler bindings are untouched.
  /// Task 4.4 aspect contract: the slot-28 value written here (the stored
  /// `selAspect` fallback from `toLensParams`) is OVERWRITTEN by
  /// [_LensFilterPainter.paint] with the real paint size aspect before
  /// every draw, so the radial ellipse is always computed in the paint
  /// context — visually identical to the CPU export, which recomputes it
  /// from the frame `w/h` (aspectOverride in `applyLensGrade`).
  static void _writeGradeUniforms(ui.FragmentShader shader, LensParams params) {
    final List<double> uniforms = params.toUniforms();
    for (var i = 0; i < 9; i++) {
      shader.setFloat(i, uniforms[i]);
    }
    shader.setFloat(11, uniforms[9]);
    for (var i = 0; i < 9; i++) {
      shader.setFloat(12 + i, uniforms[10 + i]);
    }
    for (var i = 0; i < 13; i++) {
      shader.setFloat(21 + i, uniforms[19 + i]);
    }
    for (var i = 0; i < 5; i++) {
      shader.setFloat(34 + i, uniforms[32 + i]);
    }
    for (var i = 0; i < 10; i++) {
      shader.setFloat(39 + i, uniforms[37 + i]);
    }
    for (var i = 0; i < 8; i++) {
      shader.setFloat(49 + i, uniforms[47 + i]);
    }
    shader.setFloat(57, uniforms[55]);
  }

  /// Returns a ready-to-draw shader for ([program], [params], [image],
  /// [lut], [mask], [blurMask], [structureMaps]), reusing the cached one when
  /// the tuple is unchanged.
  /// Grade uniforms (slots 0..8, 11, 12..20, 21..33, 34..38, 39..48, 49..56) and all five
  /// image samplers are written exactly once at creation; the resolution
  /// uniforms (slots 9..10) are refreshed by the painter from the paint
  /// [Size].
  /// When only [params] moved (the 60Hz slider-tick case), the floats are
  /// rewritten in place on the live shader instead of reallocating. The
  /// params comparison is `LensParams.==`, which covers the Task 3.2
  /// Enhance fields, the Task 4.2 Selective fields, the Task 6.2 Blur
  /// fields AND the Task 7.2 Rays fields, so an enhance, selective, blur,
  /// or rays tick never serves a stale grade. Null when shader creation throws (caller falls back to CPU).
  ui.FragmentShader? _ensureShader(
    ui.FragmentProgram program,
    LensParams params,
    ui.Image image,
    ui.Image lut,
    ui.Image mask,
    ui.Image blurMask,
    ui.Image structureMaps,
  ) {
    final cached = _shader;
    if (cached != null &&
        identical(_shaderProgram, program) &&
        identical(_shaderImage, image) &&
        identical(_shaderLut, lut) &&
        identical(_shaderMask, mask) &&
        identical(_shaderBlurMask, blurMask) &&
        identical(_shaderStructureMaps, structureMaps)) {
      if (_shaderParams != params) {
        try {
          _writeGradeUniforms(cached, params);
          _shaderParams = params;
        } catch (error, stackTrace) {
          // Uniform-write failure: drop the poisoned shader and rebuild it
          // from scratch (same tuple, fresh program instance).
          AppLogger.d(
            'Grade uniform write failed; rebuilding shader',
            context: 'shader_preview',
            error: error,
            stackTrace: stackTrace,
          );
          _disposeShader();
          return _createShader(
            program,
            params,
            image,
            lut,
            mask,
            blurMask,
            structureMaps,
          );
        }
      }
      return cached;
    }
    _disposeShader();
    return _createShader(
      program,
      params,
      image,
      lut,
      mask,
      blurMask,
      structureMaps,
    );
  }

  ui.FragmentShader? _createShader(
    ui.FragmentProgram program,
    LensParams params,
    ui.Image image,
    ui.Image lut,
    ui.Image mask,
    ui.Image blurMask,
    ui.Image structureMaps,
  ) {
    try {
      final shader = program.fragmentShader();
      _writeGradeUniforms(shader, params);
      // Placeholder resolution; the painter overwrites it with the real
      // paint size before every draw.
      shader.setFloat(9, image.width.toDouble());
      shader.setFloat(10, image.height.toDouble());
      shader.setImageSampler(0, image);
      shader.setImageSampler(1, lut);
      shader.setImageSampler(2, mask);
      shader.setImageSampler(3, blurMask);
      // Bilinear filtering is REQUIRED for slot 4: the maps are a low-res
      // grid, and the shader's `texture(uStructureMaps, uv)` has to be the
      // same bilinear texel-centre interpolation as the export's
      // `structureBaseAt`. `none` (nearest) would snap to the nearest texel
      // and quantise the base into visible blocks; `medium`/`high` add
      // mipmaps, which ignore the texel-centre mapping.
      shader.setImageSampler(
        4,
        structureMaps,
        filterQuality: ui.FilterQuality.low,
      );
      _shader = shader;
      _shaderProgram = program;
      _shaderParams = params;
      _shaderImage = image;
      _shaderLut = lut;
      _shaderMask = mask;
      _shaderBlurMask = blurMask;
      _shaderStructureMaps = structureMaps;
      return shader;
    } catch (error, stackTrace) {
      // One-time, invisible degradation to the CPU fallback — worth one log
      // line, because nothing else on screen explains the lost quality.
      AppLogger.w(
        'Shader creation failed; preview degraded to CPU fallback',
        context: 'shader_preview',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  @override
  void dispose() {
    // NOTE: the LUT atlas (_lutFuture) is LutManager-owned and stays
    // cached for instant filter switches — never disposed here.
    _disposeShader();
    _disposeStructureMaps();
    _disposeDecoded();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Subscribes to warm-up: a preview built before `precache` finished
    // starts on the CPU fallback and rebuilds into the GPU path the moment
    // the program lands, with no polling and no parent rebuild.
    return ValueListenableBuilder<ui.FragmentProgram?>(
      valueListenable: LensShaderController.programVN,
      builder: (context, program, _) {
        if (program == null) {
          // Shader not compiled (yet) — CPU fallback keeps the preview alive.
          return _CpuFallback(
            bytes: widget.fallbackBytes ?? widget.imageBytes,
            fit: widget.fit,
          );
        }
        return FutureBuilder<ui.Image>(
          // Created on demand so the future always has a listener:
          // snapshot.hasError below renders the CPU fallback.
          future: _ensureDecoded(),
          builder: (context, snapshot) {
            final image = snapshot.data;
            if (image == null) {
              if (snapshot.hasError) {
                return _CpuFallback(
                  bytes: widget.fallbackBytes ?? widget.imageBytes,
                  fit: widget.fit,
                );
              }
              return _CpuFallback(
                bytes: widget.fallbackBytes ?? widget.imageBytes,
                fit: widget.fit,
              );
            }
            final aspect = image.width / image.height;
            // LUT atlas for the selected filter (identity atlas for none).
            // _lutFor returns a stable future per id: strength/intensity
            // ticks reuse the completed snapshot (no flicker), a filter
            // switch shows one spinner while the atlas builds once.
            final lutFuture = _lutFor(widget.params.filterId);
            return FutureBuilder<ui.Image>(
              future: lutFuture,
              builder: (context, lutSnapshot) {
                final readyLut = lutSnapshot.data;
                if (readyLut != null) {
                  _boundLut = readyLut;
                  _boundParams = widget.params;
                } else if (lutSnapshot.hasError ||
                    _boundLut == null ||
                    _boundParams == null) {
                  return _CpuFallback(
                    bytes: widget.fallbackBytes ?? widget.imageBytes,
                    fit: widget.fit,
                  );
                }
                // Keep the last complete grade while a new atlas is on its
                // way: never flash the ungraded photograph on a filter
                // switch. The stale window is one frame for a cached atlas
                // and a few frames on a cold one.
                final ui.Image lut = readyLut ?? _boundLut!;
                final LensParams params = readyLut != null
                    ? widget.params
                    : _boundParams!;
                // Brush-mask texture (Task 4.2: cached 1x1 white stub;
                // Task 4.5 swaps in the rasterized 128 mask). Stable future
                // per mask revision, so selective ticks reuse the completed
                // snapshot with no flicker.
                return FutureBuilder<ui.Image>(
                  future: _maskFor(),
                  builder: (context, maskSnapshot) {
                    final mask = maskSnapshot.data;
                    if (mask == null) {
                      if (maskSnapshot.hasError) {
                        return _CpuFallback(
                          bytes: widget.fallbackBytes ?? widget.imageBytes,
                          fit: widget.fit,
                        );
                      }
                      return _CpuFallback(
                        bytes: widget.fallbackBytes ?? widget.imageBytes,
                        fit: widget.fit,
                      );
                    }
                    // Subject-mask texture (Task 6.2: cached 1x1 white stub;
                    // Task 6.4 passes the real 256 ML/manual mask via
                    // [blurMaskImage]). Same stable-future pattern as above.
                    return FutureBuilder<ui.Image>(
                      future: _blurMaskFor(),
                      builder: (context, blurSnapshot) {
                        final blurMask = blurSnapshot.data;
                        if (blurMask == null) {
                          if (blurSnapshot.hasError) {
                            return _CpuFallback(
                              bytes: widget.fallbackBytes ?? widget.imageBytes,
                              fit: widget.fit,
                            );
                          }
                          return _CpuFallback(
                            bytes: widget.fallbackBytes ?? widget.imageBytes,
                            fit: widget.fit,
                          );
                        }
                        // Structure maps (sampler slot 4): the guided-filter
                        // base/detail coefficients of this preview raster,
                        // computed once per photo — structure ticks reuse the
                        // completed snapshot. While they are still computing
                        // the neutral stub stays bound (an exact no-op), so
                        // the preview never flashes the CPU fallback just
                        // because the filter is a few milliseconds behind.
                        return FutureBuilder<ui.Image>(
                          future: _structureMapsFor(image),
                          builder: (context, mapsSnapshot) {
                            final ui.Image? structureMaps =
                                mapsSnapshot.data ?? _stubStructureMaps;
                            if (structureMaps == null) {
                              // Only the first frames, before the 1x1 stub
                              // has finished decoding.
                              return _CpuFallback(
                                bytes:
                                    widget.fallbackBytes ?? widget.imageBytes,
                                fit: widget.fit,
                              );
                            }
                            final shader = _ensureShader(
                              program,
                              params,
                              image,
                              lut,
                              mask,
                              blurMask,
                              structureMaps,
                            );
                            if (shader == null) {
                              return _CpuFallback(
                                bytes:
                                    widget.fallbackBytes ?? widget.imageBytes,
                                fit: widget.fit,
                              );
                            }
                            return RepaintBoundary(
                              child: _AspectFit(
                                aspect: aspect,
                                fit: widget.fit,
                                child: CustomPaint(
                                  painter: _LensFilterPainter(
                                    image: image,
                                    params: params,
                                    shader: shader,
                                    fit: widget.fit,
                                  ),
                                ),
                              ),
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

/// Places the shader paint rect (which *is* the photo — the frag maps uv
/// 0..1 across the whole rect) inside the available box per [fit].
///
/// `contain` (and every other fit) letterboxes at the photo [aspect], which
/// is exactly what the editor preview wants. [BoxFit.cover] does not rescale
/// the shader: it grows the paint rect past the box on the free axis and
/// clips, so the photo still grades in its own uv/aspect space while the box
/// ends up filled edge to edge (the square filter thumbs).
class _AspectFit extends StatelessWidget {
  const _AspectFit({
    required this.aspect,
    required this.fit,
    required this.child,
  });

  final double aspect;
  final BoxFit fit;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (fit != BoxFit.cover || !aspect.isFinite || aspect <= 0) {
      return Center(
        child: AspectRatio(aspectRatio: aspect, child: child),
      );
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final double boxW = constraints.maxWidth;
        final double boxH = constraints.maxHeight;
        if (!boxW.isFinite || !boxH.isFinite || boxW <= 0 || boxH <= 0) {
          return Center(
            child: AspectRatio(aspectRatio: aspect, child: child),
          );
        }
        // Cover: the box side that is proportionally smaller binds, so the
        // photo is scaled until the other side overflows and gets clipped.
        final Size photo = boxW / boxH > aspect
            ? Size(boxW, boxW / aspect)
            : Size(boxH * aspect, boxH);
        return ClipRect(
          child: OverflowBox(
            minWidth: 0,
            maxWidth: double.infinity,
            minHeight: 0,
            maxHeight: double.infinity,
            alignment: Alignment.center,
            child: SizedBox(
              width: photo.width,
              height: photo.height,
              child: child,
            ),
          ),
        );
      },
    );
  }
}

class _CpuFallback extends StatelessWidget {
  const _CpuFallback({required this.bytes, required this.fit});

  final Uint8List bytes;
  final BoxFit fit;

  @override
  Widget build(BuildContext context) {
    // Corrupt bytes degrade to an icon, never an exception splash:
    // this widget is the last resort of the preview fallback chain.
    return Image.memory(
      bytes,
      fit: fit,
      gaplessPlayback: true,
      errorBuilder: (context, _, _) =>
          const Center(child: Icon(LucideIcons.imageOff, size: 48)),
    );
  }
}

/// Paints [image] through a ready-made Lens filter [shader].
///
/// The shader is owned by [_ShaderPreviewState] (created once per
/// params/image change, uniforms + sampler pre-bound); this painter only
/// refreshes the resolution uniforms and draws, so [paint] never
/// allocates or disposes native handles.
///
/// Uniform layout mirrors `lens_filter.frag` declaration order:
/// samplers 0/1/2/3 = uImage/uLut/uSelMask/uBlurMask; floats 0..8 =
/// exposure..structure plus float 11 = uFilterStrength, floats 12..20 =
/// Enhance core block, floats 21..33 = Selective block, floats 34..38 =
/// Blur block, floats 39..48 = Rays block and floats 49..56 = the derived
/// auto-grade tail of the Enhance stage (grade, pre-bound /
/// rewritten in place); floats 9..10 = uResolution (paint size,
/// refreshed here).
/// Float 28 (uSelAspect) is ALSO refreshed here from the paint [Size]
/// (Task 4.4 aspect contract): the painter's size is the only context that
/// knows the real preview ratio, so the params value is never trusted —
/// the CPU export does the symmetric override from the frame `w/h`.
class _LensFilterPainter extends CustomPainter {
  _LensFilterPainter({
    required this.image,
    required this.params,
    required this.shader,
    required this.fit,
  });

  final ui.Image image;
  final LensParams params;
  final ui.FragmentShader shader;
  final BoxFit fit;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    try {
      shader.setFloat(9, size.width);
      shader.setFloat(10, size.height);
      // Task 4.4 aspect contract: slot 28 is ALWAYS the paint aspect, never
      // the params value (the painter owns the only true preview ratio).
      if (size.height > 0) {
        shader.setFloat(28, size.width / size.height);
      }
      canvas.drawRect(Offset.zero & size, Paint()..shader = shader);
    } catch (_) {
      // Driver hiccup must never blank the editor: paint the raw image.
      paintImage(
        canvas: canvas,
        rect: Offset.zero & size,
        image: image,
        fit: fit,
      );
    }
  }

  @override
  bool shouldRepaint(_LensFilterPainter oldDelegate) =>
      !identical(oldDelegate.shader, shader) ||
      !identical(oldDelegate.image, image) ||
      oldDelegate.params != params ||
      oldDelegate.fit != fit;
}
