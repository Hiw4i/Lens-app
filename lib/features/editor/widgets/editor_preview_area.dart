import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/blur/blur_cache.dart';
import 'package:lens/features/blur/blur_overlay.dart';
import 'package:lens/features/blur/subject_mask.dart';
import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/crop/crop_stage.dart';
import 'package:lens/features/crop/crop_viewport.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/photo_viewport.dart';
import 'package:lens/features/imaging/mask_manager.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/imaging/widgets/shader_preview.dart';
import 'package:lens/features/library/photo_hero.dart';
import 'package:lens/features/rays/rays_overlay.dart';
import 'package:lens/features/selective/selective_overlay.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/widgets/indicators/app_badge.dart';

/// Preview card: rebuilds on preview bytes / compare-hold / grade only.
/// The top bar and tool rail are siblings, so their subtrees stay put.
///
/// [EditorStateToLensParams] carries adjust + filter (atlas selector +
/// strength slot) + enhance (cached analysis + strength mix) + selective +
/// blur + rays (float uniforms only); compare-hold swaps in [LensParams.identity]
/// (filterId 0, enhance strength 0), so the original bypasses the LUT AND
/// the enhance stage as well as the grade. Export forwards the same params.
///
/// Blur mask resolve (Task 6.4): `toLensParams` carries only floats; the
/// mask texture is resolved HERE (not in the state): manual source binds
/// the cached 128 raster via `MaskManager.maskImage(strokes)`, auto source
/// binds the ML 256 mask via `BlurCache.get(bytes)` -> `MaskManager.
/// floatMaskImage` (gray RGB, the shader reads `.r`). Null binds the
/// shared 1x1 white stub (all-subject = neutral no-op) inside
/// [ShaderPreview]. A null settle (desktop/ML-fail) shows an honest hint
/// with a Manual button — no spinner (concern 6.1#4).
class EditorPreviewArea extends ConsumerStatefulWidget {
  const EditorPreviewArea({
    super.key,
    this.photoId,
    this.aspectRatio = 1,
    this.transitionBytes,
    this.captureKey,
    this.visibleInsets = EdgeInsets.zero,
    this.cropInsets = EdgeInsets.zero,
  });

  final GlobalKey? captureKey;
  final String? photoId;
  final double aspectRatio;
  final Uint8List? transitionBytes;

  /// The area the floating chrome leaves free — the photo rests inside it.
  final EdgeInsets visibleInsets;

  /// The area the crop stage works in, clear of the chrome and with room
  /// beside the screen for its corner handles.
  final EdgeInsets cropInsets;

  @override
  ConsumerState<EditorPreviewArea> createState() => _EditorPreviewAreaState();
}

