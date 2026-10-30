import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/blur/subject_mask.dart' show SubjectSource;
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';

/// Manual-mask paint overlay for the blur stage (Task 6.4).
///
/// Rendered [Stack]ed over the preview photo (inside the same uv box, but
/// OUTSIDE the [RepaintBoundary]/hero so return-snapshots stay clean), only
/// while `tool == blur && source == manual && strength > 0` (the parent
/// gates this).
///
/// Deliberately minimal: finger pan paints dab points in preview-box uv
/// coordinates via [EditorStateNotifier.addBlurBrushPoint]. No handle
/// painting — the mask is visible through the blur itself (spec: skip
/// stroke visualization). Every gesture brackets exactly one undo entry
/// via the shared [EditorStateNotifier.beginStroke]/[endStroke] contract
/// (same as the sliders and [SelectiveOverlay]); [addBlurBrushPoint]
/// live-updates without touching history until [endStroke].
///
/// Compare-hold conflict: the preview photo normally flips to the original
/// on raw pointer-down (a [Listener], which gesture arenas do NOT block),
/// so a paint drag would ALSO flip the grade mid-gesture. The parent
/// therefore drops the compare [Listener] whenever this overlay is
/// visible — hold-to-compare is unavailable in manual-blur mode by design
/// (same rule as selective mode in Task 4.5).
class BlurOverlay extends ConsumerWidget {
  const BlurOverlay({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final blur = ref.watch(editorStateProvider.select((state) => state.blur));
    final notifier = ref.read(editorStateProvider.notifier);
    if (blur.source != SubjectSource.manual || blur.strength <= 0) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size box = Size(constraints.maxWidth, constraints.maxHeight);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onPanStart: (details) {
            notifier.beginStroke();
            if (context.hapticsEnabled) AppHaptics.selection();
            _paintAt(box, notifier, details.localPosition);
          },
          onPanUpdate: (details) =>
              _paintAt(box, notifier, details.localPosition),
          onPanEnd: (_) => notifier.endStroke(),
          onPanCancel: notifier.endStroke,
          child: const SizedBox.expand(),
        );
      },
    );
  }

  static void _paintAt(Size box, EditorStateNotifier notifier, Offset local) {
    if (box.isEmpty) return;
    notifier.addBlurBrushPoint(local.dx / box.width, local.dy / box.height);
  }
}
