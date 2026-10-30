import 'package:flutter/material.dart';

/// Common animation curves used throughout the application
class AppAnimationCurves {
  AppAnimationCurves._();

  /// Bounce curve with moderate overshoot - used for smooth bounce effects
  /// Similar to bottom sheet opening animation
  static const Curve bounce = Cubic(0.24, 1.2, 0.2, 1.0);

  /// Bounce curve with stronger overshoot - used for emphasis effects
  static const Curve bounceStrong = Cubic(0.3, 1.2, 0.5, 1.0);

  /// Gentle bounce curve - used for subtle animations
  static const Curve bounceGentle = Cubic(0.3, 0.8, 0.15, 1.0);

  /// Standard ease-in-out cubic curve
  static const Curve easeInOutCubic = Curves.easeInOutCubic;

  /// Standard ease-out cubic curve
  static const Curve easeOutCubic = Curves.easeOutCubic;

  /// Standard ease-out quart curve
  static const Curve easeOutQuart = Curves.easeOutQuart;

  /// Standard ease-out curve
  static const Curve easeOut = Curves.easeOut;

  /// Standard ease-in cubic curve
  static const Curve easeInCubic = Curves.easeInCubic;

  /// Standard ease-out quad curve
  static const Curve easeOutQuad = Curves.easeOutQuad;
}
