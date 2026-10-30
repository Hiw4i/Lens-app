import 'package:flutter/material.dart';

abstract class AppColors {
  Brightness get brightness;
  Color get background;
  Color get surface;
  Color get surfaceTranslucent;
  Color get surfaceBright;
  Color get accent;
  Color get accentTranslucent;
  Color get primary;
  Color get primaryInverse;
  Color get secondary;
  Color get border;
}

class _AppColorsData implements AppColors {
  const _AppColorsData({
    required this.brightness,
    required this.background,
    required this.surface,
    required this.surfaceTranslucent,
    required this.surfaceBright,
    required this.accent,
    required this.accentTranslucent,
    required this.primary,
    required this.primaryInverse,
    required this.secondary,
    required this.border,
  });

  @override
  final Brightness brightness;
  @override
  final Color background;
  @override
  final Color surface;
  @override
  final Color surfaceTranslucent;
  @override
  final Color surfaceBright;
  @override
  final Color accent;
  @override
  final Color accentTranslucent;
  @override
  final Color primary;
  @override
  final Color primaryInverse;
  @override
  final Color secondary;
  @override
  final Color border;
}

class Palette {
  final String id;
  final String name;
  final AppColors dark;
  final AppColors light;

  const Palette({
    required this.id,
    required this.name,
    required this.dark,
    required this.light,
  });
}

const List<Palette> palettes = [
  Palette(
    id: 'lens',
    name: 'Lens',
    dark: _AppColorsData(
      brightness: Brightness.dark,
      background: Color(0xFF0A0A0A),
      surface: Color(0xFF1C1C1E),
      surfaceTranslucent: Color(0x831C1C1E),
      surfaceBright: Color(0xFF2C2C2E),
      accent: Color(0xFFFFFFFF),
      accentTranslucent: Color(0x26FFFFFF),
      primary: Color(0xFFFFFFFF),
      primaryInverse: Color(0xFF000000),
      secondary: Color(0xFF8E8E93),
      border: Color(0x1AFFFFFF),
    ),
    light: _AppColorsData(
      brightness: Brightness.light,
      background: Color(0xFFF2F2F7),
      surface: Color(0xFFFFFFFF),
      surfaceTranslucent: Color(0x83FFFFFF),
      surfaceBright: Color(0xFFE5E5EA),
      accent: Color(0xFF000000),
      accentTranslucent: Color(0x26000000),
      primary: Color(0xFF000000),
      primaryInverse: Color(0xFFFFFFFF),
      // 5.3:1 on the #F2F2F7 light background. The previous #6E6E73 sat at
      // ~4.5:1, which is borderline for the 11 px metadata used in the editor.
      secondary: Color(0xFF636366),
      border: Color(0x1A000000),
    ),
  ),
];

int get duskPaletteIndex => 0;

AppColors resolveColors(int paletteIndex, Brightness brightness) {
  final palette = palettes[paletteIndex.clamp(0, palettes.length - 1)];
  return brightness == Brightness.light ? palette.light : palette.dark;
}
