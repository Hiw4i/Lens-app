import 'package:lens/features/selective/mask_raster.dart' show BrushStroke;
import 'package:lens/features/selective/selective_mask.dart'
    show SelectiveGeometry, SelectiveMode;

/// Immutable selective grade (Task 4.4).
///
/// Off-switch is [active], NOT a null mode: [mode] keeps the last-picked
/// shape (radial/linear/brush) so re-enabling restores it without
/// re-picking — fast toggle for the Task 4.5 UI.
///
/// Ranges (enforced by `EditorStateNotifier` setters, mirrored in the
/// `LensParams` doc comment): [strength] 0..100; [selExp] -3..+3 stops;
/// [selCon]/[selSat] -100..100; geometry fields follow
/// [SelectiveGeometry] (center 0..1, radius/feather/width 0..1,
/// angle 0..360); [brushRadius] 0.01..0.5 uv, [brushFeather] 0..1.
///
/// Aspect contract (Task 4.4): `geometry.aspect` is a STORED preview ratio
/// (default 1.0) updated by the UI via `setSelectiveAspect` WITHOUT history
/// (like `tool`/`showOriginal` — layout, not grade). It is NEVER trusted
/// downstream: the preview painter overwrites shader slot 28 with the real
/// paint `size.width/size.height` every frame, and `applyLensGrade`
/// recomputes it from the decoded frame `w/h` (aspectOverride). So the
/// radial ellipse looks visually identical on preview and export even
/// though the two contexts have different resolutions. Undo/redo/reset
/// ignore the stored aspect (it is outside [GradeSnapshot] comparisons
/// only in the sense that aspect-only edits never PUSH — the value itself
/// still travels inside [geometry], and undo preserves the latest aspect
/// instead of restoring the snapshot's one).
///
/// History cost: [strokes] travel inside the snapshot by reference
/// (immutable, copy-on-write, structurally shared). A brush drag mutates a
/// live list without history and commits ONE entry in `endStroke`, so 20
/// stacked entries stay cheap.
class SelectiveState {
  const SelectiveState({
    this.mode = SelectiveMode.radial,
    this.active = false,
    this.geometry = const SelectiveGeometry(),
    this.strength = 100,
    this.selExp = 0,
    this.selCon = 0,
    this.selSat = 0,
    this.strokes = const [],
    this.brushRadius = 0.08,
    this.brushFeather = 0.5,
  }) : assert(strength >= 0 && strength <= 100),
       assert(selExp >= -3 && selExp <= 3),
       assert(selCon >= -100 && selCon <= 100),
       assert(selSat >= -100 && selSat <= 100),
       assert(brushRadius > 0 && brushRadius <= 1),
       assert(brushFeather >= 0 && brushFeather <= 1);

  /// Mask shape; remembered while [active] is false (last-pick restore).
  final SelectiveMode mode;

  /// Master off-switch. False = stage skipped everywhere (selMode 0).
  final bool active;

  /// Radial/linear geometry. `aspect` is the stored preview ratio —
  /// see the aspect contract above; never trusted downstream.
  final SelectiveGeometry geometry;

  /// Mask mix amount, 0..100 UI units (-> /100 into shader slot 30).
  final double strength;

  /// Local exposure inside the mask, stops -3..+3 (slot 31, as-is).
  final double selExp;

  /// Local contrast/saturation inside the mask, -100..100 UI units
  /// (-> /100 into slots 32..33, same scale as the global grade).
  final double selCon;
  final double selSat;

  /// Painted brush polyline spines (immutable, copy-on-write).
  /// Only read when [active] && [mode] == brush; empty = no brush.
  final List<BrushStroke> strokes;

  /// Default dab radius/feather for NEW strokes created by
  /// `addBrushPoint` (uv units / 0..1). Existing strokes keep their own.
  final double brushRadius;
  final double brushFeather;

  /// Default = off. DECISION: `!active` only — a parked `strength == 0`
  /// with `active == true` is still a user edit (undoable, survives
  /// `reset`-detection); the off-fallback (`selMode 0`) happens at the
  /// `toLensParams` mapping, not here.
  bool get isDefault => !active;

  SelectiveState copyWith({
    SelectiveMode? mode,
    bool? active,
    SelectiveGeometry? geometry,
    double? strength,
    double? selExp,
    double? selCon,
    double? selSat,
    List<BrushStroke>? strokes,
    double? brushRadius,
    double? brushFeather,
  }) {
    return SelectiveState(
      mode: mode ?? this.mode,
      active: active ?? this.active,
      geometry: geometry ?? this.geometry,
      strength: strength ?? this.strength,
      selExp: selExp ?? this.selExp,
      selCon: selCon ?? this.selCon,
      selSat: selSat ?? this.selSat,
      strokes: strokes ?? this.strokes,
      brushRadius: brushRadius ?? this.brushRadius,
      brushFeather: brushFeather ?? this.brushFeather,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! SelectiveState) return false;
    if (mode != other.mode ||
        active != other.active ||
        geometry != other.geometry ||
        strength != other.strength ||
        selExp != other.selExp ||
        selCon != other.selCon ||
        selSat != other.selSat ||
        brushRadius != other.brushRadius ||
        brushFeather != other.brushFeather) {
      return false;
    }
    if (strokes.length != other.strokes.length) return false;
    for (int i = 0; i < strokes.length; i++) {
      if (strokes[i] != other.strokes[i]) return false;
    }
    return true;
  }

  @override
  int get hashCode => Object.hash(
    mode,
    active,
    geometry,
    strength,
    selExp,
    selCon,
    selSat,
    brushRadius,
    brushFeather,
    Object.hashAll(strokes),
  );
}
