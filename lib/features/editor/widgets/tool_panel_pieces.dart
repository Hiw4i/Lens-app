import 'package:flutter/material.dart';

import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';

/// The one-line hint under a tool panel's controls ("Paint over your
/// subject…", "Drag the sun to move the light…"). One implementation for
/// every tool panel: tight 11px dim copy, centered, single line.
class ToolPanelHint extends StatelessWidget {
  const ToolPanelHint({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Text(
      text,
      style: AppTextStyles.smallDim(context).copyWith(fontSize: 11),
      textAlign: TextAlign.center,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}

/// The one-tap primary action a tool shows while it is off ("Blur
/// background", "Add light rays"). Routes the tap through the shared
/// haptics + the caller's action, sized to the panel's secondary row.
class ToolActivateButton extends StatelessWidget {
  const ToolActivateButton({
    super.key,
    required this.label,
    required this.icon,
    required this.onTap,
  });

  final String label;
  final IconData icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: EditorPanelMetrics.hPad),
      child: AppButton.primary(
        label: label,
        icon: icon,
        minHeight: EditorPanelMetrics.secondaryRowHeight,
        onTap: onTap,
      ),
    );
  }
}
