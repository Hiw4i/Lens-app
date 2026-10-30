import 'package:flutter/widgets.dart';
import 'package:lens/shared/motion/policy/ui_performance_policy.dart';

class UiPerformanceScope extends InheritedWidget {
  const UiPerformanceScope({
    super.key,
    required this.policy,
    required super.child,
  });

  final UiPerformancePolicy policy;

  static UiPerformancePolicy of(BuildContext context) {
    return maybeOf(context) ??
        const UiPerformancePolicy(
          profile: UiPerformanceProfile.cinematic,
          motionEnabled: true,
        );
  }

  static UiPerformancePolicy? maybeOf(BuildContext context) {
    return context
        .dependOnInheritedWidgetOfExactType<UiPerformanceScope>()
        ?.policy;
  }

  @override
  bool updateShouldNotify(UiPerformanceScope oldWidget) =>
      oldWidget.policy.profile != policy.profile ||
      oldWidget.policy.motionEnabled != policy.motionEnabled ||
      oldWidget.policy.motionScale != policy.motionScale;
}

extension UiPerformanceContext on BuildContext {
  UiPerformancePolicy get uiPerformance => UiPerformanceScope.of(this);
}
