/// The editor's aggregate state and the command hub that mutates it.
///
/// The editor OWNS the editing session (which tool is active, the undo
/// history, the preview bytes), but it does NOT own the tools' data: every
/// tool keeps its own state in its own feature folder —
/// `features/adjust/adjust_state.dart`, `features/blur/blur_state.dart`,
/// `features/rays/rays_state.dart`, `features/selective/selective_state.dart`
/// — and the editor aggregates them. The same split applies to the bridges:
/// the editor -> pipeline mapping lives in `editor_params.dart`, the crop
/// geometry in `features/crop/crop_export.dart` and the selective brush in
/// `features/selective/selective_export.dart`.
library;

import 'dart:typed_data';
import 'dart:ui' show Rect, Size;

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/adjust/adjust_state.dart' show AdjustParams;
import 'package:lens/features/blur/blur_cache.dart';
import 'package:lens/features/blur/blur_state.dart' show BlurState;
import 'package:lens/features/blur/subject_mask.dart'
    show SubjectSource, kSubjectMaskSize;
import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/editor/logic/editor_snapshot.dart'
    show GradeSnapshot;
import 'package:lens/features/editor/logic/editor_tool.dart'
    show
        EditorTool,
        kBlurOneTapStrength,
        kEnhanceOneTapStrength,
        kHistoryLimit,
        kRaysOneTapStrength;
import 'package:lens/features/filters/lut_definition.dart' show LensFilterId;
import 'package:lens/features/rays/rays_state.dart' show RaysState;
import 'package:lens/features/selective/mask_raster.dart';
import 'package:lens/features/selective/selective_mask.dart'
    show SelectiveGeometry, SelectiveMode;
import 'package:lens/features/selective/selective_state.dart'
    show SelectiveState;

// The editor is the aggregate of the tool features, so its state barrel
// re-exports the per-feature state types. Consumers that only need one
// of them may import the feature file directly.
export 'package:lens/features/adjust/adjust_state.dart' show AdjustParams;
export 'package:lens/features/blur/blur_state.dart' show BlurState;
// The export bridges belong to their tool features (the crop geometry and
// the selective brush); they are re-exported here because that is where
// callers expect them.
export 'package:lens/features/crop/crop_export.dart' show CropExport;
// The editor -> pipeline bridge (the EditorState -> LensParams mapping)
// lives in its own file so the imaging pipeline does not have to know the
// editor. It is re-exported here because that is where callers expect it.
export 'package:lens/features/editor/logic/editor_params.dart';
export 'package:lens/features/editor/logic/editor_snapshot.dart'
    show GradeSnapshot;
export 'package:lens/features/editor/logic/editor_tool.dart'
    show
        EditorTool,
        kBlurOneTapStrength,
        kEnhanceOneTapStrength,
        kHistoryLimit,
        kRaysOneTapStrength;
export 'package:lens/features/rays/rays_state.dart' show RaysState;
export 'package:lens/features/selective/selective_export.dart'
    show SelectiveBrushExport;
export 'package:lens/features/selective/selective_state.dart'
    show SelectiveState;

/// Immutable editor state: preview bytes + active tool + Adjust grade +
/// LUT filter selection (Task 2.3).
///
/// [undoDepth]/[redoDepth] mirror the history stack sizes so the UI can
/// subscribe with `ref.watch(editorStateProvider.select((s) => s.undoDepth))`
/// and rebuild undo/redo affordances without replaying the whole screen on
/// every slider tick. They are updated atomically with the grade in a
/// single state emission per mutation (no double-notify).
class EditorState {
  const EditorState({
    this.previewBytes,
    this.tool = EditorTool.adjust,
    this.adjust = const AdjustParams(),
    this.filterId = LensFilterId.none,
    this.filterStrength = 100,
    this.enhanceStrength = 0,
    this.enhanceAnalysisVersion = 0,
    this.selective = const SelectiveState(),
    this.blur = const BlurState(),
    this.rays = const RaysState(),
    this.crop = const CropSpec(),
    this.photoAspect = 1,
    this.blurAnalysisVersion = 0,
    this.showOriginal = false,
    this.undoDepth = 0,
    this.redoDepth = 0,
  });

  final Uint8List? previewBytes;
  final EditorTool tool;
  final AdjustParams adjust;

  /// Active LUT look (`LensFilterId.none` = identity atlas, no-op).
  /// A filter is NOT part of [AdjustParams]: adjust is a continuous grade,
  /// the filter is a categorical look with its own strength.
  final LensFilterId filterId;

  /// LUT mix amount, 0..100 UI units (-> /100 into shader slot 11).
  final double filterStrength;

  /// 1-tap Enhance mix amount, 0..100 UI units (-> /100 into slot 20).
  /// 0 = stage skipped (shader no-op, CPU early-out).
  final double enhanceStrength;

  /// Cache-generation nonce for the async Enhance analysis. Bumped via
  /// [EditorStateNotifier.bumpEnhanceVersion] when `EnhanceCache.prewarm`
  /// completes, so `select((s) => s.toLensParams())` re-evaluates the
  /// (cache-backed) enhance uniforms. Not part of the undoable grade:
  /// ignored by [isDefault], history, undo/redo and `reset`.
  final int enhanceAnalysisVersion;

  /// Selective local grade (Task 4.4). Default = off ([SelectiveState.isDefault]).
  final SelectiveState selective;

  /// Background blur grade (Task 6.4). Default = off ([BlurState.isDefault]).
  final BlurState blur;

  /// Tyndall-rays grade (Task 7.4). Default = off ([RaysState.isDefault]).
  final RaysState rays;

  /// Crop + straighten geometry. Default = untouched ([CropSpec.isDefault]).
  ///
  /// Unlike every other block this is pure GEOMETRY, not a grade: it does not
  /// reach [LensParams] and never runs in the shader. The preview applies it
  /// as a widget transform and the exporter as a resample, both driven by
  /// this one spec (see `features/crop/crop_spec.dart`).
  final CropSpec crop;

