import 'dart:math' as math;

import 'package:flutter/foundation.dart';

/// Persisted application-wide graphics and motion quality.
enum UiPerformanceProfile {
  performance('Performance'),
  balanced('Balanced'),
  cinematic('Cinematic');

  const UiPerformanceProfile(this.label);

  final String label;
}

@immutable
class UiPerformancePolicy {
  const UiPerformancePolicy({
    required this.profile,
    required this.motionEnabled,
    this.motionScale = 1.0,
  }) : assert(motionScale > 0, 'motionScale must be positive');

  static const _openContainerBaseDuration = Duration(milliseconds: 320);
  static const _onboardingTransitionBaseDuration = Duration(milliseconds: 600);
  static const _smoothScrollBaseDuration = Duration(milliseconds: 1300);

  final UiPerformanceProfile profile;
  final bool motionEnabled;

  /// Global animation-speed multiplier applied to every policy-gated
  /// duration. 1.0 keeps token values as designed; the Customisation
  /// "Animation Speed" setting raises it for slower motion. Timers,
  /// delays and timeouts never pass through here, so they are unaffected.
  final double motionScale;

  bool get isPerformance => profile == UiPerformanceProfile.performance;
  bool get isBalanced => profile == UiPerformanceProfile.balanced;
  bool get isCinematic => profile == UiPerformanceProfile.cinematic;
  bool get blurEnabled => isCinematic;
  bool get ambientAnimationsEnabled => motionEnabled && !isPerformance;
  bool get openContainerEnabled => motionEnabled && !isPerformance;
  bool get smoothScrollEnabled => !isPerformance;

  double get modalDimOpacity => isBalanced ? 0.5 : 0.3;
  Duration get periodMovementDuration => !motionEnabled
      ? Duration.zero
      : _scaled(Duration(milliseconds: isPerformance ? 300 : 500));

  /// Open-container route transition, scaled by [motionScale].
  Duration get openContainerDuration => _scaled(_openContainerBaseDuration);

  /// Onboarding page transitions, scaled by [motionScale].
  Duration get onboardingForwardTransitionDuration =>
      _scaled(_onboardingTransitionBaseDuration);

  /// Onboarding page transitions, scaled by [motionScale].
  Duration get onboardingBackTransitionDuration =>
      _scaled(_onboardingTransitionBaseDuration);

  /// Silky scroll glide, scaled by [motionScale].
  Duration get smoothScrollDuration => _scaled(_smoothScrollBaseDuration);
  Duration colorDuration(Duration duration) => motionDuration(duration);

  // Stopwatch start/stop is functional feedback in every quality profile.
  Duration stateChangeDuration(Duration duration) =>
      motionEnabled ? _scaled(duration) : Duration.zero;

  Duration motionDuration(Duration duration) =>
      motionEnabled && !isPerformance ? _scaled(duration) : Duration.zero;

  /// Scales [duration] by [motionScale], never collapsing nonzero motion
  /// into zero and never touching an already-zero duration.
  Duration _scaled(Duration duration) {
    if (duration == Duration.zero || motionScale == 1.0) return duration;
    final scaled = (duration.inMicroseconds * motionScale).round();
    return Duration(microseconds: math.max(1, scaled));
  }

  factory UiPerformancePolicy.resolve(
    UiPerformanceProfile profile, {
    required bool disableAnimations,
    double motionScale = 1.0,
  }) {
    return UiPerformancePolicy(
      profile: profile,
      motionEnabled: !disableAnimations,
      motionScale: motionScale,
    );
  }
}
