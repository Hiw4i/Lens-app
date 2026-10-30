import 'dart:math' as math;

import 'package:flutter/physics.dart';
import 'package:lens/shared/motion/tokens/app_durations.dart';

/// Perceptual spring timing and explicit route completion budgets.
abstract final class AppSprings {
  static const minimumPressDuration = Duration(milliseconds: 90);
  static const sheetOpenDuration = Duration(milliseconds: 700);
  static const sheetCloseDuration = AppDurations.medium;
  static const sheetExpansionDuration = Duration(milliseconds: 380);
  static const navigationRevealDuration = Duration(milliseconds: 800);
  static const navigationSettleDuration = Duration(milliseconds: 300);
  static const navigationSettleMaxImpulse = 3.0;
  static const shortcutHiddenOffset = 9.0;

  // Keep contact prompt while letting a held press settle with a gentle tail.
  static final press = SpringDescription.withDurationAndBounce(
    duration: AppDurations.pressDown,
    bounce: 0.18,
  );
  // Keep the original easeOutBack-sized visible overshoot and return rhythm.
  static final release = SpringDescription.withDurationAndBounce(
    duration: AppDurations.press,
    bounce: 0.39,
  );
  static final hover = release;

  // Match the original small overshoot and its peak near 54% of entrance time.
  static SpringDescription sheetEntrance(Duration duration) =>
      SpringDescription.withDurationAndBounce(
        duration: Duration(
          milliseconds: math.max(1, (duration.inMilliseconds * 0.63).round()),
        ),
        bounce: 0.19,
      );

  // The route's offscreen target reaches the viewport edge within this budget.
  static SpringDescription sheetExit(Duration duration) =>
      SpringDescription.withDurationAndBounce(duration: duration * 2);

  static final sheetExpansion = SpringDescription.withDurationAndBounce(
    duration: sheetExpansionDuration,
  );
  static final sheetDismissal = SpringDescription.withDurationAndBounce(
    duration: sheetCloseDuration,
  );
  static SpringDescription sheetHeight(Duration duration) =>
      SpringDescription.withDurationAndBounce(duration: duration);
  static const swipeReturn = SpringDescription(
    mass: 1,
    stiffness: 400,
    damping: 28,
  );
  static SpringDescription reveal(Duration duration, {required bool visible}) =>
      SpringDescription.withDurationAndBounce(
        duration: duration,
        bounce: visible ? 0.22 : 0,
      );

  static final navigation = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 280),
    bounce: 0.22,
  );
  static final navigationSettle = SpringDescription.withDurationAndBounce(
    duration: navigationSettleDuration,
    bounce: 0.10,
  );
  static final navigationReveal = SpringDescription.withDurationAndBounce(
    duration: navigationRevealDuration,
    bounce: 0.36,
  );
  static final navigationRevealCrossAxis =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 420),
        bounce: 0.28,
      );
  static final navigationEntranceTravel =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 540),
        bounce: 0.28,
      );
  static final navigationHide = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 480),
  );
  static final navigationCollapse = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 540),
  );
  static final navigationCollapseCrossAxis =
      SpringDescription.withDurationAndBounce(
        duration: const Duration(milliseconds: 320),
      );

  // The photo glides onto its resting frame when it returns to 1x.
  static final photoSnapHome = SpringDescription.withDurationAndBounce(
    duration: const Duration(milliseconds: 320),
    bounce: 0.12,
  );

  static const scaleTolerance = Tolerance(distance: 0.0001, velocity: 0.001);
}
