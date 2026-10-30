import 'dart:async';

import 'package:flutter/physics.dart';
import 'package:flutter/widgets.dart';
import 'package:lens/shared/motion/tokens/app_springs.dart';

/// Visual feedback only. Gesture owners retain activation and hold callbacks.
class PressMotionController extends AnimationController
    with WidgetsBindingObserver {
  PressMotionController({
    required super.vsync,
    this.pressedScale = 0.95,
    this.hoverScale = 1.02,
  }) : super.unbounded(value: 1) {
    addListener(_continueRelease);
    WidgetsBinding.instance.addObserver(this);
  }

  final double pressedScale;
  final double hoverScale;
  bool _motionEnabled = true;
  bool _pressed = false;
  bool _hovered = false;
  bool _releasePending = false;
  bool _releaseScheduled = false;
  double _pressStart = 1;
  double _pressedTarget = 0.95;
  int _generation = 0;

  double get _restScale => _hovered ? hoverScale : 1;

  void setMotionEnabled(bool enabled) {
    if (_motionEnabled == enabled) return;
    _motionEnabled = enabled;
    cancel();
  }

  void hover(bool hovered) {
    _hovered = hovered;
    if (!_pressed && !_releasePending) _animate(_restScale, AppSprings.hover);
  }

  void press({double? targetScale}) {
    _generation++;
    _releaseScheduled = false;
    _releasePending = false;
    _pressed = true;
    _pressStart = value;
    _pressedTarget = targetScale ?? pressedScale;
    _animate(_pressedTarget, AppSprings.press);
  }

  void release() {
    if (!_pressed) return;
    _pressed = false;
    if (!_motionEnabled) {
      value = _restScale;
      return;
    }
    _releasePending = true;
    _continueRelease();
  }

  void _continueRelease() {
    if (!_releasePending || _releaseScheduled) return;
    // Ticker time is monotonic and counts visible animation time, not wall
    // time while frames are suspended. No delayed task can outlive a press.
    final elapsed = isAnimating
        ? lastElapsedDuration ?? Duration.zero
        : AppSprings.minimumPressDuration;
    final remaining = (value - _pressedTarget).abs();
    final travel = (_pressStart - _pressedTarget).abs();
    if (elapsed < AppSprings.minimumPressDuration ||
        remaining > travel * 0.05 + AppSprings.scaleTolerance.distance) {
      return;
    }
    _releaseScheduled = true;
    final generation = _generation;
    scheduleMicrotask(() {
      if (generation != _generation || !_releasePending) return;
      _releasePending = false;
      _releaseScheduled = false;
      _animate(_restScale, AppSprings.release);
    });
  }

  void cancel() {
    _generation++;
    _releaseScheduled = false;
    _releasePending = false;
    _pressed = false;
    _animate(_restScale, AppSprings.release);
  }

  void resetInteraction() {
    _generation++;
    _releasePending = false;
    _releaseScheduled = false;
    _pressed = false;
    _hovered = false;
    value = 1;
  }

  void _animate(double target, SpringDescription spring) {
    if (!_motionEnabled) {
      value = target;
      return;
    }
    final currentVelocity = velocity;
    if (!_pressed &&
        (value - target).abs() < AppSprings.scaleTolerance.distance &&
        currentVelocity.abs() < AppSprings.scaleTolerance.velocity) {
      value = target;
      return;
    }
    animateWith(
      _pressed
          ? _PressSimulation(spring, value, target, currentVelocity)
          : SpringSimulation(
              spring,
              value,
              target,
              currentVelocity,
              tolerance: AppSprings.scaleTolerance,
              snapToEnd: true,
            ),
    );
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) resetInteraction();
  }

  @override
  void dispose() {
    _generation++;
    _releasePending = false;
    WidgetsBinding.instance.removeObserver(this);
    removeListener(_continueRelease);
    super.dispose();
  }
}

class _PressSimulation extends SpringSimulation {
  _PressSimulation(super.spring, super.start, super.end, super.velocity)
    : super(tolerance: AppSprings.scaleTolerance, snapToEnd: true);

  @override
  bool isDone(double time) =>
      time >= AppSprings.minimumPressDuration.inMicroseconds / 1000000 &&
      super.isDone(time);
}
