import 'package:flutter/gestures.dart' show kDoubleTapSlop, kDoubleTapTimeout;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// Interactive sun overlay for the rays stage (Task 7.4).
///
/// Rendered [Stack]ed over the preview photo (inside the same uv box, but
/// OUTSIDE the [RepaintBoundary]/hero so return-snapshots stay clean), only
/// while `tool == rays && intensity > 0` (the parent gates this).
///
/// * single tap places the sun at the finger (primary — tap-to-place);
/// * drag (pan) moves the sun with the finger (optional);
/// * double-tap returns the sun to the default (.5, .2).
///
/// Tap/double-tap are disambiguated MANUALLY on tap down/up (no framework
/// double-tap recognizer): a second tap-down within [kDoubleTapTimeout] and
/// [kDoubleTapSlop] arms the reset, which the tap-up then applies instead
/// of placing. Deliberate — the framework recognizer holds single taps
/// until the double-tap timeout (~300ms of tap-to-place latency) and a
/// down-phase place would cost every sun drag a second undo entry. Here a
/// tap-down only records; placement happens on tap-up (immediate — no
/// double-tap recognizer holds the arena) and a drag places inside its own
/// stroke, so a tap is one push and a drag is one entry. A double-tap costs
/// two entries (place + reset); both undo cleanly.
///
/// Every gesture brackets exactly one undo entry via the shared
/// [EditorStateNotifier.beginStroke]/[endStroke] contract (same as the
/// sliders and [SelectiveOverlay]/[BlurOverlay]): a tap-place calls
/// [EditorStateNotifier.setRaysSource] standalone (one push); a drag
/// brackets `beginStroke`/`endStroke` (one entry per drag); the
/// double-tap reset is one push.
///
/// Compare-hold conflict: the preview photo normally flips to the original
/// on raw pointer-down (a [Listener], which gesture arenas do NOT block),
/// so a sun drag would ALSO flip the grade mid-gesture. The parent
/// therefore drops the compare [Listener] whenever this overlay is
/// visible — hold-to-compare is unavailable in rays mode by design (same
/// rule as selective/manual-blur in Tasks 4.5/6.4).
///
/// The sun handle reuses the selective handle language (filled core +
/// 28pt ring, static glow halo) in [ThemeColors]. Tap-to-place works
/// anywhere on the photo, so the 48pt touch target is satisfied by
/// construction; the painted handle itself stays a quiet 28pt visual.
/// The rays are static — no animation: motion answers the gesture, not
/// time (the [RaysPanel] double-tap on a slider owns value resets; the
/// overlay owns the sun position).
class RaysOverlay extends ConsumerStatefulWidget {
  const RaysOverlay({super.key});

  @override
  ConsumerState<RaysOverlay> createState() => _RaysOverlayState();
}

class _RaysOverlayState extends ConsumerState<RaysOverlay> {
  DateTime? _lastDownTime;
  Offset? _lastDownPos;
  bool _doubleArmed = false;

  @override
  Widget build(BuildContext context) {
    final rays = ref.watch(editorStateProvider.select((state) => state.rays));
    final notifier = ref.read(editorStateProvider.notifier);
    final colors = context.themeColors;
    if (rays.intensity <= 0) {
      return const SizedBox.shrink();
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size box = Size(constraints.maxWidth, constraints.maxHeight);
        if (box.isEmpty) return const SizedBox.shrink();
        return Semantics(
          container: true,
          label: 'Sun position',
          hint: 'Tap the photo to place the sun. Double tap resets it.',
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapDown: _onTapDown,
            onTapUp: (details) => _onTapUp(box, notifier, details),
            onPanStart: (details) {
              _clearTapMemory();
              notifier.beginStroke();
              if (context.hapticsEnabled) AppHaptics.selection();
              _placeAt(box, notifier, details.localPosition);
            },
            onPanUpdate: (details) =>
                _placeAt(box, notifier, details.localPosition),
            onPanEnd: (_) => notifier.endStroke(),
            onPanCancel: notifier.endStroke,
            child: CustomPaint(
              painter: _RaysPainter(source: rays.source, color: colors.primary),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }

  void _onTapDown(TapDownDetails details) {
    final DateTime now = DateTime.now();
    final DateTime? lastTime = _lastDownTime;
    final Offset? lastPos = _lastDownPos;
    _doubleArmed =
        lastTime != null &&
        lastPos != null &&
        now.difference(lastTime) < kDoubleTapTimeout &&
        (details.localPosition - lastPos).distance < kDoubleTapSlop;
    _lastDownTime = now;
    _lastDownPos = details.localPosition;
  }

  void _onTapUp(Size box, EditorStateNotifier notifier, TapUpDetails details) {
    if (_doubleArmed) {
      _doubleArmed = false;
      _lastDownTime = null;
      _lastDownPos = null;
      if (context.hapticsEnabled) AppHaptics.selection();
      notifier.setRaysSource(0.5, 0.2);
      return;
    }
    if (context.hapticsEnabled) AppHaptics.selection();
    _placeAt(box, notifier, details.localPosition);
  }

  void _clearTapMemory() {
    _lastDownTime = null;
    _lastDownPos = null;
    _doubleArmed = false;
  }

  static void _placeAt(Size box, EditorStateNotifier notifier, Offset local) {
    if (box.isEmpty) return;
    notifier.setRaysSource(local.dx / box.width, local.dy / box.height);
  }
}

/// Sun handle in [ThemeColors]: a soft static halo, a filled core and a
/// 28pt ring — the selective center-dot language, no animation.
class _RaysPainter extends CustomPainter {
  _RaysPainter({required this.source, required this.color});

  final (double, double) source;
  final Color color;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final Offset center = Offset(
      source.$1 * size.width,
      source.$2 * size.height,
    );
    canvas.drawCircle(
      center,
      22,
      Paint()..color = color.withValues(alpha: 0.18),
    );
    canvas.drawCircle(center, 5, Paint()..color = color);
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..color = color.withValues(alpha: 0.6)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(_RaysPainter oldDelegate) =>
      oldDelegate.source != source || oldDelegate.color != color;
}