  /// width / height of the source photo.
  ///
  /// LAYOUT, not grade: excluded from [isDefault] and from the history
  /// snapshot, same rule as `SelectiveGeometry.aspect`. The crop panel and
  /// crop stage both need it to turn normalized geometry into pixels, and it
  /// is supplied by the library, which has already decoded the photo by the
  /// time the editor opens.
  final double photoAspect;

  /// Cache-generation nonce for the async ML subject-mask analysis. Bumped
  /// via [EditorStateNotifier.bumpBlurVersion] when `BlurCache.prewarm`
  /// settles (mask or null), so `select((s) => s.toLensParams())` and the
  /// preview mask resolver re-read the now-settled cache. Not part of the
  /// undoable grade: ignored by [isDefault], history, undo/redo and `reset`.
  final int blurAnalysisVersion;

  /// Preview mask cache key (Task 6.4 resolve path): the async ML nonce.
  /// Manual strokes are covered by [blur] equality itself (a dab changes
  /// [BlurState], so `select((s) => s.blur)` rebuilds); this nonce covers
  /// the async auto path, where `BlurCache.get` flips from null to mask
  /// without any grade edit. `_PreviewArea` watches both.
  int get blurMaskKey => blurAnalysisVersion;

  final bool showOriginal;

  /// Number of undoable steps; > 0 means "Undo" is enabled.
  final int undoDepth;

  /// Number of redoable steps; > 0 means "Redo" is enabled.
  final int redoDepth;

  /// True when grade, filter, enhance, selective, blur, rays AND crop are at
  /// defaults. [enhanceAnalysisVersion]/[blurAnalysisVersion] are intentionally
  /// excluded: cache nonces, not user-visible grades.
  bool get isDefault =>
      adjust.isDefault &&
      filterId == LensFilterId.none &&
      filterStrength == 100 &&
      enhanceStrength == 0 &&
      selective.isDefault &&
      blur.isDefault &&
      rays.isDefault &&
      crop.isDefault;

  /// Resolves the READY 256x256 subject mask for export (Task 6.4).
  ///
  /// * strength <= 0 => null (off stays neutral everywhere);
  /// * manual source with no painted stroke => null (empty manual grades
  ///   nothing — same off-fallback as `toLensParams`);
  /// * auto source => `BlurCache.get(previewBytes)` (null on miss/failure —
  ///   the caller then stays neutral; desktop/ML-fail degrades to manual
  ///   in the UI, never to a full-frame blur);
  /// * manual source with paint => synchronous 256x256 raster via
  ///   [rasterizeBrushMask] (65k floats, a few ms on the UI thread —
  ///   acceptable for a one-shot export resolve; the preview instead reuses
  ///   the cached 128 async raster via `MaskManager.maskImage`).
  /// Null [previewBytes] (no photo) => null.
  Float32List? resolveBlurMask256() {
    if (blur.strength <= 0) return null;
    final bool hasPaint = blur.strokes.any((s) => s.points.isNotEmpty);
    if (blur.source == SubjectSource.manual) {
      if (!hasPaint) return null;
      return rasterizeBrushMask(blur.strokes, kSubjectMaskSize);
    }
    final Uint8List? bytes = previewBytes;
    if (bytes == null) return null;
    return BlurCache.get(bytes);
  }