class _EditorPreviewAreaState extends ConsumerState<EditorPreviewArea>
    with SingleTickerProviderStateMixin {
  /// One photo widget for the normal viewport AND the crop stage.
  ///
  /// The key lets Flutter move the [ShaderPreview] State across the
  /// composition swap instead of unmounting it. Without it the hand-off
  /// re-decodes the photo and flashes the CPU fallback on exactly the frame
  /// the crop chrome appears, which breaks the seamless morph.
  final GlobalKey _photoKey = GlobalKey(debugLabel: 'editor-photo');

  /// Drives the crop in/out photo morph. Always runs 0 -> 1; [_morphToCrop]
  /// picks which endpoint the progress maps to.
  late final AnimationController _cropMorph;

  /// True while the photo is travelling between the two compositions.
  bool _morphing = false;
  bool _morphToCrop = true;

  /// Compare-hold bookkeeping. Instance fields (not statics): a remount of
  /// this widget then starts from a clean slate instead of inheriting a
  /// pending timer or a leaked pointer count.
  int _pointerCount = 0;
  Timer? _compareTimer;

  @override
  void initState() {
    super.initState();
    _cropMorph = AnimationController(vsync: this)
      ..addListener(_onMorphTick)
      ..addStatusListener(_onMorphStatus);
  }

  @override
  void dispose() {
    _compareTimer?.cancel();
    _cropMorph.dispose();
    super.dispose();
  }

  /// Rebuilds on every morph tick. The morph geometry (spec, aspect,
  /// insets) is derived in [build] from the controller value, so the morph
  /// must drive its OWN rebuilds — the parent sheet animation only
  /// coincides with the morph while the sheet is itself animating, and a
  /// re-measure that settles early would otherwise freeze the morph on
  /// its first frame.
  void _onMorphTick() {
    if (mounted && _morphing) setState(() {});
  }

  void _onMorphStatus(AnimationStatus status) {
    if (status != AnimationStatus.completed) return;
    // The controller is now at the target endpoint; the composition built
    // from the interpolated geometry matches the settled crop stage / normal
    // viewport exactly, so the swap is invisible.
    if (mounted && _morphing) setState(() => _morphing = false);
  }

  /// Starts (or re-targets) the crop morph when the tool flips.
  ///
  /// Enter maps the geometry normal -> crop; exit maps crop -> normal. Both
  /// run the controller forward and are eased in [build], matching the
  /// sheet-height curve so the photo and the chrome move as one.
  void _onToolChanged(EditorTool? previous, EditorTool next) {
    final bool enter = next == EditorTool.crop && previous != EditorTool.crop;
    final bool exit = previous == EditorTool.crop && next != EditorTool.crop;
    if (!enter && !exit) return;
    final Duration duration = context.uiPerformance.motionDuration(
      EditorPanelMetrics.resizeDuration,
    );
    if (duration == Duration.zero) {
      // Reduced motion / Performance: switch compositions instantly rather
      // than freezing a half-morphed frame.
      if (_morphing) setState(() => _morphing = false);
      return;
    }
    _cropMorph.duration = duration;
    _morphToCrop = enter;
    _cropMorph.value = 0;
    setState(() => _morphing = true);
    _cropMorph.forward();
  }

  @override
  Widget build(BuildContext context) {
    // Registered before any early return, as Riverpod requires.
    ref.listen(editorStateProvider.select((s) => s.tool), _onToolChanged);
    final bytes = ref.watch(editorStateProvider.select((s) => s.previewBytes));
    final showOriginal = ref.watch(
      editorStateProvider.select((s) => s.showOriginal),
    );
    final tool = ref.watch(editorStateProvider.select((s) => s.tool));
    final selective = ref.watch(editorStateProvider.select((s) => s.selective));
    final blur = ref.watch(editorStateProvider.select((s) => s.blur));
    final rays = ref.watch(editorStateProvider.select((s) => s.rays));
    // Async ML nonce: re-resolves the auto mask when the prewarm settles
    // without any grade edit (manual strokes are covered by `blur`
    // equality above — a dab already rebuilds us).
    ref.watch(editorStateProvider.select((s) => s.blurAnalysisVersion));
    // LensParams has value equality, so this select dedups: ticks that
    // don't change the grade (tool switches, depth-only commits) skip us.
    // Brush dabs do NOT move toLensParams (strokes cross via the sampler,
    // not the uniforms) — the overlay watches above rebuild us for those.
    final lensParams = ref.watch(
      editorStateProvider.select((s) => s.toLensParams()),
    );
    final notifier = ref.read(editorStateProvider.notifier);
    final params = showOriginal ? LensParams.identity : lensParams;
    // Crop geometry, watched here rather than inside the LayoutBuilder
    // below: that builder runs during layout, and Riverpod only allows
    // `ref.watch` during an actual build.
    final CropSpec cropSpec = ref.watch(
      editorStateProvider.select((s) => s.crop),
    );
    final Size cropSource = CropSpec.nominalSource(
      ref.watch(editorStateProvider.select((s) => s.photoAspect)),
    );
    // The overlay owns photo gestures (pan/pinch/paint): the compare-hold
    // Listener below is raw pointers (arenas do NOT block it), so it must
    // go away while the overlay is up or every mask drag would ALSO flip
    // the grade mid-gesture. Hold-to-compare is unavailable in selective,
    // manual-blur and rays modes by design.
    final selectiveOverlayVisible =
        tool == EditorTool.selective && selective.active;
    final blurOverlayVisible =
        tool == EditorTool.blur &&
        blur.source == SubjectSource.manual &&
        blur.strength > 0;
    final raysOverlayVisible = tool == EditorTool.rays && rays.intensity > 0;
    final overlayVisible =
        selectiveOverlayVisible || blurOverlayVisible || raysOverlayVisible;

    if (bytes == null) {
      return Center(
        child: Text(
          'Choose a photo to start editing',
          style: AppTextStyles.bodyDim(context),
        ),
      );
    }
    // Effective blur for the mask: strength > 0 AND (auto OR manual with
    // paint). Manual-empty and strength-0 both mean off (mode 0) — the
    // white stub stays bound (neutral), same off-fallback as toLensParams.
    final bool hasBlurPaint = blur.strokes.any((s) => s.points.isNotEmpty);
    final bool blurMaskActive =
        !showOriginal &&
        blur.strength > 0 &&
        !(blur.source == SubjectSource.manual && !hasBlurPaint);
    final Future<ui.Image>? blurMaskFuture = !blurMaskActive
        ? null
        : blur.source == SubjectSource.manual
        ? MaskManager.maskImage(blur.strokes)
        : () {
            final Float32List? mask = BlurCache.get(bytes);
            if (mask == null) return null;
            return MaskManager.floatMaskImage(mask, kSubjectMaskSize);
          }();
    // Once the user has cropped, every other tool composes the RESULT:
    // the fit follows the visible crop aspect, not the original frame.
    // Keeping the old source aspect here would letterbox a square crop
    // inside the full landscape box and make the crop look undone.
    final double resultAspect = cropSpec.isDefault
        ? widget.aspectRatio
        : cropSpec.resultAspect(cropSource);
    Widget shaderPhoto(ui.Image? blurMaskImage) => ShaderPreview(
      key: _photoKey,
      imageBytes: bytes,
      fallbackBytes: widget.transitionBytes,
      params: params,
      brushStrokes: selective.strokes,
      blurMaskImage: blurMaskImage,
    );

    /// The capture boundary sits AROUND the crop viewport, so the return
    /// flight carries the cropped grade. Overlays are a separate
    /// [CropViewport] sibling and never enter the snapshot. [spec] is the
    /// interpolated geometry while the crop morph is running.
    Widget photoWithMask(ui.Image? blurMaskImage, CropSpec spec) =>
        RepaintBoundary(
          key: widget.captureKey,
          child: CropViewport(
            spec: spec,
            photoAspect: widget.aspectRatio,
            child: shaderPhoto(blurMaskImage),
          ),
        );

    Widget buildPhoto(CropSpec spec) {
      if (blurMaskFuture == null) {
        Widget photo = photoWithMask(null, spec);
        if (widget.photoId != null && widget.transitionBytes != null) {
          photo = PhotoHero(
            id: widget.photoId!,
            bytes: widget.transitionBytes!,
            child: photo,
          );
        }
        return photo;
      }
      return FutureBuilder<ui.Image>(
        future: blurMaskFuture,
        builder: (context, snapshot) {
          Widget photo = photoWithMask(snapshot.data, spec);
          if (widget.photoId != null && widget.transitionBytes != null) {
            photo = PhotoHero(
              id: widget.photoId!,
              bytes: widget.transitionBytes!,
              child: photo,
            );
          }
          return photo;
        },
      );
    }

    // Crop takes over the preview wholesale: it needs the WHOLE photo
    // visible (cover-fit would hide exactly the pixels being cut), and it
    // owns its own gestures, so none of the cover/inspect/overlay stack
    // below applies. No capture boundary either — the hero that flies
    // back to the library is the uncropped photo, not this framing.
    //
    // The switch is choreographed as a morph of the SAME normal composition:
    // its aspect, insets and crop rectangle interpolate from the settled
    // result view to the full rotated frame in the crop area. When the morph
    // lands, the geometry already equals [CropStage]'s, so swapping in the
    // stage (with [_photoKey] carrying the shader state across) is invisible.
    final bool cropTool = tool == EditorTool.crop;
    if (cropTool && !_morphing) {
      return Padding(
        // The stage keeps clear of the chrome and leaves a margin beside
        // the screen, so every corner of the crop window can be grabbed.
        padding: widget.cropInsets,
        child: CropStage(
          spec: cropSpec,
          photoAspect: widget.aspectRatio,
          // Deliberately NOT `photoWithMask`: the capture boundary feeds the
          // return-flight snapshot, and inside the crop stage it would
          // capture a rotated, clipped frame and fly that back as the
          // library thumbnail. With no boundary, the hero falls back to the
          // uncropped transition raster.
          photo: shaderPhoto(null),
          onRectChanged: (rect) => notifier.setCropRect(rect, cropSource),
        ),
      );
    }

    // Ease the raw controller exactly like the sheet height: the photo grows
    // into the crop area in step with the chrome shrinking around it.
    final double eased = Curves.easeOutCubic.transform(
      _cropMorph.value.clamp(0.0, 1.0),
    );
    final bool morphing = _morphing;
    final double morph = morphing ? (_morphToCrop ? eased : 1 - eased) : 0;
    final CropSpec effectiveSpec = morphing
        ? cropSpec.copyWith(
            rect: Rect.lerp(cropSpec.rect, CropSpec.kFullRect, morph)!,
          )
        : cropSpec;
    // Derive the aspect from the interpolated window instead of lerping it
    // independently: the photo then fills the resting rect exactly on every
    // frame (no letterbox band between the old and new aspect).
    final double effectiveAspect = morphing
        ? effectiveSpec.resultAspect(cropSource)
        : resultAspect;
    final EdgeInsets effectiveInsets = morphing
        ? EdgeInsets.lerp(widget.visibleInsets, widget.cropInsets, morph)!
        : widget.visibleInsets;
    // Overlays belong to their tool, not to the crop morph: hide them while
    // the photo travels so the hand-off stays a pure photo move.
    final bool showOverlays = overlayVisible && !morphing;

    final Widget photo = buildPhoto(effectiveSpec);
    final interactive = overlayVisible
        ? Semantics(
            label: selectiveOverlayVisible
                ? 'Photo preview. Selective mask editor active.'
                : blurOverlayVisible
                ? 'Photo preview. Blur mask editor active.'
                : 'Photo preview. Sun position editor active.',
            child: photo,
          )
        : Semantics(
            label: 'Photo preview',
            button: true,
            onLongPress: () => notifier.setShowOriginal(!showOriginal),
            child: Listener(
              onPointerDown: (_) {
                _pointerCount++;
                if (_pointerCount == 1) {
                  _compareTimer?.cancel();
                  _compareTimer = Timer(const Duration(milliseconds: 90), () {
                    if (_pointerCount == 1) {
                      notifier.setShowOriginal(true);
                    }
                  });
                } else {
                  _compareTimer?.cancel();
                  notifier.setShowOriginal(false);
                }
              },
              onPointerUp: (_) {
                _compareTimer?.cancel();
                if (_pointerCount > 0) _pointerCount--;
                if (_pointerCount == 0) {
                  notifier.setShowOriginal(false);
                }
              },
              onPointerCancel: (_) {
                _compareTimer?.cancel();
                if (_pointerCount > 0) _pointerCount--;
                if (_pointerCount == 0) {
                  notifier.setShowOriginal(false);
                }
              },
              child: photo,
            ),
          );
    Widget viewport = PhotoViewport(
      aspectRatio: effectiveAspect,
      visibleInsets: effectiveInsets,
      child: Stack(
        fit: StackFit.expand,
        children: [
          interactive,
          if (showOverlays)
            CropViewport(
              spec: cropSpec,
              photoAspect: widget.aspectRatio,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (selectiveOverlayVisible)
                    Positioned.fill(
                      child: SelectiveOverlay(aspect: widget.aspectRatio),
                    ),
                  if (blurOverlayVisible)
                    const Positioned.fill(child: BlurOverlay()),
                  if (raysOverlayVisible)
                    const Positioned.fill(child: RaysOverlay()),
                ],
              ),
            ),
        ],
      ),
    );
    // The travelling photo is not interactive: a stray drag during the
    // 220ms hand-off would knock the rest rect off the morph endpoints.
    if (morphing) viewport = IgnorePointer(child: viewport);
    return Stack(
      fit: StackFit.expand,
      children: [
        // The photo and overlays are two CropViewport siblings:
        // identical geometry, but only the photo one is inside the
        // capture boundary/hero, so mask handles never fly back to
        // the library. Overlays still share the SOURCE uv box; the
        // viewport transform maps gestures back into it.
        viewport,
        if (showOriginal)
          Positioned(
            top:
                EditorPanelMetrics.topBarInset(
                  MediaQuery.paddingOf(context).top,
                ) +
                10,
            left: 8,
            child: IgnorePointer(
              child: AppBadge(
                child: Text('Original', style: AppTextStyles.small(context)),
              ),
            ),
          ),
      ],
    );
  }
}
