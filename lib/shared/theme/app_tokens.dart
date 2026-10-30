import 'package:flutter/material.dart';

/// Single source of truth for radii and spacing going forward.
///
/// Existing screens still contain inline `BorderRadius.circular(...)` and
/// `EdgeInsets` values; migrate them opportunistically when touching a file
/// instead of in one massive reformatting commit.
class AppRadius {
  AppRadius._();

  static const double xs = 10;
  static const double sm = 12;
  static const double md = 14;
  static const double lg = 16;
  static const double card = 20;
  static const double sheet = 24;
  static const double pill = 32;

  static BorderRadius circular(double radius) => BorderRadius.circular(radius);

  static BorderRadius get xsRadius => BorderRadius.circular(xs);
  static BorderRadius get smRadius => BorderRadius.circular(sm);
  static BorderRadius get mdRadius => BorderRadius.circular(md);
  static BorderRadius get lgRadius => BorderRadius.circular(lg);
  static BorderRadius get cardRadius => BorderRadius.circular(card);
  static BorderRadius get sheetRadius => BorderRadius.circular(sheet);
  static BorderRadius get pillRadius => BorderRadius.circular(pill);
}

class AppSpacing {
  AppSpacing._();

  static const double xs = 4;
  static const double sm = 8;
  static const double md = 12;
  static const double lg = 16;
  static const double xl = 20;
  static const double xxl = 24;

  static const EdgeInsets cardPadding = EdgeInsets.all(xxl);
  static const EdgeInsets tilePadding = EdgeInsets.all(lg);
  static const EdgeInsets buttonPadding = EdgeInsets.symmetric(
    horizontal: xl,
    vertical: md,
  );
}
