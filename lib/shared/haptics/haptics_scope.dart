import 'package:flutter/widgets.dart';

/// Delivers [hapticsEnabledProvider] to plain widgets that cannot watch
/// Riverpod directly (e.g. [PressableScale]).
///
/// Wired once at the app root in `main.dart`; falls back to enabled when no
/// scope is present so widget tests and previews keep working without one.
class HapticsScope extends InheritedWidget {
  const HapticsScope({super.key, required this.enabled, required super.child});

  final bool enabled;

  static bool of(BuildContext context) => maybeOf(context) ?? true;

  static bool? maybeOf(BuildContext context) {
    return context.dependOnInheritedWidgetOfExactType<HapticsScope>()?.enabled;
  }

  @override
  bool updateShouldNotify(HapticsScope oldWidget) =>
      oldWidget.enabled != enabled;
}

extension HapticsContext on BuildContext {
  bool get hapticsEnabled => HapticsScope.of(this);
}
