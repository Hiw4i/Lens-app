import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/shared/data/preferences/app_preference_keys.dart';
import 'package:lens/shared/data/preferences/shared_preferences_provider.dart';
import 'package:lens/shared/motion/policy/ui_performance_policy.dart';

final uiPerformanceProfileProvider =
    NotifierProvider<UiPerformanceProfileNotifier, UiPerformanceProfile>(
      UiPerformanceProfileNotifier.new,
    );

class UiPerformanceProfileNotifier extends Notifier<UiPerformanceProfile> {
  @override
  UiPerformanceProfile build() {
    final prefs = ref.watch(sharedPreferencesProvider).requireValue;
    final stored = prefs.getString(AppPreferenceKeys.uiPerformanceProfile);
    return UiPerformanceProfile.values.firstWhere(
      (profile) => profile.name == stored,
      orElse: () => UiPerformanceProfile.cinematic,
    );
  }

  Future<void> setProfile(UiPerformanceProfile profile) async {
    state = profile;
    final prefs = ref.read(sharedPreferencesProvider).requireValue;
    await prefs.setString(AppPreferenceKeys.uiPerformanceProfile, profile.name);
  }
}

/// Animation-speed choice from Customisation. Only scales policy-gated
/// motion durations; timers, delays and timeouts are unaffected.
enum AnimationSpeed {
  fast('Fast', 1.0),
  balanced('Balanced', 1.25);

  final String label;
  final double scale;

  const AnimationSpeed(this.label, this.scale);
}

final animationSpeedProvider =
    NotifierProvider<AnimationSpeedNotifier, AnimationSpeed>(
      AnimationSpeedNotifier.new,
    );

class AnimationSpeedNotifier extends Notifier<AnimationSpeed> {
  @override
  AnimationSpeed build() {
    final prefs = ref.watch(sharedPreferencesProvider).requireValue;
    final stored = prefs.getString(AppPreferenceKeys.animationSpeed);
    return AnimationSpeed.values.firstWhere(
      (speed) => speed.name == stored,
      orElse: () => AnimationSpeed.fast,
    );
  }

  Future<void> setSpeed(AnimationSpeed speed) async {
    state = speed;
    final prefs = ref.read(sharedPreferencesProvider).requireValue;
    await prefs.setString(AppPreferenceKeys.animationSpeed, speed.name);
  }
}
