import 'dart:async';

import 'package:flutter/scheduler.dart';
import 'package:flutter/services.dart';

/// Best-effort haptic wrappers shared by every interaction surface.
///
/// Platform haptics are advisory feedback only: missing channels (widget
/// tests, desktop) must never break interaction, so every failure is
/// swallowed here instead of at each call site.
abstract final class AppHaptics {
  /// Single pleasant tick for a successful button tap.
  static void tap() => _fire(HapticFeedback.lightImpact);

  static void light() => _fire(HapticFeedback.lightImpact);

  static void medium() => _fire(HapticFeedback.mediumImpact);

  static void selection() => _fire(HapticFeedback.selectionClick);

  /// Rising "ba-dum" for confirmations like session start or deletion:
  /// a light tick followed by a medium one a few frames later.
  static void doubleTap() {
    scheduleMicrotask(() async {
      try {
        await HapticFeedback.lightImpact();
        await _skipFrames(_doubleTapGapFrames);
        await HapticFeedback.mediumImpact();
      } catch (_) {
        // Ignore: haptics are advisory feedback only.
      }
    });
  }

  /// Gap between the two taps (~80ms at 60fps, ~50ms at 120fps).
  static const _doubleTapGapFrames = 5;

  /// Frame-paced pause. Unlike a wall-clock timer this never leaves a
  /// pending fake timer behind, so widget-test teardowns stay green even
  /// when the test never pumps again. Frames are forced so the second tap
  /// still lands on an otherwise static screen.
  static Future<void> _skipFrames(int frames) {
    final completer = Completer<void>();
    var remaining = frames;
    void tick(Duration _) {
      if (remaining <= 1) {
        completer.complete();
        return;
      }
      remaining--;
      SchedulerBinding.instance.scheduleFrame();
      SchedulerBinding.instance.scheduleFrameCallback(tick);
    }

    SchedulerBinding.instance.scheduleFrame();
    SchedulerBinding.instance.scheduleFrameCallback(tick);
    return completer.future;
  }

  static void _fire(Future<void> Function() feedback) {
    // Microtask, not a Future/timer: widget tests tear down with pending
    // fake timers as a failure, while pending microtasks flush on any pump.
    scheduleMicrotask(() async {
      try {
        await feedback();
      } catch (_) {
        // Ignore: haptics are advisory feedback only.
      }
    });
  }
}
