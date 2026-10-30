import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/shared/data/preferences/app_preference_keys.dart';
import 'package:lens/shared/data/preferences/shared_preferences_provider.dart';

/// Global haptic-feedback switch from Customisation ("Haptic Feedback").
///
/// Stored as a bool so the setting is a plain on/off: a missing value means
/// enabled. Read via [HapticsScope] in plain widgets; write via [setEnabled].
final hapticsEnabledProvider = NotifierProvider<HapticsEnabledNotifier, bool>(
  HapticsEnabledNotifier.new,
);

class HapticsEnabledNotifier extends Notifier<bool> {
  @override
  bool build() {
    final prefs = ref.watch(sharedPreferencesProvider).requireValue;
    return prefs.getBool(AppPreferenceKeys.hapticsEnabled) ?? true;
  }

  Future<void> setEnabled(bool enabled) async {
    state = enabled;
    final prefs = ref.read(sharedPreferencesProvider).requireValue;
    await prefs.setBool(AppPreferenceKeys.hapticsEnabled, enabled);
  }
}
