import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/features/filters/filter_strip.dart';

/// Filters-mode control surface: live [FilterStrip] + strength slider.
///
/// Strength drags bracket into exactly one undo entry via
/// [EditorStateNotifier.beginStroke]/[endStroke] (same contract as the
/// Adjust sliders); double-tap resets to 100.
class FiltersPanel extends ConsumerWidget {
  const FiltersPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final filterId = ref.watch(editorStateProvider.select((s) => s.filterId));
    final strength = ref.watch(
      editorStateProvider.select((s) => s.filterStrength),
    );
    final bytes = ref.watch(editorStateProvider.select((s) => s.previewBytes));
    final notifier = ref.read(editorStateProvider.notifier);
    // Content-sized like every other panel.
    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: EditorPanelMetrics.bodyPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          FilterStrip(
            selectedId: filterId,
            previewBytes: bytes,
            onSelect: notifier.setFilterId,
          ),
          const SizedBox(height: EditorPanelMetrics.gap),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: EditorPanelMetrics.hPad,
            ),
            child: LensSlider(
              label: 'Strength',
              semanticLabel: 'Filter strength',
              value: strength,
              displayValue: strength.round().toString(),
              onChanged: notifier.setFilterStrength,
              onChangeStart: (_) => notifier.beginStroke(),
              onChangeEnd: (_) => notifier.endStroke(),
              onReset: () => notifier.setFilterStrength(100),
            ),
          ),
        ],
      ),
    );
  }
}