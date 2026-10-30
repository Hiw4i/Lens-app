import 'package:flutter/material.dart';

import 'package:lens/shared/theme/app_tokens.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// A small surface-filled, hairline-bordered container for floating hints
/// and status badges (black-minimalist chrome).
///
/// The editor previously hand-rolled the same decoration three times
/// (compare hint, "Original" badge, blur auto-miss hint); this is the
/// single source of that surface. Keep paddings tight: badges read as
/// chrome, not as cards.
class AppBadge extends StatelessWidget {
  const AppBadge({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
    this.radius = AppRadius.xs,
  });

  final Widget child;

  final EdgeInsetsGeometry padding;

  /// Corner radius. Defaults to the tight badge radius ([AppRadius.xs]);
  /// pass [AppRadius.sm] for slightly roomier hints.
  final double radius;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    return Container(
      padding: padding,
      decoration: BoxDecoration(
        color: colors.surface,
        borderRadius: BorderRadius.circular(radius),
        border: Border.all(color: colors.border),
      ),
      child: child,
    );
  }
}
