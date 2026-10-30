abstract final class AppPreferenceKeys {
  static const colorTheme = 'colorTheme';
  static const themeBrightness = 'themeBrightness';
  static const uiPerformanceProfile = 'uiPerformanceProfile';
  static const animationSpeed = 'animationSpeed';
  static const hapticsEnabled = 'hapticsEnabled';

  /// One-time discoverability hint for press-and-hold compare.
  static const compareHintSeen = 'compareHintSeen';

  static const all = <String>{
    colorTheme,
    themeBrightness,
    uiPerformanceProfile,
    animationSpeed,
    hapticsEnabled,
    compareHintSeen,
  };
}
