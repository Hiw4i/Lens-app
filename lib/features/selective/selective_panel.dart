import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/editor_controls.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/tool_panel_pieces.dart';
import 'package:lens/features/editor/widgets/tool_param_panel.dart';
import 'package:lens/features/selective/cards/selective_card.dart';
import 'package:lens/features/selective/cards/selective_cards.dart';
import 'package:lens/features/selective/selective_mask.dart' show SelectiveMode;
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';

/// Selective local-grade panel: a shape row (Radial / Linear / Brush /
/// Off), parameter cards with one shared undoable slider over them,
/// a Strength slider with the Invert toggle sharing that row, and a hint.
///
/// Mask geometry is NOT edited here — radial/linear handles and brush
/// painting live on the photo itself ([SelectiveOverlay]). This panel only
/// drives the grade (exposure/contrast/saturation + strength + invert) and
/// the shape on/off switch. Everything is English, Material3, Lucide icons,
/// themed through the app's `ThemeColors` scope.
class SelectivePanel extends ConsumerStatefulWidget {
  const SelectivePanel({super.key});
  @override
  ConsumerState<SelectivePanel> createState() => _SelectivePanelState();
}

class _SelectivePanelState extends ConsumerState<SelectivePanel> {
  SelectiveCard _selected = kSelectiveCards.first;

  @override
  Widget build(BuildContext context) {
    final selective = ref.watch(
      editorStateProvider.select((state) => state.selective),
    );
    final notifier = ref.read(editorStateProvider.notifier);
    final selected = _selected;
    final active = selective.active;

    // Content-sized: the sheet hugs this stack and animates to match when
    // the tool changes, so the padding supplies the sheet's breathing room
    // rather than a fixed-height box.
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: EditorPanelMetrics.bodyPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EditorModeRow(
            keyPrefix: 'selective-mode',
            entries: [
              (
                'Radial',
                SelectiveMode.radial,
                active && selective.mode == SelectiveMode.radial,
              ),
              (
                'Linear',
                SelectiveMode.linear,
                active && selective.mode == SelectiveMode.linear,
              ),
              (
                'Brush',
                SelectiveMode.brush,
                active && selective.mode == SelectiveMode.brush,
              ),
              ('Off', null, !active),
            ],
            onPick: (mode) {
              if (context.hapticsEnabled) AppHaptics.selection();
              if (mode == null) {
                notifier.setSelectiveActive(false);
              } else {
                notifier.setSelectiveMode(mode as SelectiveMode);
              }
            },
          ),
          const SizedBox(height: EditorPanelMetrics.gap),
          // Grade controls stay inert while the mask is off; the strip keeps
          // its own height so the sheet does not jump between shapes.
          Opacity(
            opacity: active ? 1 : 0.4,
            child: IgnorePointer(
              ignoring: !active,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ToolParamPanel(
                    cards: kSelectiveCards,
                    selected: selected,
                    notifier: notifier,
                    stripKey: const ValueKey('selective-strip'),
                    cardKeyPrefix: 'selective-param',
                    onSelect: (card) => setState(() => _selected = card),
                  ),
                  const SizedBox(height: EditorPanelMetrics.gap),
                  EditorStrengthInvertRow(
                    strengthLabel: 'Strength',
                    strengthValue: selective.strength,
                    onStrengthChanged: notifier.setSelectiveStrength,
                    onStrengthStart: (_) => notifier.beginStroke(),
                    onStrengthEnd: (_) => notifier.endStroke(),
                    onStrengthReset: () => notifier.setSelectiveStrength(100),
                    invert: selective.geometry.invert,
                    onInvertChanged: (value) {
                      if (context.hapticsEnabled) AppHaptics.selection();
                      notifier.setSelectiveInvert(value);
                    },
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: EditorPanelMetrics.gap),
          ToolPanelHint(text: _hint(selective.mode, active)),
        ],
      ),
    );
  }

  static String _hint(SelectiveMode mode, bool active) {
    if (!active) return 'Pick a mask shape to begin';
    return switch (mode) {
      SelectiveMode.radial => 'Drag on the photo to move the mask',
      SelectiveMode.linear => 'Drag on the photo to move the band',
      SelectiveMode.brush => 'Paint on the photo to add to the mask',
    };
  }
}
