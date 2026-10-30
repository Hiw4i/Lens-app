import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart'
    show EditorState, EditorStateNotifier, editorStateProvider;
import 'package:lens/features/editor/logic/tool_card.dart';
import 'package:lens/features/editor/widgets/editor_controls.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';

/// The shared parameter block: one undoable slider above a strip of cards.
///
/// Adjust, Blur, Rays and Selective all had their own copy of this exact
/// layout (a [LensSlider] over an [EditorParamStrip]); the panel is now
/// written once and each tool only supplies its [ToolCard] list.
///
/// The card owns everything tool-specific: the range, the value, the
/// label, the icon and what a tap writes. The panel only maps the card's
/// range onto the slider's 0..100 space and routes the taps.
class ToolParamPanel<T extends ToolCard> extends ConsumerWidget {
  const ToolParamPanel({
    super.key,
    required this.cards,
    required this.selected,
    required this.onSelect,
    required this.notifier,
    this.stripKey,
    this.cardKeyPrefix,
    this.sliderTrailing,
  });

  /// The cards of this tool, in strip order.
  final List<T> cards;

  /// The card the slider currently drives.
  final T selected;

  /// Called when the user picks another card.
  final ValueChanged<T> onSelect;

  /// The editor notifier (the panel only routes writes through it).
  final EditorStateNotifier notifier;

  /// Stable key of the strip, so switching tools replaces its scroll
  /// position instead of inheriting the previous tool's offset.
  final Key? stripKey;

  /// Prefix of the per-card keys (`<prefix>-<card id>`).
  final String? cardKeyPrefix;

  /// Optional control that shares the slider's row (Adjust puts its
  /// preset menu there).
  final Widget? sliderTrailing;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final EditorState state = ref.watch(editorStateProvider);
    final T card = selected;
    final double min = card.min;
    final double max = card.max;
    final double span = max - min;
    final double normalized =
        span <= 0 ? 0 : (card.value(state) - min) / span * 100;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: EditorPanelMetrics.hPad,
          ),
          child: Row(
            children: [
              Expanded(
                child: LensSlider(
                  key: ValueKey(card.id),
                  label: card.label,
                  semanticLabel: card.label,
                  showLabel: card.showSliderLabel,
                  showValue: card.showSliderValue,
                  value: normalized,
                  displayValue: card.showSliderValue
                      ? card.display(state)
                      : null,
                  snapNeutral: card.snapToNeutral && span > 0
                      ? (0 - min) / span * 100
                      : null,
                  onChanged: (next) => card.set(
                    notifier,
                    min + next / 100 * span,
                  ),
                  onChangeStart: (_) => notifier.beginStroke(),
                  onChangeEnd: (_) => notifier.endStroke(),
                  onReset: () => card.reset(notifier),
                ),
              ),
              if (sliderTrailing != null) ...[
                const SizedBox(width: 8),
                sliderTrailing!,
              ],
            ],
          ),
        ),
        const SizedBox(height: EditorPanelMetrics.gap),
        EditorParamStrip(
          stripKey: stripKey,
          itemCount: cards.length,
          itemBuilder: (context, index) {
            final T item = cards[index];
            final double itemValue = item.value(state);
            final bool isSelected = item.id == card.id;
            return EditorParamCard(
              key: ValueKey(
                cardKeyPrefix == null ? item.id : '$cardKeyPrefix-${item.id}',
              ),
              label: item.label,
              icon: item.icon,
              value: itemValue == 0 && !item.alwaysShowValue
                  ? null
                  : item.display(state),
              active: isSelected,
              onTap: () {
                if (isSelected) {
                  // A second tap on a live parameter clears it; a card
                  // that does not opt in just stays selected.
                  if (item.resetOnSecondTap && itemValue != 0) {
                    item.set(notifier, 0);
                    if (context.hapticsEnabled) AppHaptics.selection();
                  }
                  return;
                }
                notifier.endStroke();
                if (context.hapticsEnabled) AppHaptics.selection();
                onSelect(item);
                // The strip is horizontal: the picked card can land
                // off-screen, so reveal it once the frame that rebuilt
                // the strip has been laid out.
                WidgetsBinding.instance.addPostFrameCallback((_) {
                  if (!context.mounted) return;
                  Scrollable.ensureVisible(
                    context,
                    alignment: .5,
                    duration: context.uiPerformance.motionDuration(
                      const Duration(milliseconds: 180),
                    ),
                    curve: Curves.easeOutCubic,
                  );
                });
              },
            );
          },
        ),
      ],
    );
  }
}
