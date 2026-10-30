import 'package:lens/features/blur/subject_mask.dart' show SubjectSource;
import 'package:lens/features/selective/mask_raster.dart' show BrushStroke;

/// Immutable background-blur grade (Task 6.4).
///
/// Off-switch is `strength == 0` (NOT a null mode): [source] keeps the
/// last-picked mask source (auto/manual) while off so re-enabling restores
/// it without re-picking — fast toggle, same philosophy as
/// [SelectiveState.active]. Parked [radius]/[feather]/[invert] are likewise
/// remembered while off.
///
/// Ranges (enforced by `EditorStateNotifier` setters, mirrored in the
/// `LensParams` doc comment): [strength] 0..100; [radius] 0..100 UI units
/// (-> /100*0.05 fraction of min(w,h) into shader slot 35); [feather]
/// 0..100 UI units (-> /100 into slot 36); [brushRadius] 0.01..0.5 uv,
/// [brushFeather] 0..1.
///
/// Effective mode (see `toLensParams`): `strength <= 0` => off (0);
/// `source == manual &&` no painted stroke => off (0, Task 6.3 concern #2
/// — empty manual must grade nothing); else `auto => 1`, `manual => 2`.
///
/// History cost: [strokes] travel inside the snapshot by reference
/// (immutable, copy-on-write, structurally shared). A brush drag mutates a
/// live list without history and commits ONE entry in `endStroke`, same as
/// selective.
class BlurState {
  const BlurState({
    this.source = SubjectSource.auto,
    this.strength = 0,
    this.radius = 40,
    this.feather = 50,
    this.invert = false,
    this.strokes = const [],
    this.brushRadius = 0.08,
    this.brushFeather = 0.5,
  }) : assert(strength >= 0 && strength <= 100),
       assert(radius >= 0 && radius <= 100),
       assert(feather >= 0 && feather <= 100),
       assert(brushRadius > 0 && brushRadius <= 1),
       assert(brushFeather >= 0 && brushFeather <= 1);

  /// Mask source; remembered while [strength] is 0.
  final SubjectSource source;

  /// Blurred<->sharp mix, 0..100 UI units (-> /100 into slot 37).
  /// 0 = stage skipped everywhere (mode 0, neutral).
  final double strength;

  /// Bokeh radius, 0..100 UI units (-> /100*0.05 fraction into slot 35).
  final double radius;

  /// Mask edge softness, 0..100 UI units (-> /100 into slot 36,
  /// 0 = hard step).
  final double feather;

  /// Blur the subject instead of the background.
  final bool invert;

  /// Hand-painted spines (immutable, copy-on-write).
  /// Only read when [source] is manual; empty = no manual mask.
  final List<BrushStroke> strokes;

  /// Default dab radius/feather for NEW strokes created by
  /// `addBlurBrushPoint` (uv units / 0..1). Existing strokes keep their own.
  final double brushRadius;
  final double brushFeather;

  /// Default = off. DECISION: `strength == 0 && strokes.isEmpty` only — a
  /// parked non-default radius/feather/invert/source with `strength == 0`
  /// is still a user edit in history terms but reports default for the
  /// `isDefault` gate (same philosophy as [SelectiveState.isDefault]:
  /// off means off, parked params are remembered, not graded).
  bool get isDefault => strength == 0 && strokes.isEmpty;

  /// Effective UI activity: strength > 0. The empty-manual off-fallback
  /// (manual source with no painted stroke) is applied at the
  /// `toLensParams` mapping, not here — same split as selective.
  bool get isActive => strength > 0;

  BlurState copyWith({
    SubjectSource? source,
    double? strength,
    double? radius,
    double? feather,
    bool? invert,
    List<BrushStroke>? strokes,
    double? brushRadius,
    double? brushFeather,
  }) {
    return BlurState(
      source: source ?? this.source,
      strength: strength ?? this.strength,
      radius: radius ?? this.radius,
      feather: feather ?? this.feather,
      invert: invert ?? this.invert,
      strokes: strokes ?? this.strokes,
      brushRadius: brushRadius ?? this.brushRadius,
      brushFeather: brushFeather ?? this.brushFeather,
    );
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is! BlurState) return false;
    if (source != other.source ||
        strength != other.strength ||
        radius != other.radius ||
        feather != other.feather ||
        invert != other.invert ||
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
    source,
    strength,
    radius,
    feather,
    invert,
    brushRadius,
    brushFeather,
    Object.hashAll(strokes),
  );
}
