import 'package:flutter/material.dart';

import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/app_tokens.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/animation/pressable_scale.dart';

/// A selectable label chip — the shared black-minimalist choice control.
///
/// One implementation for every "pick one of N" row: crop ratios, collage
/// layouts, settings options. Selected = [AppColors.surfaceBright] fill +
/// [AppColors.primary] border and weight-600 label; idle = transparent
/// fill + hairline border + dim label.
class AppChoiceChip extends StatelessWidget {
  const AppChoiceChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.padding = const EdgeInsets.symmetric(horizontal: 14, vertical: 9),
    this.alignment,
  });

  final String label;

  final bool selected;

  /// Null disables the chip (already-selected choices pass null, mirroring
  /// the radio idiom: tapping the selection is a no-op).
  final VoidCallback? onTap;

  /// The crop ratio strip pins a 32px row and passes horizontal-only
  /// padding; every other consumer keeps the default.
  final EdgeInsetsGeometry padding;

  /// Optional child alignment inside the box. Only containers with tight,
  /// larger-than-content constraints need it (the crop strip centers its
  /// label in the pinned 32px row). Must stay NULL in Wrap/Column layouts:
  /// an Align expands to bounded constraints and would stretch every chip
  /// to the full row width instead of hugging its label.
  final AlignmentGeometry? alignment;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 140),
    );
    return Semantics(
      button: true,
      selected: selected,
      enabled: onTap != null,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: PressableScale(
          onTap: onTap,
          child: AnimatedContainer(
            duration: duration,
            alignment: alignment,
            padding: padding,
            decoration: BoxDecoration(
              color: selected ? colors.surfaceBright : Colors.transparent,
              borderRadius: BorderRadius.circular(AppRadius.sm),
              border: Border.all(
                color: selected ? colors.primary : colors.border,
              ),
            ),
            child: AnimatedDefaultTextStyle(
              duration: duration,
              style: AppTextStyles.small(context).copyWith(
                fontSize: 13,
                height: 1.1,
                color: selected ? colors.primary : colors.secondary,
                fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
              ),
              child: Text(label),
            ),
          ),
        ),
      ),
    );
  }
}
