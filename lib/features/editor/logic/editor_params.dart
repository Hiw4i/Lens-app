import 'dart:typed_data';

import 'package:lens/features/adjust/cards/enhance/enhance_analysis.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_cache.dart';
import 'package:lens/features/blur/subject_mask.dart' show SubjectSource;
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/selective/selective_mask.dart' show SelectiveMode;

/// Bridges the editor Adjust state to the imaging bus.
///
/// Unit mapping ([AdjustParams] UI units -> [LensParams] shader units):
/// exposure stops pass through directly; contrast/saturation/temp/tint/
/// shadows/highlights are /100; structure is /100 into slot 8 (-1..1);
/// intensity is pinned to 1.0 (no master-mix UI yet); filterId passes the
/// `LensFilterId.index` through (texture selector, no uniform slot);
/// filterStrength is /100 into slot 11 (0..1). The Task 2.4 filter UI
/// drives filterId/filterStrength live; the Task 2.5 CPU export path
/// (`applyLensGrade`) consumes both — filterId as a separate int arg
/// (categorical, selects the LUT table generated in-isolate), strength
/// from the 10th uniforms slot.
///
/// Enhance (Task 3.3): enhance uniforms come from the cached analysis —
/// `EnhanceCache.getOrNone(previewBytes)` read synchronously. When
/// `previewBytes` is null (no photo) or the prewarm isolate has not
/// finished yet, the read degrades to [EnhanceAnalysis.none] and slots
/// 12..20 stay neutral; the UI then shows strength-driven mixing against
/// neutral gains (a no-op) until `prewarm onReady` fires
/// `EditorStateNotifier.bumpEnhanceVersion`, which re-emits state so
/// `select((s) => s.toLensParams())` re-reads the now-hot cache and the
/// preview/export pick up the real uniforms. `enhanceStrength` is
/// `EditorState.enhanceStrength / 100` into slot 20 (0 = stage skipped
/// everywhere: shader mixes are no-ops, the CPU path early-outs). The
/// derived auto-grade travels in the tail slots 49..56: auto-exposure
/// gain, S-curve contrast, shadow lift, vibrance, saturation, split tone
/// and the highlight shoulder.
///
/// Selective (Task 4.4): mapped from [SelectiveState] —
/// `selMode = active ? mode.index + 1 : 0` (0 = off matches the shader
/// slot), with two extra off-fallbacks: `strength <= 0` (stage skipped
/// everywhere anyway) and brush mode with no painted strokes (Task 4.3
/// concern #2: empty brush must grade nothing — the CPU treats a missing
/// raster as neutral, so emitting mode 0 keeps every consumer consistent).
/// Geometry/strength/local-grade mirror the state 1:1 (`strength/100` into
/// slot 30, `selCon/selSat/100` into slots 32..33 — same scale as the
/// global grade, `selExp` stops as-is into slot 31, `invert ? 1 : 0` into
/// slot 29). The stored `geometry.aspect` travels into slot 28 as a
/// fallback only: the preview painter overwrites slot 28 with the paint
/// size aspect every frame and the CPU export recomputes it from the frame
/// `w/h` (see the [SelectiveState] aspect contract). Brush strokes do NOT
/// travel here — see `SelectiveBrushExport.encodeSelectiveBrush`.
///
/// Blur (Task 6.4): mapped from [BlurState] —
/// `blurMode = off ? 0 : source == auto ? 1 : 2` (0 = off matches the
/// shader slot), with two off-fallbacks: `strength <= 0` (stage skipped
/// everywhere anyway) and manual source with no painted stroke (Task 6.3
/// concern #2: empty manual must grade nothing — the CPU treats a missing
/// mask as neutral, so emitting mode 0 keeps every consumer consistent).
/// `blurRadius` is UI 0..100 -> /100*0.05 fraction into slot 35 (default 40
/// -> 0.02, matches `LensParams` default); `blurFeather` is UI 0..100 ->
/// /100 into slot 36; `blurStrength` is /100 into slot 37 (0 when off);
/// `blurInvert` is `invert ? 1 : 0` into slot 38 (parked while off, like
/// selective invert — the stage skip makes it neutral anyway). The mask
/// itself NEVER travels here — see `EditorState.resolveBlurMask256` (export)
/// and the `_PreviewArea` resolver (preview via `MaskManager`).
///
/// Rays (Task 7.4): mapped from [RaysState] — `rayOn = intensity > 0 ? 1
/// : 0` (0 = off matches the shader slot: the stage exits before any tap
/// and the CPU export ignores the block); `rayX/rayY` carry the sun as-is
/// (off-frame passes through, same convention as the slots); `rayIntensity`
/// `/rayLength`/`rayWarmth`/`rayDensity` are UI 0..100 -> /100 into slots
/// 42..45 (parked while off — the gate makes them neutral anyway).
extension EditorStateToLensParams on EditorState {
  LensParams toLensParams() {
    final Uint8List? bytes = previewBytes;
    final EnhanceAnalysis analysis = bytes == null
        ? EnhanceAnalysis.none
        : EnhanceCache.getOrNone(bytes);
    final SelectiveState sel = selective;
    final bool hasBrushStrokes = sel.strokes.any((s) => s.points.isNotEmpty);
    final int selMode =
        (!sel.active ||
            sel.strength <= 0 ||
            (sel.mode == SelectiveMode.brush && !hasBrushStrokes))
        ? 0
        : sel.mode.index + 1;
    final BlurState b = blur;
    final bool hasBlurPaint = b.strokes.any((s) => s.points.isNotEmpty);
    final int blurMode =
        (b.strength <= 0 || (b.source == SubjectSource.manual && !hasBlurPaint))
        ? 0
        : b.source == SubjectSource.auto
        ? 1
        : 2;
    final RaysState r = rays;
    return LensParams(
      exposure: adjust.exposure,
      contrast: adjust.contrast / 100,
      saturation: adjust.saturation / 100,
      temp: adjust.temp / 100,
      tint: adjust.tint / 100,
      shadows: adjust.shadows / 100,
      highlights: adjust.highlights / 100,
      structure: adjust.structure,
      intensity: 1.0,
      filterId: filterId.index,
      filterStrength: filterStrength / 100,
      enhR: analysis.wbGainR,
      enhB: analysis.wbGainB,
      enhBlack: analysis.blackPt,
      enhWhite: analysis.whitePt,
      enhDehaze: analysis.dehaze,
      enhHazeR: analysis.hazeColor.$1,
      enhHazeG: analysis.hazeColor.$2,
      enhHazeB: analysis.hazeColor.$3,
      enhanceStrength: (enhanceStrength / 100).clamp(0.0, 1.0).toDouble(),
      // The professional auto-grade tail: every one of these is derived
      // from the photo by `analyzeEnhance` (auto-exposure, S-curve
      // contrast, shadow lift, vibrance, saturation, split tone and the
      // highlight shoulder). Neutral values keep the stage a no-op.
      enhExposure: analysis.exposureGain,
      enhContrast: analysis.contrast,
      enhShadowLift: analysis.shadowLift,
      enhVibrance: analysis.vibrance,
      enhSaturation: analysis.saturation,
      enhToneShadow: analysis.toneShadow,
      enhToneHighlight: analysis.toneHighlight,
      enhHighlightRecover: analysis.highlightRecover,
      enhLook: analysis.look,
      selMode: selMode,
      selCx: sel.geometry.center.$1,
      selCy: sel.geometry.center.$2,
      selRadius: sel.geometry.radius,
      selFeather: sel.geometry.feather,
      selAngle: sel.geometry.angle,
      selWidth: sel.geometry.width,
      selAspect: sel.geometry.aspect,
      selInvert: sel.geometry.invert ? 1 : 0,
      // Off-fallback (any of the three above) emits a fully neutral block:
      // strength 0 with mode 0, so identity-like params skip the stage
      // everywhere by construction (same as LensParams.identity).
      selStrength: selMode == 0
          ? 0.0
          : (sel.strength / 100).clamp(0.0, 1.0).toDouble(),
      selExp: sel.selExp,
      selCon: sel.selCon / 100,
      selSat: sel.selSat / 100,
      blurMode: blurMode,
      blurRadius: (b.radius / 100 * 0.05).clamp(0.0, 0.05),
      blurFeather: (b.feather / 100).clamp(0.0, 1.0),
      // Off-fallback (either of the two above) emits a fully neutral block:
      // strength 0 with mode 0, so identity-like params skip the stage
      // everywhere by construction (same as LensParams.identity).
      blurStrength: blurMode == 0
          ? 0.0
          : (b.strength / 100).clamp(0.0, 1.0).toDouble(),
      blurInvert: b.invert ? 1 : 0,
      // Off-fallback (intensity <= 0) emits a fully neutral block: gate 0
      // with intensity 0, so identity-like params skip the stage
      // everywhere by construction (same as LensParams.identity). The sun
      // travels as-is (off-frame passes through, like the slots).
      rayOn: r.intensity > 0 ? 1 : 0,
      rayX: r.source.$1,
      rayY: r.source.$2,
      rayIntensity: r.intensity > 0
          ? (r.intensity / 100).clamp(0.0, 1.0).toDouble()
          : 0.0,
      rayLength: (r.length / 100).clamp(0.0, 1.0).toDouble(),
      rayWarmth: (r.warmth / 100).clamp(0.0, 1.0).toDouble(),
      rayDensity: (r.density / 100).clamp(0.0, 1.0).toDouble(),
      rayMode: r.mode,
      rayAngle: r.angle,
      rayWidth: (r.width / 100).clamp(0.0, 1.0).toDouble(),
    );
  }
}
