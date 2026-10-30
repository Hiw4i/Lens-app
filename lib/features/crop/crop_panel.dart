import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/editor_controls.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/inputs/app_choice_chip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Crop panel: an aspect strip and one straighten slider, nothing else.
///
/// Deliberately two rows and no headers. The window speaks for itself on the
/// photo, so the panel only carries what cannot be expressed by dragging:
/// the aspect lock, the numeric angle, and the two discrete actions (quarter
/// turn, reset).
///
/// Row 1 is a scrolling strip of ratios; row 2 is the rotate / straighten /
/// reset bar. The strip scrolls because eight ratios cannot fit on a phone
/// without shrinking the chips past a comfortable tap target.
class CropPanel extends ConsumerWidget {
  const CropPanel({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final CropSpec spec = ref.watch(editorStateProvider.select((s) => s.crop));
    final double aspect = ref.watch(
      editorStateProvider.select((s) => s.photoAspect),
    );
    final notifier = ref.read(editorStateProvider.notifier);
    final Size source = CropSpec.nominalSource(aspect);

    return Padding(
      padding: const EdgeInsets.symmetric(
        vertical: EditorPanelMetrics.bodyPadding,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          EditorFadingRow(
            height: 32,
            gradientFraction: 0.1,
            padding: const EdgeInsets.symmetric(
              horizontal: EditorPanelMetrics.hPad,
            ),
            child: Row(
              children: [
                for (final ratio in CropRatio.values)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: _RatioChip(
                      ratio: ratio,
                      selected: spec.ratio == ratio.value,
                      onTap: () {
                        if (context.hapticsEnabled) {
                          AppHaptics.selection();
                        }
                        notifier.setCropRatio(ratio.value, source);
                      },
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: EditorPanelMetrics.gap),
          Padding(
            padding: const EdgeInsets.symmetric(
              horizontal: EditorPanelMetrics.hPad,
            ),
            child: Row(
              children: [
                _ActionButton(
                  // A square turning inside a frame: the old circular arrow
                  // was a twin of the reset button's and the two read as the
                  // same control.
                  icon: LucideIcons.rotateCwSquare,
                  tooltip: 'Rotate 90°',
                  onTap: () {
                    if (context.hapticsEnabled) AppHaptics.selection();
                    notifier.rotateCropQuarter(source);
                  },
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: LensSlider(
                    label: 'Straighten',
                    semanticLabel: 'Straighten angle',
                    // The slider is bipolar around a centre detent: 50 is
                    // level, and the detent makes returning to it easy.
                    value:
                        50 + spec.angleDegrees / CropSpec.kMaxAngleDegrees * 50,
                    displayValue: _angleLabel(spec.angleDegrees),
                    snapNeutral: 50,
                    onChanged: (next) => notifier.setCropAngle(
                      (next - 50) / 50 * CropSpec.kMaxAngleDegrees,
                      source,
                    ),
                    // Double-tap levels the photo, matching the bipolar
                    // sliders everywhere else in the editor.
                    onReset: () => notifier.setCropAngle(0, source),
                  ),
                ),
                const SizedBox(width: 10),
                _ActionButton(
                  icon: LucideIcons.rotateCcw,
                  tooltip: 'Reset crop',
                  onTap: spec.isDefault
                      ? null
                      : () {
                          if (context.hapticsEnabled) AppHaptics.selection();
                          notifier.clearCrop();
                        },
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _angleLabel(double degrees) {
    if (degrees == 0) return '0°';
    final double rounded = degrees.roundToDouble();
    return '${rounded > 0 ? '+' : ''}${rounded.toStringAsFixed(0)}°';
  }
}

class _RatioChip extends StatelessWidget {
  const _RatioChip({
    required this.ratio,
    required this.selected,
    required this.onTap,
  });

  final CropRatio ratio;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    // The shared choice chip with the strip's horizontal-only padding; the
    // key stays on the chip so the panel tests keep addressing ratios.
    return AppChoiceChip(
      key: ValueKey('crop-ratio-${ratio.label}'),
      label: ratio.label,
      selected: selected,
      onTap: onTap,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      // Center the label in the pinned 32px strip row (safe here: the row
      // gives tight height and the scroll width is unbounded).
      alignment: Alignment.center,
    );
  }
}

class _ActionButton extends StatelessWidget {
  const _ActionButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final bool enabled = onTap != null;
    return Tooltip(
      message: tooltip,
      child: Semantics(
        button: true,
        enabled: enabled,
        label: tooltip,
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            child: Container(
              width: 40,
              height: 40,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                border: Border.all(color: colors.border),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Icon(
                icon,
                size: 18,
                color: enabled ? colors.primary : colors.secondary,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
