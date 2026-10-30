/// Immutable Tyndall-rays grade (Task 7.4).
///
/// Off-switch is `intensity == 0` (NOT a null source): [source]/[length]/
/// [warmth]/[density] are parked while off and remembered for fast
/// re-enable — same philosophy as [BlurState]. UI units 0..100 for the
/// four scalars (-> /100 into shader slots 42..45); [source] is normalized
/// uv with a top-left origin like selective (slots 40..41, passed through
/// as-is so an off-frame sun keeps marching).
///
/// Ranges (enforced by `EditorStateNotifier` setters, mirrored in the
/// `LensParams` doc comment): [intensity]/[length]/[warmth]/[density]
/// 0..100; [source] components 0..1 (clamped on set).
///
/// Defaults park at the math-core values ([RaysParams]: .5/.2 sun, 0
/// intensity, .6 length, .7 warmth, .5 density), so one-tap only has to
/// flip the intensity to arm an already-sane golden sun — warmth .7 is
/// deliberately golden, never acidic.
///
/// Effective gate (see `toLensParams`): `intensity <= 0` => rayOn 0 (the
/// shader exits before any tap, the CPU export ignores the block).
class RaysState {
  const RaysState({
    this.source = (0.5, 0.2),
    this.intensity = 0,
    this.length = 60,
    this.warmth = 70,
    this.density = 50,
    int? mode,
    int? kind,
    int? type,
    double? angle,
    double? direction,
    double? width,
    double? spread,
  }) : mode = mode ?? kind ?? type ?? 0,
       angle = angle ?? direction ?? 0.0,
       width = width ?? spread ?? 100.0,
       assert(intensity >= 0 && intensity <= 100),
       assert(length >= 0 && length <= 100),
       assert(warmth >= 0 && warmth <= 100),
       assert(density >= 0 && density <= 100);

  /// Sun position in normalized uv 0..1, top-left origin.
  /// Remembered while [intensity] is 0.
  final (double, double) source;

  /// Shaft strength, 0..100 UI units (-> /100 into slot 42).
  /// 0 = stage skipped everywhere (rayOn 0, neutral).
  final double intensity;

  /// March length as a share of the frame diagonal, 0..100 UI units
  /// (-> /100 into slot 43).
  final double length;

  /// Shaft color, 0..100 UI units (-> /100 into slot 44,
  /// 0 = neutral white, 100 = golden).
  final double warmth;

  /// Streak frequency/sharpness, 0..100 UI units (-> /100 into slot 45).
  final double density;

  /// Ray kind: 0 = bright-source, 1 = fog. UI units 0/100? store 0/1? We'll store 0/1 int.
  final int mode;

  /// Ray direction in degrees 0..360.
  final double angle;

  /// Ray angular spread 0..100 UI units (-> /100).
  final double width;

  /// Default = off. DECISION: `intensity == 0` only — parked non-default
  /// length/warmth/density/source with `intensity == 0` are remembered,
  /// not graded (same philosophy as [SelectiveState.isDefault]: off
  /// means off, parked params are not user-visible grade).
  bool get isDefault => intensity == 0;

  /// Effective UI activity: intensity > 0. The gate itself (`rayOn`) is
  /// applied at the `toLensParams` mapping, not here — same split as blur.
  bool get isActive => intensity > 0;

  RaysState copyWith({
    (double, double)? source,
    double? intensity,
    double? length,
    double? warmth,
    double? density,
    int? mode,
    int? kind,
    int? type,
    double? angle,
    double? direction,
    double? width,
    double? spread,
  }) {
    return RaysState(
      source: source ?? this.source,
      intensity: intensity ?? this.intensity,
      length: length ?? this.length,
      warmth: warmth ?? this.warmth,
      density: density ?? this.density,
      mode: mode ?? kind ?? type ?? this.mode,
      angle: angle ?? direction ?? this.angle,
      width: width ?? spread ?? this.width,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is RaysState &&
          source == other.source &&
          intensity == other.intensity &&
          length == other.length &&
          warmth == other.warmth &&
          density == other.density &&
          mode == other.mode &&
          angle == other.angle &&
          width == other.width;

  @override
  int get hashCode => Object.hash(
    source,
    intensity,
    length,
    warmth,
    density,
    mode,
    angle,
    width,
  );
}
