import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/blur/cards/blur_cards.dart';
import 'package:lens/features/blur/subject_mask.dart' show SubjectSource;
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/logic/tool_card.dart';
import 'package:lens/features/editor/widgets/editor_controls.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/tool_panel_pieces.dart';
import 'package:lens/features/editor/widgets/tool_param_panel.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Background-blur panel: a source row (Auto/Manual/Off), parameter cards
/// with one shared undoable slider over them, a Strength slider with
/// the Invert toggle sharing that row, and a one-line hint.
///
/// Manual painting itself lives on the photo ([BlurOverlay]); this panel
/// only drives radius/feather/strength/invert and the source switch.
/// Everything is English, Material3, Lucide icons, themed through the app's
/// `ThemeColors` scope.
class BlurPanel extends ConsumerStatefulWidget {
  const BlurPanel({super.key});
  @override
  ConsumerState<BlurPanel> createState() => _BlurPanelState();
}

class _BlurPanelState extends ConsumerState<BlurPanel> {
  SliderValueCard _selected = kBlurCards.first;

  @override
  Widget build(BuildContext context) {
    final blur = ref.watch(editorStateProvider.select((state) => state.blur));
    final notifier = ref.read(editorStateProvider.notifier);
    final selected = _selected;
    final active = blur.strength > 0;

    // The radius/feather controls stay inert (and dimmed) while blur is
    // off; the strip keeps its height so the sheet does not jump.
    Widget controls() => Opacity(
      opacity: active ? 1 : 0.4,
      child: IgnorePointer(
        ignoring: !active,
        child: ToolParamPanel(
          cards: kBlurCards,
          selected: selected,
          notifier: notifier,
          stripKey: const ValueKey('blur-strip'),
          cardKeyPrefix: 'blur-param',
          onSelect: (card) => setState(() => _selected = card),
        ),
      ),
    );

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
            keyPrefix: 'blur-mode',
            entries: [
              (
                'Auto',
                SubjectSource.auto,
                active && blur.source == SubjectSource.auto,
              ),
              (
                'Manual',
                SubjectSource.manual,
                active && blur.source == SubjectSource.manual,
              ),
              ('Off', null, !active),
            ],
            onPick: (source) {
              if (context.hapticsEnabled) AppHaptics.selection();
              if (source == null) {
                notifier.clearBlur();
              } else {
                notifier.setBlurSource(source as SubjectSource);
              }
            },
          ),
          const SizedBox(height: EditorPanelMetrics.gap),
          controls(),
          const SizedBox(height: EditorPanelMetrics.gap),
          // Strength/Invert take the row the one-tap button uses while blur
          // is off, so both states have the same stack height and the sheet
          // never jumps when the mask turns on.
          if (active)
            EditorStrengthInvertRow(
              strengthLabel: 'Strength',
              strengthValue: blur.strength,
              onStrengthChanged: notifier.setBlurStrength,
              onStrengthStart: (_) => notifier.beginStroke(),
              onStrengthEnd: (_) => notifier.endStroke(),
              onStrengthReset: notifier.clearBlur,
              invert: blur.invert,
              onInvertChanged: (value) {
                if (context.hapticsEnabled) AppHaptics.selection();
                notifier.setBlurInvert(value);
              },
            )
          else
            ToolActivateButton(
              label: 'Blur background',
              icon: LucideIcons.aperture,
              onTap: () {
                if (context.hapticsEnabled) AppHaptics.medium();
                notifier.applyBlurOneTap();
              },
            ),
          const SizedBox(height: EditorPanelMetrics.gap),
          ToolPanelHint(text: _hint(blur.source, active, blur.strokes.isEmpty)),
        ],
      ),
    );
  }

  static String _hint(SubjectSource source, bool active, bool noStrokes) {
    if (!active) return 'Tap Blur background or pick a mask source';
    return switch (source) {
      SubjectSource.auto => 'Auto mask blurs the background',
      SubjectSource.manual when noStrokes =>
        'Paint on the photo to mark the subject',
      SubjectSource.manual => 'Paint on the photo to add to the mask',
    };
  }
}
