import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/adjust/adjust_presets.dart';
import 'package:lens/features/adjust/cards/adjust_card.dart';
import 'package:lens/features/adjust/cards/adjust_cards.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/tool_param_panel.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// One shared slider above a carousel of parameter cards.
///
/// The slider is deliberately bare — no label, no readout — because the
/// active card below already names the parameter and shows its value.
class AdjustPanel extends ConsumerStatefulWidget {
  const AdjustPanel({super.key});
  @override
  ConsumerState<AdjustPanel> createState() => _AdjustPanelState();
}

class _AdjustPanelState extends ConsumerState<AdjustPanel> {
  AdjustCard _selected = kAdjustCards.first;

  @override
  Widget build(BuildContext context) {
    final notifier = ref.read(editorStateProvider.notifier);
    final colors = context.themeColors;

    // Content-sized: the sheet hugs this stack and animates to match when
    // the tool changes, so the padding supplies the sheet's breathing room
    // rather than a fixed-height box.
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: EditorPanelMetrics.bodyPadding,
      ),
      child: ToolParamPanel(
        cards: kAdjustCards,
        selected: _selected,
        notifier: notifier,
        stripKey: const ValueKey('adjustment-strip'),
        cardKeyPrefix: 'adjustment',
        onSelect: (card) => setState(() => _selected = card),
        // The preset menu shares the slider's row.
        sliderTrailing: PopupMenuButton<String>(
          tooltip: 'Adjustment presets',
          icon: Icon(
            LucideIcons.sparkles,
            size: 18,
            color: colors.primary,
          ),
          onSelected: (preset) => notifier.setAdjust(switch (preset) {
            'Punchy' => kAdjustPunchy,
            'Muted' => kAdjustMuted,
            _ => kAdjustNatural,
          }),
          itemBuilder: (_) => [
            for (final preset in ['Natural', 'Punchy', 'Muted'])
              PopupMenuItem(value: preset, child: Text(preset)),
          ],
        ),
      ),
    );
  }
}
