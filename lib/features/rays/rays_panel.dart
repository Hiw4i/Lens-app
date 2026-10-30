import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/logic/tool_card.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/tool_panel_pieces.dart';
import 'package:lens/features/editor/widgets/tool_param_panel.dart';
import 'package:lens/features/rays/cards/rays_cards.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Tyndall-rays panel: a 1-tap [AppButton.primary] ("Add light") while off,
/// parameter cards with one shared undoable slider over them while on,
/// and a placement hint.
///
/// The sun itself lives on the photo ([RaysOverlay]): a single tap places
/// it (primary), a drag moves it (optional), a double-tap returns it to
/// the default (.5, .2). This panel only drives
/// intensity/length/warmth/density. Everything is English, Material3
/// (Filled/Outlined/TextButton), Lucide icons, themed through the app's
/// `ThemeColors` scope.
class RaysPanel extends ConsumerStatefulWidget {
  const RaysPanel({super.key});
  @override
  ConsumerState<RaysPanel> createState() => _RaysPanelState();
}

class _RaysPanelState extends ConsumerState<RaysPanel> {
  SliderValueCard _selected = kRaysCards.first;

  @override
  Widget build(BuildContext context) {
    final rays = ref.watch(editorStateProvider.select((state) => state.rays));
    final notifier = ref.read(editorStateProvider.notifier);
    final selected = _selected;
    final active = rays.intensity > 0;

    Widget controls() => Opacity(
      opacity: active ? 1 : 0.4,
      child: IgnorePointer(
        ignoring: !active,
        child: ToolParamPanel(
          cards: kRaysCards,
          selected: selected,
          notifier: notifier,
          stripKey: const ValueKey('rays-strip'),
          cardKeyPrefix: 'rays-param',
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
          if (!active) ...[
            ToolActivateButton(
              label: 'Add light',
              icon: LucideIcons.sun,
              onTap: () {
                if (context.hapticsEnabled) AppHaptics.medium();
                notifier.applyRaysOneTap();
              },
            ),
            const SizedBox(height: EditorPanelMetrics.gap),
          ],
          controls(),
          const SizedBox(height: EditorPanelMetrics.gap),
          ToolPanelHint(
            text: active
                ? 'Tap photo to place the sun · Double-tap resets'
                : 'Add light, then tap the photo to place the sun',
          ),
        ],
      ),
    );
  }
}