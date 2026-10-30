import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../data/preferences/app_preference_keys.dart';
import '../data/preferences/shared_preferences_provider.dart';
import 'themes.dart';

enum ThemeBrightness {
  dark('Dark'),
  light('Light'),
  system('System');

  final String label;
  const ThemeBrightness(this.label);

  ThemeMode get toThemeMode => switch (this) {
    ThemeBrightness.system => ThemeMode.system,
    ThemeBrightness.light => ThemeMode.light,
    ThemeBrightness.dark => ThemeMode.dark,
  };

  Brightness resolveBrightness(Brightness platformBrightness) => switch (this) {
    ThemeBrightness.system => platformBrightness,
    ThemeBrightness.light => Brightness.light,
    ThemeBrightness.dark => Brightness.dark,
  };
}

final paletteProvider = NotifierProvider<PaletteNotifier, int>(
  PaletteNotifier.new,
);

class PaletteNotifier extends Notifier<int> {
  @override
  int build() {
    final prefs = ref.watch(sharedPreferencesProvider).requireValue;
    final index = prefs.getInt(AppPreferenceKeys.colorTheme) ?? 0;
    return index.clamp(0, palettes.length - 1);
  }

  Future<void> setPalette(int index) async {
    state = index.clamp(0, palettes.length - 1);

    final prefs = ref.read(sharedPreferencesProvider).requireValue;
    await prefs.setInt(AppPreferenceKeys.colorTheme, state);
  }
}

final themeBrightnessProvider =
    NotifierProvider<ThemeBrightnessNotifier, ThemeBrightness>(
      ThemeBrightnessNotifier.new,
    );

class ThemeBrightnessNotifier extends Notifier<ThemeBrightness> {
  @override
  ThemeBrightness build() {
    final prefs = ref.watch(sharedPreferencesProvider).requireValue;
    final stored = prefs.getString(AppPreferenceKeys.themeBrightness);
    if (stored != null) {
      return ThemeBrightness.values.firstWhere(
        (b) => b.name == stored,
        orElse: () => ThemeBrightness.dark,
      );
    }
    return ThemeBrightness.dark;
  }

  Future<void> setBrightness(ThemeBrightness brightness) async {
    state = brightness;

    final prefs = ref.read(sharedPreferencesProvider).requireValue;
    await prefs.setString(AppPreferenceKeys.themeBrightness, brightness.name);
  }
}
