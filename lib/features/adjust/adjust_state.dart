/// Immutable Adjust grade values in UI units.
///
/// Ranges (enforced by `EditorStateNotifier` setters, mirrored in the
/// `LensParams` doc comment): exposure -3..+3 stops; structure -100..100;
/// contrast/saturation/temp/tint/shadows/highlights -100..100.
///
/// Lives in the Adjust feature: everything about Adjust — its state, its
/// panel and its parameter cards — is owned by `features/adjust/`.
class AdjustParams {
  const AdjustParams({
    this.exposure = 0,
    this.structure = 0,
    this.contrast = 0,
    this.saturation = 0,
    this.temp = 0,
    this.tint = 0,
    this.shadows = 0,
    this.highlights = 0,
  });

  /// All-zero grade: preview renders 1:1.
  static const AdjustParams defaults = AdjustParams();

  /// Exposure in stops, -3..+3.
  final double exposure;

  /// Local-contrast (clarity) amount, -100..100; negative softens the
  /// texture.
  final double structure;

  final double contrast;
  final double saturation;
  final double temp;
  final double tint;
  final double shadows;
  final double highlights;

  bool get isDefault => this == defaults;

  AdjustParams copyWith({
    double? exposure,
    double? structure,
    double? contrast,
    double? saturation,
    double? temp,
    double? tint,
    double? shadows,
    double? highlights,
  }) {
    return AdjustParams(
      exposure: exposure ?? this.exposure,
      structure: structure ?? this.structure,
      contrast: contrast ?? this.contrast,
      saturation: saturation ?? this.saturation,
      temp: temp ?? this.temp,
      tint: tint ?? this.tint,
      shadows: shadows ?? this.shadows,
      highlights: highlights ?? this.highlights,
    );
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is AdjustParams &&
          exposure == other.exposure &&
          structure == other.structure &&
          contrast == other.contrast &&
          saturation == other.saturation &&
          temp == other.temp &&
          tint == other.tint &&
          shadows == other.shadows &&
          highlights == other.highlights;

  @override
  int get hashCode => Object.hash(
    exposure,
    structure,
    contrast,
    saturation,
    temp,
    tint,
    shadows,
    highlights,
  );
}
