import 'package:flutter/material.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/editor_controls.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Tool tabs for the editor sheet: borderless, icon-over-small-label chips
/// that sit flush against the sheet's bottom edge.
///
/// The horizontal strip owns its scroll controller (see [EditorFadingRow]),
/// so the offset survives rebuilds and the rail never snaps back to the
/// first tool under the user's finger.
class ToolRail extends StatelessWidget {
  const ToolRail({super.key, required this.selected, required this.onSelect});

  final EditorTool selected;
  final ValueChanged<EditorTool> onSelect;

  static const tools = <(EditorTool, String, IconData)>[
    // Crop comes first: it is the tool people reach for right after a shot,
    // and the rail scrolls, so the first chip is the one always in reach.
    (EditorTool.crop, 'Crop', LucideIcons.crop),
    (EditorTool.filters, 'Filters', LucideIcons.palette),
    (EditorTool.adjust, 'Adjust', LucideIcons.slidersHorizontal),
    // Enhance has no chip of its own: the rail is for the tools a photo is
    // composed with, and Enhance is one tap away inside Adjust.
    (EditorTool.selective, 'Selective', LucideIcons.crosshair),
    (EditorTool.blur, 'Blur', LucideIcons.aperture),
    (EditorTool.rays, 'Rays', LucideIcons.sun),
  ];

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    return EditorFadingRow(
      height: EditorPanelMetrics.railHeight,
      padding: const EdgeInsets.symmetric(
        horizontal: EditorPanelMetrics.hPad - 4,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (final tool in tools)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 3),
              child: _ToolChip(
                label: tool.$2,
                icon: tool.$3,
                selected: selected == tool.$1,
                onTap: () => onSelect(tool.$1),
                accent: colors.primary,
                idle: colors.secondary,
                surface: colors.surfaceBright,
              ),
            ),
        ],
      ),
    );
  }
}

/// One tool tab: icon + label, no border, a soft fill when selected.
class _ToolChip extends StatelessWidget {
  const _ToolChip({
    required this.label,
    required this.icon,
    required this.selected,
    required this.onTap,
    required this.accent,
    required this.idle,
    required this.surface,
  });

  final String label;
  final IconData icon;
  final bool selected;
  final VoidCallback onTap;
  final Color accent;
  final Color idle;
  final Color surface;

  @override
  Widget build(BuildContext context) {
    final foreground = selected ? accent : idle;
    final duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 160),
    );
    return Semantics(
      selected: selected,
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(12),
        child: AnimatedContainer(
          duration: duration,
          height: EditorPanelMetrics.railHeight - 10,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: selected ? surface : Colors.transparent,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              TweenAnimationBuilder<Color?>(
                tween: ColorTween(end: foreground),
                duration: duration,
                builder: (context, color, _) =>
                    Icon(icon, size: 17, color: color ?? foreground),
              ),
              const SizedBox(width: 7),
              AnimatedDefaultTextStyle(
                duration: duration,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.1,
                  fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
                  color: foreground,
                ),
                child: Text(label),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
