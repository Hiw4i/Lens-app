import 'package:flutter/material.dart';

import 'themes.dart';
export 'themes.dart';

/// Stateful wrapper that animates [AppColors] transitions via [Color.lerp].
class ThemeColors extends StatefulWidget {
  final AppColors colors;
  final Widget child;
  final Duration duration;

  const ThemeColors({
    super.key,
    required this.colors,
    required this.child,
    this.duration = const Duration(milliseconds: 350),
  });

  static AppColors of(BuildContext context) {
    return _InheritedThemeColors.of(context);
  }

  @override
  State<ThemeColors> createState() => _ThemeColorsState();
}

class _ThemeColorsState extends State<ThemeColors>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late AppColors _targetColors;
  AppColors? _previousColors;

  @override
  void initState() {
    super.initState();
    _targetColors = widget.colors;
    _controller = AnimationController(duration: widget.duration, vsync: this)
      ..addListener(_onTick);
  }

  @override
  void didUpdateWidget(ThemeColors old) {
    super.didUpdateWidget(old);
    _controller.duration = widget.duration;
    if (widget.duration == Duration.zero) {
      _controller.stop();
      _previousColors = null;
      _targetColors = widget.colors;
      return;
    }
    if (old.colors != widget.colors) {
      // Start from the colour currently on screen, not the previous target:
      // a fast palette/brightness switch mid-transition would otherwise snap
      // to the old destination before animating to the new one.
      _previousColors = _effectiveColors;
      _targetColors = widget.colors;
      _controller.forward(from: 0.0);
    }
  }

  void _onTick() => setState(() {});

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  AppColors get _effectiveColors {
    if (_previousColors == null || !_controller.isAnimating) {
      _previousColors = null;
      return _targetColors;
    }
    return _AnimAppColors(_previousColors!, _targetColors, _controller.value);
  }

  @override
  Widget build(BuildContext context) {
    return _InheritedThemeColors(colors: _effectiveColors, child: widget.child);
  }
}

class _InheritedThemeColors extends InheritedWidget {
  final AppColors colors;

  const _InheritedThemeColors({required this.colors, required super.child});

  static AppColors of(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<_InheritedThemeColors>()!
        .colors;
  }

  @override
  bool updateShouldNotify(_InheritedThemeColors oldWidget) =>
      oldWidget.colors != colors;
}

extension ThemeColorsContext on BuildContext {
  AppColors get themeColors => ThemeColors.of(this);
}

class _AnimAppColors implements AppColors {
  final AppColors begin;
  final AppColors end;
  final double t;

  const _AnimAppColors(this.begin, this.end, this.t);

  @override
  Brightness get brightness => end.brightness;

  @override
  Color get background => Color.lerp(begin.background, end.background, t)!;

  @override
  Color get surface => Color.lerp(begin.surface, end.surface, t)!;

  @override
  Color get surfaceTranslucent =>
      Color.lerp(begin.surfaceTranslucent, end.surfaceTranslucent, t)!;

  @override
  Color get surfaceBright =>
      Color.lerp(begin.surfaceBright, end.surfaceBright, t)!;

  @override
  Color get accent => Color.lerp(begin.accent, end.accent, t)!;

  @override
  Color get accentTranslucent =>
      Color.lerp(begin.accentTranslucent, end.accentTranslucent, t)!;

  @override
  Color get primary => Color.lerp(begin.primary, end.primary, t)!;

  @override
  Color get primaryInverse =>
      Color.lerp(begin.primaryInverse, end.primaryInverse, t)!;

  @override
  Color get secondary => Color.lerp(begin.secondary, end.secondary, t)!;

  @override
  Color get border => Color.lerp(begin.border, end.border, t)!;
}
