import 'dart:async';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Floating editor chrome: the translucent pill surface the top-bar actions
/// sit on, and the undo/redo affordances.
///
/// Extracted from the editor shell so the shell file stays layout-only;
/// these widgets own their own rebuild scope via Riverpod `select`s.
///
/// Floating chrome pill. The sigma-18 backdrop blur is expensive on
/// mid-range GPUs, so it is tied to the UI profile exactly like AppButton's
/// glass surfaces: Performance/Balanced fall back to the opaque surface
/// colour instead of stacking three blurs.
class EditorFloatingPill extends StatelessWidget {
  const EditorFloatingPill({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final blurEnabled = context.uiPerformance.blurEnabled;
    final radius = BorderRadius.circular(16);
    final Widget surface = Container(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 2),
      decoration: BoxDecoration(
        color: blurEnabled ? colors.surfaceTranslucent : colors.surface,
        border: Border.all(color: colors.border),
        borderRadius: radius,
      ),
      child: child,
    );
    if (!blurEnabled) return ClipRRect(borderRadius: radius, child: surface);
    return ClipRRect(
      borderRadius: radius,
      child: BackdropFilter(
        filter: ui.ImageFilter.blur(sigmaX: 18, sigmaY: 18),
        child: surface,
      ),
    );
  }
}

/// AppBar undo/redo: rebuilds only when the history depths change —
/// slider ticks (adjust-only) skip this subtree entirely.
class EditorUndoActions extends ConsumerWidget {
  const EditorUndoActions({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Every [EditorTool] is an editor tool, so the undo affordance is
    // always visible; the depths below gate its enabled state.
    final canUndo = ref.watch(
      editorStateProvider.select((s) => s.undoDepth > 0),
    );
    final canRedo = ref.watch(
      editorStateProvider.select((s) => s.redoDepth > 0),
    );
    final notifier = ref.read(editorStateProvider.notifier);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        EditorHistoryStepButton(
          icon: LucideIcons.undo2,
          semanticLabel: 'Undo',
          enabled: canUndo,
          step: notifier.undo,
          canStep: () => notifier.canUndo,
        ),
        EditorHistoryStepButton(
          icon: LucideIcons.redo2,
          semanticLabel: 'Redo',
          enabled: canRedo,
          step: notifier.redo,
          canStep: () => notifier.canRedo,
        ),
      ],
    );
  }
}

/// One undo/redo affordance. A tap steps the history once; holding the
/// button REPLAYS it — one step every [_replayInterval] until the finger
/// lifts or the stack runs dry. Holding Undo therefore rolls the whole
/// grade back to the untouched photo (the button then greys out: nothing
/// left to undo) and holding Redo walks the changes back in.
///
/// The outer long-press recognizer wins the gesture arena after
/// kLongPressTimeout, cancelling the button's tap, so one press never
/// fires both paths. The button carries no [Tooltip]: a tooltip's own
/// long-press trigger sits deeper in the tree and would win that arena,
/// swallowing the hold — [semanticLabel] keeps the affordance accessible
/// without a competing gesture.
class EditorHistoryStepButton extends StatefulWidget {
  const EditorHistoryStepButton({
    super.key,
    required this.icon,
    required this.semanticLabel,
    required this.enabled,
    required this.step,
    required this.canStep,
  });

  final IconData icon;
  final String semanticLabel;

  /// Mirrors the history depth; false greys the button out and stops a
  /// running replay.
  final bool enabled;
  final VoidCallback step;

  /// Whether one more [step] is available right now. The replay loop polls
  /// this and stops itself when the history runs dry.
  final bool Function() canStep;

  @override
  State<EditorHistoryStepButton> createState() =>
      _EditorHistoryStepButtonState();
}

class _EditorHistoryStepButtonState extends State<EditorHistoryStepButton> {
  /// One history step per tick: fast enough to feel like scrubbing, slow
  /// enough for each grade to read on the preview.
  static const Duration _replayInterval = Duration(milliseconds: 90);

  Timer? _replay;

  @override
  void didUpdateWidget(covariant EditorHistoryStepButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled) _stopReplay();
  }

  @override
  void dispose() {
    _stopReplay();
    super.dispose();
  }

  void _startReplay() {
    if (context.hapticsEnabled) AppHaptics.doubleTap();
    _stopReplay();
    _replayStep();
    _replay = Timer.periodic(_replayInterval, (_) => _replayStep());
  }

  void _replayStep() {
    if (!widget.canStep()) {
      _stopReplay();
      return;
    }
    widget.step();
  }

  void _stopReplay() {
    _replay?.cancel();
    _replay = null;
  }

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onLongPress: widget.enabled ? _startReplay : null,
      onLongPressEnd: (_) => _stopReplay(),
      onLongPressCancel: _stopReplay,
      child: AppButton.iconGhost(
        icon: widget.icon,
        semanticLabel: widget.semanticLabel,
        onTap: widget.enabled
            ? () {
                if (context.hapticsEnabled) AppHaptics.selection();
                widget.step();
              }
            : null,
      ),
    );
  }
}