  EditorState copyWith({
    Uint8List? previewBytes,
    EditorTool? tool,
    AdjustParams? adjust,
    LensFilterId? filterId,
    double? filterStrength,
    double? enhanceStrength,
    int? enhanceAnalysisVersion,
    SelectiveState? selective,
    BlurState? blur,
    RaysState? rays,
    CropSpec? crop,
    double? photoAspect,
    int? blurAnalysisVersion,
    bool? showOriginal,
    int? undoDepth,
    int? redoDepth,
    bool clearPreview = false,
  }) {
    return EditorState(
      previewBytes: clearPreview ? null : (previewBytes ?? this.previewBytes),
      tool: tool ?? this.tool,
      adjust: adjust ?? this.adjust,
      filterId: filterId ?? this.filterId,
      filterStrength: filterStrength ?? this.filterStrength,
      enhanceStrength: enhanceStrength ?? this.enhanceStrength,
      enhanceAnalysisVersion:
          enhanceAnalysisVersion ?? this.enhanceAnalysisVersion,
      selective: selective ?? this.selective,
      blur: blur ?? this.blur,
      rays: rays ?? this.rays,
      crop: crop ?? this.crop,
      photoAspect: photoAspect ?? this.photoAspect,
      blurAnalysisVersion: blurAnalysisVersion ?? this.blurAnalysisVersion,
      showOriginal: showOriginal ?? this.showOriginal,
      undoDepth: undoDepth ?? this.undoDepth,
      redoDepth: redoDepth ?? this.redoDepth,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditorState &&
          identical(other.previewBytes, previewBytes) &&
          other.tool == tool &&
          other.adjust == adjust &&
          other.filterId == filterId &&
          other.filterStrength == filterStrength &&
          other.enhanceStrength == enhanceStrength &&
          other.enhanceAnalysisVersion == enhanceAnalysisVersion &&
          other.selective == selective &&
          other.blur == blur &&
          other.rays == rays &&
          other.crop == crop &&
          other.photoAspect == photoAspect &&
          other.blurAnalysisVersion == blurAnalysisVersion &&
          other.showOriginal == showOriginal &&
          other.undoDepth == undoDepth &&
          other.redoDepth == redoDepth;

  @override
  int get hashCode => Object.hash(
    identityHashCode(previewBytes),
    tool,
    adjust,
    filterId,
    filterStrength,
    enhanceStrength,
    enhanceAnalysisVersion,
    selective,
    blur,
    rays,
    crop,
    photoAspect,
    blurAnalysisVersion,
    showOriginal,
    undoDepth,
    redoDepth,
  );
}

final editorStateProvider = NotifierProvider<EditorStateNotifier, EditorState>(
  EditorStateNotifier.new,
);

class EditorStateNotifier extends Notifier<EditorState> {
  @override
  EditorState build() => const EditorState();

  /// History entries snapshot the undoable grade: adjust + filter +
  /// enhance + selective + blur + rays. Records have value equality, so
  /// stroke-commit comparisons (`start == current`) stay exact. The PUBLIC
  /// depth contract is unchanged: [EditorState.undoDepth]/[redoDepth] still
  /// mirror these stacks, existing `select` subscriptions keep working.
  /// The stroke bracket ([beginStroke]/[endStroke]) is shared across
  /// adjust, filter-strength, enhance-strength, selective, blur and rays: one
  /// open stroke at a time, the outermost wins, committed once in
  /// [endStroke]. Brush dabs additionally set [_brushInProgress] so
  /// [addBrushPoint]/[addBlurBrushPoint] know whether to extend the current
  /// dab or start a new stroke.
  final List<GradeSnapshot> _undo = [];
  final List<GradeSnapshot> _redo = [];

  /// Stroke start snapshot. Non-null between [beginStroke] and [endStroke];
  /// while set, per-tick setters update the state without touching history.
  ///
  /// History-depth contract: [undoDepth]/[redoDepth] in the state change
  /// only when the history stacks change — a drag updates them once, in the
  /// [endStroke] commit (not on every tick), so `select`-based undo buttons
  /// stay quiet while the slider moves.
  GradeSnapshot? _strokeStart;

  /// True between the first [addBrushPoint] of a dab and [endStroke].
  /// Distinguishes "extend the in-progress dab" from "start a new stroke"
  /// when the shared bracket is already open.
  bool _brushInProgress = false;

  bool get canUndo => _undo.isNotEmpty;
  bool get canRedo => _redo.isNotEmpty;

  void setPreviewBytes(Uint8List? bytes) {
    if (identical(bytes, state.previewBytes)) return;
    _undo.clear();
    _redo.clear();
    _strokeStart = null;
    _brushInProgress = false;
    // The aspect is layout and survives a photo swap only when the caller
    // re-supplies it; keep the old one so a transient null never renders the
    // crop stage at a 1:1 assumption.
    state = EditorState(previewBytes: bytes, photoAspect: state.photoAspect);
  }

  /// Records the source photo's aspect (width / height). Layout only — see
  /// [EditorState.photoAspect]. Never pushes history.
  void setPhotoAspect(double aspect) {
    if (!aspect.isFinite || aspect <= 0 || aspect == state.photoAspect) {
      return;
    }
    state = state.copyWith(photoAspect: aspect);
  }

  /// Switching tools also manages the crop session: entering Crop opens the
  /// one-entry undo bracket, leaving it commits. Doing it here rather than in
  /// the UI means every entry point (rail tap, keyboard, undo, reset) keeps
  /// the history honest.
  void setTool(EditorTool tool) {
    if (state.tool == tool) return;
    if (state.tool == EditorTool.crop) endCrop();
    if (tool == EditorTool.crop) beginCrop();
    state = state.copyWith(tool: tool);
  }

  // --- Crop / straighten ------------------------------------------------
  //
  // The whole visit to the Crop tool is ONE undo entry: [beginCrop] opens
  // the shared stroke bracket on entry and [endCrop] commits it on exit, so
  // dragging the frame, twisting the photo and nudging the angle all collapse
  // into a single history step. `endStroke` compares the grade, so a visit
  // that changed nothing commits nothing.

  /// Opens the crop bracket. Call when the Crop tool becomes active.
  void beginCrop() => beginStroke();

  /// Commits the crop bracket. Call when leaving the Crop tool.
  void endCrop() => endStroke();

  /// Sets the straightening angle (degrees, clamped) and re-fits the window
  /// so it never drifts into the transparent corners the rotation creates.
  ///
  /// The window keeps its pixel size and centre: normalizing it afresh
  /// against the grown frame would silently zoom a window the user had
  /// deliberately shrunk.
  void setCropAngle(double degrees, Size source) {
    if (!degrees.isFinite) return;
    final CropSpec previous = state.crop;
    final CropSpec next = previous
        .copyWith(
          angleDegrees: degrees
              .clamp(-CropSpec.kMaxAngleDegrees, CropSpec.kMaxAngleDegrees)
              .toDouble(),
        )
        .refittedFrom(previous, source);
    _commitGrade((s) => s.copyWith(crop: next));
  }

  /// Replaces the crop window (normalized 0..1 against the rotated frame).
  ///
  /// This is a direct window edit, not a ratio selection: it preserves the
  /// candidate's size and position and only clamps it into the safe area.
  void setCropRect(Rect rect, Size source) {
    if (!rect.isFinite || rect.width <= 0 || rect.height <= 0) return;
    _commitGrade(
      (s) => s.copyWith(crop: s.crop.copyWith(rect: rect).refitted(source)),
    );
  }

  /// Locks the window to [ratio] (null = free), snapping to the largest
  /// matching shape in the current frame.
  void setCropRatio(double? ratio, Size source) {
    _commitGrade((s) => s.copyWith(crop: s.crop.withRatio(ratio, source)));
  }

  /// Rotates a quarter turn clockwise.
  void rotateCropQuarter(Size source) {
    final CropSpec previous = state.crop;
    final CropSpec next = previous
        .copyWith(quarterTurns: (previous.quarterTurns + 1) % 4)
        .refittedFrom(previous, source);
    _commitGrade((s) => s.copyWith(crop: next));
  }

  /// Drops all crop geometry (angle, rotation, window, aspect lock).
  void clearCrop() => _commitGrade((s) => s.copyWith(crop: const CropSpec()));

  void setShowOriginal(bool value) {
    if (state.showOriginal != value) {
      state = state.copyWith(showOriginal: value);
    }
  }

  /// Marks the start of a slider drag. The UI must call this once (e.g. in
  /// `onChangeStart`) before the first tick, and [endStroke] once (e.g. in
  /// `onChangeEnd`) after the last tick; the whole drag then costs exactly
  /// one undo entry. Nested calls are ignored — the outermost stroke wins.
  void beginStroke() {
    _strokeStart ??= _snapshot();
  }

  /// Commits the in-progress stroke (see below): pushes the pre-drag
  /// snapshot to undo (and clears redo) only if the value actually moved.
  /// Safe to call without a matching [beginStroke] — it becomes a no-op.
  /// Also closes an in-progress brush dab ([_brushInProgress]).
  /// The stored preview aspect is ignored by the comparison (see
  /// [_sameGrade]): an aspect-only layout change inside an open stroke
  /// never commits a history entry.
  void endStroke() {
    final start = _strokeStart;
    _strokeStart = null;
    _brushInProgress = false;
    if (start == null || _sameGrade(start, _snapshot())) return;
    _pushHistory(start);
    state = state.copyWith(undoDepth: _undo.length, redoDepth: _redo.length);
  }

  void setAdjust(AdjustParams value) =>
      _commitGrade((s) => s.copyWith(adjust: value));

  void setExposure(double value) => _commitGrade(
    (s) => s.copyWith(adjust: s.adjust.copyWith(exposure: _clamp(value, -3, 3))),
  );

  void setStructure(double value) => _commitGrade(
    (s) =>
        s.copyWith(adjust: s.adjust.copyWith(structure: _clamp(value, -100, 100))),
  );

  void setContrast(double value) => _commitGrade(
    (s) =>
        s.copyWith(adjust: s.adjust.copyWith(contrast: _clamp(value, -100, 100))),
  );

  void setSaturation(double value) => _commitGrade(
    (s) => s.copyWith(
      adjust: s.adjust.copyWith(saturation: _clamp(value, -100, 100)),
    ),
  );

  void setTemp(double value) => _commitGrade(
    (s) => s.copyWith(adjust: s.adjust.copyWith(temp: _clamp(value, -100, 100))),
  );

  void setTint(double value) => _commitGrade(
    (s) => s.copyWith(adjust: s.adjust.copyWith(tint: _clamp(value, -100, 100))),
  );

  void setShadows(double value) => _commitGrade(
    (s) =>
        s.copyWith(adjust: s.adjust.copyWith(shadows: _clamp(value, -100, 100))),
  );

  void setHighlights(double value) => _commitGrade(
    (s) => s.copyWith(
      adjust: s.adjust.copyWith(highlights: _clamp(value, -100, 100)),
    ),
  );

  /// Selects the LUT look as ONE undoable step (no stroke bracketing —
  /// the Task 2.4 preset UI calls this once per tap).
  /// A mid-drag filter change first commits the in-progress adjust stroke
  /// so the drag's history entry is not corrupted, then pushes the filter
  /// change on top.
  void setFilterId(LensFilterId value) {
    if (value == state.filterId) return;
    if (_strokeStart != null) endStroke();
    _pushHistory(_snapshot());
    state = state.copyWith(
      filterId: value,
      filterStrength: 50,
      undoDepth: _undo.length,
      redoDepth: _redo.length,
    );
  }

  /// Sets the LUT mix amount (0..100 UI units) as one undoable step.
  /// Honors an open stroke so a strength drag bracketed with
  /// [beginStroke]/[endStroke] costs exactly one history entry — same as
  /// the adjust sliders.
  void setFilterStrength(double value) =>
      _commitGrade((s) => s.copyWith(filterStrength: _clamp(value, 0, 100)));

  /// Sets the Enhance mix amount (0..100 UI units) as one undoable step.
  /// Stroke-aware like [setFilterStrength]: inside a [beginStroke]/[endStroke]
  /// drag it live-updates without touching history; standalone it pushes
  /// exactly one entry. A mid-drag tool switch first commits the open
  /// stroke via [endStroke] (callers: one-tap/clear), so the drag entry
  /// is never corrupted.
  void setEnhanceStrength(double value) =>
      _commitGrade((s) => s.copyWith(enhanceStrength: _clamp(value, 0, 100)));

  /// TG-like 1-tap Enhance: jumps to [kEnhanceOneTapStrength] as exactly
  /// one undoable step. Re-tapping at the same strength is a no-op (no
  /// duplicate history entry). Commits an open slider stroke first.
  void applyEnhanceOneTap() {
    if (state.enhanceStrength == kEnhanceOneTapStrength) return;
    if (_strokeStart != null) endStroke();
    setEnhanceStrength(kEnhanceOneTapStrength);
  }

  /// Turns Enhance off (strength 0) as exactly one undoable step.
  /// Already-off is a no-op. Commits an open slider stroke first.
  void clearEnhance() {
    if (state.enhanceStrength == 0) return;
    if (_strokeStart != null) endStroke();
    setEnhanceStrength(0);
  }

  /// Cache-generation bump, NOT an undoable edit: history stacks and
  /// depths are untouched. Called (via `EnhanceCache.prewarm onReady`)
  /// when the async analysis for the current photo lands, so
  /// `select((s) => s.toLensParams())` re-reads the now-hot cache and
  /// the preview picks up the enhance uniforms.
  void bumpEnhanceVersion() {
    state = state.copyWith(
      enhanceAnalysisVersion: state.enhanceAnalysisVersion + 1,
    );
  }

  void undo() {
    if (_strokeStart != null) endStroke();
    if (_undo.isEmpty) return;
    _redo.add(_snapshot());
    final GradeSnapshot prev = _undo.removeLast();
    // The stored preview aspect is layout, not grade: undo restores the
    // grade snapshot but keeps the latest aspect (same rule as
    // [setSelectiveAspect] never pushing — aspect is not undoable).
    final double aspect = state.selective.geometry.aspect;
    state = state.copyWith(
      adjust: prev.adjust,
      filterId: prev.filterId,
      filterStrength: prev.filterStrength,
      enhanceStrength: prev.enhanceStrength,
      selective: prev.selective.copyWith(
        geometry: prev.selective.geometry.copyWith(aspect: aspect),
      ),
      blur: prev.blur,
      rays: prev.rays,
      crop: prev.crop,
      undoDepth: _undo.length,
      redoDepth: _redo.length,
    );
  }

  void redo() {
    if (_strokeStart != null) endStroke();
    if (_redo.isEmpty) return;
    _undo.add(_snapshot());
    if (_undo.length > kHistoryLimit) _undo.removeAt(0);
    final GradeSnapshot next = _redo.removeLast();
    // Same aspect rule as [undo]: the redo snapshot restores the grade,
    // the live preview aspect is preserved.
    final double aspect = state.selective.geometry.aspect;
    state = state.copyWith(
      adjust: next.adjust,
      filterId: next.filterId,
      filterStrength: next.filterStrength,
      enhanceStrength: next.enhanceStrength,
      selective: next.selective.copyWith(
        geometry: next.selective.geometry.copyWith(aspect: aspect),
      ),
      blur: next.blur,
      rays: next.rays,
      crop: next.crop,
      undoDepth: _undo.length,
      redoDepth: _redo.length,
    );
  }

  /// Resets grade + filter + enhance + selective + blur + rays + crop to
  /// defaults as one undoable step. [enhanceAnalysisVersion]/[blurAnalysisVersion]
  /// are preserved: the cached analyses stay hot. The live preview aspect
  /// and the source photo's aspect are layout, not grade, and survive.
  void reset() {
    if (_strokeStart != null) endStroke();
    if (state.isDefault) return;
    _pushHistory(_snapshot());
    // Selective's aspect tracks the preview box, not the source photo. They
    // happen to be equal today, but conflating them corrupted crop geometry:
    // reset used to overwrite `photoAspect` with the (usually 1:1) selective
    // aspect, so the next crop laid out against the wrong frame.
    final double selectiveAspect = state.selective.geometry.aspect;
    state = state.copyWith(
      adjust: const AdjustParams(),
      filterId: LensFilterId.none,
      filterStrength: 100,
      enhanceStrength: 0,
      selective: SelectiveState(
        geometry: SelectiveGeometry(aspect: selectiveAspect),
      ),
      blur: const BlurState(),
      rays: const RaysState(),
      crop: const CropSpec(),
      photoAspect: state.photoAspect,
      undoDepth: _undo.length,
      redoDepth: _redo.length,
    );
  }

  // -----------------------------------------------------------------
  // Selective (Task 4.4). All grade setters below are stroke-aware like
  // [setFilterStrength]: outside a [beginStroke]/[endStroke] bracket each
  // call pushes exactly one entry; inside, they live-update and [endStroke]
  // commits once. Discrete switches ([setSelectiveMode], [clearSelective])
  // first commit an open stroke so the drag entry is never corrupted.
  // -----------------------------------------------------------------

  /// Picks the mask shape AND turns selective on (explicit shape pick =
  /// intent to use it; the last pick is remembered while off).
  /// No-op when the shape is already active. Commits an open stroke first.
  void setSelectiveMode(SelectiveMode mode) {
    final SelectiveState sel = state.selective;
    if (sel.mode == mode && sel.active) return;
    if (_strokeStart != null) endStroke();
    _commitGrade((s) => s.copyWith(selective: sel.copyWith(mode: mode, active: true)));
  }

  /// Master on/off switch. Remembers [SelectiveMode] while off.
  /// No-op when unchanged. Commits an open stroke first.
  void setSelectiveActive(bool active) {
    if (state.selective.active == active) return;
    if (_strokeStart != null) endStroke();
    _commitGrade(
      (s) => s.copyWith(selective: s.selective.copyWith(active: active)),
    );
  }

  /// Replaces the radial/linear geometry wholesale (center, radius,
  /// feather, angle, width, invert — NOT aspect: the incoming aspect is
  /// forced to the live one so geometry drags never fork the layout value;
  /// use [setSelectiveAspect] for layout). Stroke-aware, one entry.
  void setSelectiveGeometry(SelectiveGeometry geometry) {
    _commitGrade(
      (s) => s.copyWith(
        selective: s.selective.copyWith(
          geometry: geometry.copyWith(aspect: s.selective.geometry.aspect),
        ),
      ),
    );
  }

  /// Mask center in normalized uv 0..1 (clamped). Stroke-aware.
  void setSelectiveCenter(double x, double y) {
    _commitGrade(
      (s) => s.copyWith(
        selective: s.selective.copyWith(
          geometry: s.selective.geometry.copyWith(
            center: (_clamp(x, 0, 1), _clamp(y, 0, 1)),
          ),
        ),
      ),
    );
  }

  /// Radial disc radius, uv 0..1 (clamped). Stroke-aware.
  void setSelectiveRadius(double value) {
    _commitGrade(
      (s) => s.copyWith(
        selective: s.selective.copyWith(
          geometry: s.selective.geometry.copyWith(radius: _clamp(value, 0, 1)),
        ),
      ),
    );
  }

  /// Edge softness 0..1 (clamped, 0 = hard step). Stroke-aware.
  void setSelectiveFeather(double value) {
    _commitGrade(
      (s) => s.copyWith(
        selective: s.selective.copyWith(
          geometry: s.selective.geometry.copyWith(
            feather: _clamp(value, 0, 1),
          ),
        ),
      ),
    );
  }

  /// Linear gradient direction, degrees 0..360 (clamped). Stroke-aware.
  void setSelectiveAngle(double value) {
    _commitGrade(
      (s) => s.copyWith(
        selective: s.selective.copyWith(
          geometry: s.selective.geometry.copyWith(
            angle: _clamp(value, 0, 360),
          ),
        ),
      ),
    );
  }

  /// Linear half-band width, uv 0..1 (clamped). Stroke-aware.
  void setSelectiveWidth(double value) {
    _commitGrade(
      (s) => s.copyWith(
        selective: s.selective.copyWith(
          geometry: s.selective.geometry.copyWith(width: _clamp(value, 0, 1)),
        ),
      ),
    );
  }

  /// Invert flag. Stroke-aware.
  void setSelectiveInvert(bool invert) {
    _commitGrade(
      (s) => s.copyWith(
        selective: s.selective.copyWith(
          geometry: s.selective.geometry.copyWith(invert: invert),
        ),
      ),
    );
  }

  /// Mask mix amount, 0..100 UI units (clamped). Stroke-aware.
  void setSelectiveStrength(double value) => _commitGrade(
    (s) => s.copyWith(selective: s.selective.copyWith(strength: _clamp(value, 0, 100))),
  );

  /// Local exposure inside the mask, stops -2..+2 (clamped). Stroke-aware.
  void setSelectiveExp(double value) => _commitGrade(
    (s) => s.copyWith(selective: s.selective.copyWith(selExp: _clamp(value, -2, 2))),
  );

  /// Local contrast inside the mask, -100..100 (clamped). Stroke-aware.
  void setSelectiveCon(double value) => _commitGrade(
    (s) => s.copyWith(
      selective: s.selective.copyWith(selCon: _clamp(value, -100, 100)),
    ),
  );

  /// Local saturation inside the mask, -100..100 (clamped). Stroke-aware.
  void setSelectiveSat(double value) => _commitGrade(
    (s) => s.copyWith(
      selective: s.selective.copyWith(selSat: _clamp(value, -100, 100)),
    ),
  );

  /// Default dab radius for NEW strokes, uv 0.01..0.5 (clamped).
  /// Stroke-aware (existing dabs keep their own radius).
  void setSelectiveBrushRadius(double value) => _commitGrade(
    (s) => s.copyWith(
      selective: s.selective.copyWith(brushRadius: _clamp(value, 0.01, 0.5)),
    ),
  );

  /// Default dab feather for NEW strokes, 0..1 (clamped). Stroke-aware.
  void setSelectiveBrushFeather(double value) => _commitGrade(
    (s) => s.copyWith(
      selective: s.selective.copyWith(brushFeather: _clamp(value, 0, 1)),
    ),
  );

  /// Preview width/height ratio for the radial ellipse. LAYOUT, not grade:
  /// never touches history (like [setTool]) — undo/redo/reset preserve the
  /// live value. Non-positive input is ignored ([SelectiveGeometry]
  /// requires aspect > 0). The value is only a stored fallback: the preview
  /// painter and the CPU export recompute the aspect per context (see the
  /// [SelectiveState] aspect contract).
  void setSelectiveAspect(double aspect) {
    if (aspect <= 0 || aspect == state.selective.geometry.aspect) return;
    state = state.copyWith(
      selective: state.selective.copyWith(
        geometry: state.selective.geometry.copyWith(aspect: aspect),
      ),
    );
  }

  /// Appends one brush dab point (normalized uv, clamped to 0..1).
  ///
  /// Live-only: NEVER touches history — the Task 4.5 UI brackets the pan
  /// (`beginStroke` on pan-start, [endStroke] on pan-end) so the whole drag
  /// costs exactly one entry. Opens the bracket implicitly when the UI
  /// forgot it. No-op unless selective is active AND mode is brush.
  /// First point of a dab starts a new [BrushStroke] (with the current
  /// [SelectiveState.brushRadius]/[brushFeather]); subsequent points extend
  /// it (immutable copy-on-write, structurally shared with the snapshot).
  void addBrushPoint(double x, double y) {
    final SelectiveState sel = state.selective;
    if (!sel.active || sel.mode != SelectiveMode.brush) return;
    _strokeStart ??= _snapshot();
    final (double, double) point = (_clamp(x, 0, 1), _clamp(y, 0, 1));
    state = state.copyWith(
      selective: sel.copyWith(
        strokes: _appendedStrokes(
          sel.strokes,
          point,
          extendLast: _brushInProgress,
          radius: sel.brushRadius,
          feather: sel.brushFeather,
        ),
      ),
    );
    _brushInProgress = true;
  }

  /// Turns selective off and restores every selective field to default as
  /// exactly one undoable step (preserves the live preview aspect — layout,
  /// not grade). No-op when already default. Commits an open stroke first.
  void clearSelective() {
    if (_strokeStart != null) endStroke();
    // "Already default" ignores the stored aspect (layout, preserved).
    final SelectiveState sel = state.selective;
    if (sel.copyWith(geometry: sel.geometry.copyWith(aspect: 1.0)) ==
        const SelectiveState()) {
      return;
    }
    _pushHistory(_snapshot());
    final double aspect = state.selective.geometry.aspect;
    state = state.copyWith(
      selective: SelectiveState(geometry: SelectiveGeometry(aspect: aspect)),
      undoDepth: _undo.length,
      redoDepth: _redo.length,
    );
  }

  // -----------------------------------------------------------------
  // Blur (Task 6.4). All grade setters below are stroke-aware like
  // [_applyFilter]: outside a [beginStroke]/[endStroke] bracket each call
  // pushes exactly one entry; inside, they live-update and [endStroke]
  // commits once. Discrete switches ([setBlurSource], [clearBlur],
  // [applyBlurOneTap]) first commit an open stroke so the drag entry is
  // never corrupted.
  // -----------------------------------------------------------------

  /// Picks the mask source (auto ML vs manual brush).
  /// Picking a source when strength is 0 also turns blur on at
  /// [kBlurOneTapStrength] in the SAME history entry (explicit source pick
  /// = intent to use it, same as [setSelectiveMode] turning selective on).
  /// No-op when the source is already picked and blur is already on.
  /// Commits an open stroke first.
  void setBlurSource(SubjectSource source) {
    final BlurState b = state.blur;
    if (b.source == source && b.strength > 0) return;
    if (_strokeStart != null) endStroke();
    final double strength = b.strength <= 0 ? kBlurOneTapStrength : b.strength;
    _commitGrade(
      (s) => s.copyWith(blur: s.blur.copyWith(source: source, strength: strength)),
    );
  }

  /// Blur mix amount, 0..100 UI units (clamped). Stroke-aware.
  void setBlurStrength(double value) => _commitGrade(
    (s) => s.copyWith(blur: s.blur.copyWith(strength: _clamp(value, 0, 100))),
  );

  /// Bokeh radius, 0..100 UI units (clamped). Stroke-aware.
  void setBlurRadius(double value) => _commitGrade(
    (s) => s.copyWith(blur: s.blur.copyWith(radius: _clamp(value, 0, 100))),
  );

  /// Mask edge softness, 0..100 UI units (clamped). Stroke-aware.
  void setBlurFeather(double value) => _commitGrade(
    (s) => s.copyWith(blur: s.blur.copyWith(feather: _clamp(value, 0, 100))),
  );

  /// Invert flag (blur the subject instead of the background). Stroke-aware.
  void setBlurInvert(bool invert) =>
      _commitGrade((s) => s.copyWith(blur: s.blur.copyWith(invert: invert)));

  /// Default dab radius for NEW manual strokes, uv 0.01..0.5 (clamped).
  /// Stroke-aware (existing dabs keep their own radius).
  void setBlurBrushRadius(double value) => _commitGrade(
    (s) =>
        s.copyWith(blur: s.blur.copyWith(brushRadius: _clamp(value, 0.01, 0.5))),
  );

  /// Default dab feather for NEW manual strokes, 0..1 (clamped).
  /// Stroke-aware.
  void setBlurBrushFeather(double value) => _commitGrade(
    (s) => s.copyWith(blur: s.blur.copyWith(brushFeather: _clamp(value, 0, 1))),
  );

  /// 1-tap Blur: jumps to [kBlurOneTapStrength] as exactly one undoable
  /// step (keeps the current source). Re-tapping at the same strength is a
  /// no-op. Commits an open slider stroke first.
  void applyBlurOneTap() {
    if (state.blur.strength == kBlurOneTapStrength) return;
    if (_strokeStart != null) endStroke();
    setBlurStrength(kBlurOneTapStrength);
  }

  /// Turns Blur off (strength 0) as exactly one undoable step, keeping the
  /// source/strokes parked for fast re-enable. Already-off is a no-op.
  /// Commits an open slider stroke first.
  void clearBlur() {
    if (state.blur.strength == 0) return;
    if (_strokeStart != null) endStroke();
    setBlurStrength(0);
  }

  /// Cache-generation bump, NOT an undoable edit: history stacks and
  /// depths are untouched. Called (via `BlurCache.prewarm onReady`) when
  /// the async ML attempt for the current photo settles (mask or null), so
  /// `select((s) => s.toLensParams())` and the preview mask resolver
  /// re-read the now-settled cache.
  void bumpBlurVersion() {
    state = state.copyWith(blurAnalysisVersion: state.blurAnalysisVersion + 1);
  }

  /// Appends one manual brush dab point (normalized uv, clamped to 0..1).
  ///
  /// Live-only: NEVER touches history — the Task 6.4 UI brackets the pan
  /// (`beginStroke` on pan-start, [endStroke] on pan-end) so the whole drag
  /// costs exactly one entry. Opens the bracket implicitly when the UI
  /// forgot it. No-op unless the blur source is manual (strength is
  /// ignored: picking Manual already turns strength on, and painting while
  /// off must still record the stroke so the mode fallback can lift).
  /// First point of a dab starts a new [BrushStroke] (with the current
  /// [BlurState.brushRadius]/[brushFeather]); subsequent points extend it
  /// (immutable copy-on-write, structurally shared with the snapshot).
  void addBlurBrushPoint(double x, double y) {
    final BlurState b = state.blur;
    if (b.source != SubjectSource.manual) return;
    _strokeStart ??= _snapshot();
    final (double, double) point = (_clamp(x, 0, 1), _clamp(y, 0, 1));
    state = state.copyWith(
      blur: b.copyWith(
        strokes: _appendedStrokes(
          b.strokes,
          point,
          extendLast: _brushInProgress,
          radius: b.brushRadius,
          feather: b.brushFeather,
        ),
      ),
    );
    _brushInProgress = true;
  }

  // -----------------------------------------------------------------
  // Rays (Task 7.4). All grade setters below are stroke-aware like
  // [_applyFilter]: outside a [beginStroke]/[endStroke] bracket each call
  // pushes exactly one entry; inside, they live-update and [endStroke]
  // commits once. Discrete switches ([applyRaysOneTap], [clearRays]) first
  // commit an open stroke so the drag entry is never corrupted. The sun
  // source itself needs no history-free path: a tap-place calls
  // [setRaysSource] standalone (exactly one entry) and a sun drag brackets
  // it with [beginStroke]/[endStroke] (one entry per drag) — same contract
  // as the sliders.
  // -----------------------------------------------------------------

  /// Sun position in normalized uv 0..1 (clamped). Stroke-aware: a tap-place
  /// is one entry, a drag bracketed with [beginStroke]/[endStroke] is one
  /// entry per drag.
  void setRaysSource(double x, double y) {
    _commitGrade(
      (s) => s.copyWith(
        rays: s.rays.copyWith(source: (_clamp(x, 0, 1), _clamp(y, 0, 1))),
      ),
    );
  }

  /// Shaft strength, 0..100 UI units (clamped). Stroke-aware.
  void setRaysIntensity(double value) => _commitGrade(
    (s) => s.copyWith(rays: s.rays.copyWith(intensity: _clamp(value, 0, 100))),
  );

  /// March length, 0..100 UI units (clamped). Stroke-aware.
  void setRaysLength(double value) => _commitGrade(
    (s) => s.copyWith(rays: s.rays.copyWith(length: _clamp(value, 0, 100))),
  );

  /// Shaft color, 0..100 UI units (clamped). Stroke-aware.
  void setRaysWarmth(double value) => _commitGrade(
    (s) => s.copyWith(rays: s.rays.copyWith(warmth: _clamp(value, 0, 100))),
  );

  /// Streak frequency/sharpness, 0..100 UI units (clamped). Stroke-aware.
  void setRaysDensity(double value) => _commitGrade(
    (s) => s.copyWith(rays: s.rays.copyWith(density: _clamp(value, 0, 100))),
  );

  /// Streak kind (0 = soft fog, 1 = crisp streaks). Stroke-aware.
  void setRaysMode(int value) => _commitGrade(
    (s) => s.copyWith(rays: s.rays.copyWith(mode: value.clamp(0, 1))),
  );

  /// Streak direction, degrees (unclamped: the shaft field wraps). Stroke-aware.
  void setRaysAngle(double value) =>
      _commitGrade((s) => s.copyWith(rays: s.rays.copyWith(angle: value)));

  /// Streak width, 0..100 UI units (clamped). Stroke-aware.
  void setRaysWidth(double value) => _commitGrade(
    (s) => s.copyWith(rays: s.rays.copyWith(width: _clamp(value, 0, 100))),
  );

  /// 1-tap Rays: jumps to [kRaysOneTapStrength] as exactly one undoable
  /// step. When currently off the sun also returns to the default
  /// (.5, .2) in the SAME entry (a parked sun stays parked while on).
  /// Re-tapping at the same strength is a no-op (no duplicate history
  /// entry). Commits an open slider stroke first.
  void applyRaysOneTap() {
    if (state.rays.intensity == kRaysOneTapStrength) return;
    if (_strokeStart != null) endStroke();
    final RaysState r = state.rays;
    final (double, double) source = r.intensity <= 0 ? (0.5, 0.2) : r.source;
    _commitGrade(
      (s) => s.copyWith(
        rays: s.rays.copyWith(intensity: kRaysOneTapStrength, source: source),
      ),
    );
  }

  /// Turns Rays off (intensity 0) as exactly one undoable step, keeping the
  /// sun/params parked for fast re-enable. Already-off is a no-op.
  /// Commits an open slider stroke first.
  void clearRays() {
    if (state.rays.intensity == 0) return;
    if (_strokeStart != null) endStroke();
    setRaysIntensity(0);
  }

  /// The single stroke-aware commit for every undoable grade block
  /// (adjust, filter, enhance, selective, blur, rays, crop).
  ///
  /// `mutate` derives the next state from the current one. Comparing the
  /// derived state with the current one is exactly equivalent to comparing
  /// the mutated block alone: `mutate` only replaces one block and carries
  /// every other field over (preview bytes keep their identity).
  ///
  /// * Derived state == current state → no-op (no notification, no history).
  /// * Inside an open stroke ([beginStroke]…[endStroke]) → live-update;
  ///   the drag commits once in [endStroke].
  /// * Outside → the pre-change snapshot is pushed as exactly one undoable
  ///   step and the history depths are emitted atomically with the grade.
  void _commitGrade(EditorState Function(EditorState s) mutate) {
    final EditorState next = mutate(state);
    if (next == state) return;
    if (_strokeStart != null) {
      state = next;
      return;
    }
    _pushHistory(_snapshot());
    state = next.copyWith(undoDepth: _undo.length, redoDepth: _redo.length);
  }

  /// Copy-on-write append for brush strokes: extends the in-progress dab
  /// when [extendLast] (and strokes exist), else starts a fresh
  /// [BrushStroke] with the caller's brush defaults. Shared by the
  /// selective and the blur brush — their state shapes only differ in
  /// which block carries the stroke list.
  static List<BrushStroke> _appendedStrokes(
    List<BrushStroke> strokes,
    (double, double) point, {
    required bool extendLast,
    required double radius,
    required double feather,
  }) {
    if (extendLast && strokes.isNotEmpty) {
      final BrushStroke last = strokes.last;
      final BrushStroke extended = BrushStroke(
        points: [...last.points, point],
        radius: last.radius,
        feather: last.feather,
      );
      return [...strokes]..[strokes.length - 1] = extended;
    }
    return [
      ...strokes,
      BrushStroke(points: [point], radius: radius, feather: feather),
    ];
  }

  GradeSnapshot _snapshot() => (
    adjust: state.adjust,
    filterId: state.filterId,
    filterStrength: state.filterStrength,
    enhanceStrength: state.enhanceStrength,
    selective: state.selective,
    blur: state.blur,
    rays: state.rays,
    crop: state.crop,
  );

  /// Grade equality IGNORING the stored preview aspect: aspect is layout
  /// ([SelectiveState] contract), so it never affects history commits.
  /// Blur and rays have no layout field — plain equality.
  static bool _sameGrade(GradeSnapshot a, GradeSnapshot b) {
    if (a.adjust != b.adjust ||
        a.filterId != b.filterId ||
        a.filterStrength != b.filterStrength ||
        a.enhanceStrength != b.enhanceStrength ||
        a.blur != b.blur ||
        a.rays != b.rays ||
        a.crop != b.crop) {
      return false;
    }
    final SelectiveState sa = a.selective;
    final SelectiveState sb = b.selective;
    if (sa == sb) return true;
    // Differ — may be aspect-only: compare with aspect normalized.
    return sa.copyWith(geometry: sa.geometry.copyWith(aspect: 1.0)) ==
        sb.copyWith(geometry: sb.geometry.copyWith(aspect: 1.0));
  }

  void _pushHistory(GradeSnapshot previous) {
    _undo.add(previous);
    if (_undo.length > kHistoryLimit) _undo.removeAt(0);
    _redo.clear();
  }

  static double _clamp(double value, double min, double max) =>
      value.clamp(min, max).toDouble();
}
