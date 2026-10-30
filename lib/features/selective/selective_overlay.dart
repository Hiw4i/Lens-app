import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/selective/selective_mask.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// Interactive selective-mask overlay (Task 4.5).
///
/// Rendered [Stack]ed over the preview photo (inside the same uv box, but
/// OUTSIDE the [RepaintBoundary]/hero so return-snapshots stay clean), only
/// while `tool == selective && selective.active` (the parent gates this).
///
/// * radial: drag (pan) moves the center, pinch (scale) resizes the disc;
/// * linear: drag moves the band center (pinch is ignored);
/// * brush: finger paints dab points in preview-box uv coordinates.
///
/// Every gesture brackets exactly one undo entry via the shared
/// [EditorStateNotifier.beginStroke]/[endStroke] contract (same as the
/// sliders); brush painting relies on [EditorStateNotifier.addBrushPoint],
/// which live-updates without touching history until [endStroke].
///
/// Compare-hold conflict: the preview photo normally flips to the original
/// on raw pointer-down (a [Listener], which gesture arenas do NOT block),
/// so a mask drag would ALSO flip the grade mid-gesture. The parent
/// therefore drops the compare [Listener] whenever this overlay is
/// visible — hold-to-compare is unavailable in selective mode by design.
///
/// [aspect] is the preview width/height ratio (same value the parent sizes
/// the box with). It is reported back through `setSelectiveAspect`
/// post-frame — the setter is history-free and a no-op when equal, so this
/// converges in one frame and never fights undo.
class SelectiveOverlay extends ConsumerStatefulWidget {
  const SelectiveOverlay({super.key, required this.aspect});

  /// Preview width/height ratio driving the radial ellipse.
  final double aspect;

  @override
  ConsumerState<SelectiveOverlay> createState() => _SelectiveOverlayState();
}

class _SelectiveOverlayState extends ConsumerState<SelectiveOverlay> {
  double? _scaleBase;
  (double, double)? _centerBase;
  Offset _drag = Offset.zero;

  @override
  Widget build(BuildContext context) {
    final selective = ref.watch(
      editorStateProvider.select((state) => state.selective),
    );
    final notifier = ref.read(editorStateProvider.notifier);
    final colors = context.themeColors;
    if (widget.aspect > 0 && widget.aspect != selective.geometry.aspect) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          ref
              .read(editorStateProvider.notifier)
              .setSelectiveAspect(widget.aspect);
        }
      });
    }
    if (!selective.active) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size box = Size(constraints.maxWidth, constraints.maxHeight);
        final painter = _SelectivePainter(
          selective: selective,
          primary: colors.primary,
        );
        if (selective.mode == SelectiveMode.brush) {
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
            child: CustomPaint(
              painter: painter,
              child: const SizedBox.expand(),
            ),
          );
        }
        final SelectiveGeometry geometry = selective.geometry;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (_) {
            notifier.beginStroke();
            if (context.hapticsEnabled) AppHaptics.selection();
            _scaleBase = geometry.radius;
            _centerBase = geometry.center;
            _drag = Offset.zero;
          },
          onScaleUpdate: (details) {
            if (box.isEmpty) return;
            // Accumulate locally instead of adding each delta to `geometry`:
            // that closure can be a frame stale during a fast drag, so using
            // only the newest delta silently drops the earlier movement.
            _drag += details.focalPointDelta;
            final (double, double) base = _centerBase ?? geometry.center;
            notifier.setSelectiveCenter(
              base.$1 + _drag.dx / box.width,
              base.$2 + _drag.dy / box.height,
            );
            if (selective.mode == SelectiveMode.radial) {
              final double? startRadius = _scaleBase;
              if (startRadius != null) {
                notifier.setSelectiveRadius(startRadius * details.scale);
              }
            }
          },
          onScaleEnd: (_) {
            _scaleBase = null;
            _centerBase = null;
            notifier.endStroke();
          },
          child: CustomPaint(painter: painter, child: const SizedBox.expand()),
        );
      },
    );
  }

  static void _paintAt(Size box, EditorStateNotifier notifier, Offset local) {
    if (box.isEmpty) return;
    notifier.addBrushPoint(local.dx / box.width, local.dy / box.height);
  }
}

/// Mask handles in [ThemeColors]: center dot + radius ring (radial),
/// center dot + gradient line with width edges (linear), faint stroke
/// spines (brush). Minimum per spec: center point + radius ring.
class _SelectivePainter extends CustomPainter {
  _SelectivePainter({required this.selective, required this.primary});

  final SelectiveState selective;
  final Color primary;

  @override
  void paint(Canvas canvas, Size size) {
    if (size.isEmpty) return;
    final SelectiveGeometry g = selective.geometry;
    final Offset center = Offset(
      g.center.$1 * size.width,
      g.center.$2 * size.height,
    );
    switch (selective.mode) {
      case SelectiveMode.radial:
        // uv radius r maps to a pixel circle of r * height: the shader
        // penalizes x by aspect (w/h), so dx_px = r * w / aspect = r * h.
        final double radiusPx = g.radius * size.height;
        canvas.drawCircle(
          center,
          radiusPx,
          Paint()
            ..color = primary
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.5,
        );
        _dot(canvas, center);
      case SelectiveMode.linear:
        final double a = g.angle * math.pi / 180.0;
        final Offset grad = Offset(math.cos(a), math.sin(a));
        final double span = size.width + size.height;
        canvas.drawLine(
          center - grad * span,
          center + grad * span,
          Paint()
            ..color = primary.withValues(alpha: 0.6)
            ..strokeWidth = 1.5,
        );
        // Band edges: perpendicular of the gradient at +/- width in uv,
        // mapped to pixels per axis; the band direction in pixel space.
        final Offset normal = Offset(-math.sin(a), math.cos(a));
        final Offset band = Offset(
          -grad.dy * size.width,
          grad.dx * size.height,
        );
        final double bandLen = band.distance;
        if (bandLen > 1e-6) {
          final Offset unit = band / bandLen;
          for (final double sign in <double>[-1.0, 1.0]) {
            final Offset edge = Offset(
              center.dx + sign * normal.dx * g.width * size.width,
              center.dy + sign * normal.dy * g.width * size.height,
            );
            canvas.drawLine(
              edge - unit * span,
              edge + unit * span,
              Paint()
                ..color = primary.withValues(alpha: 0.35)
                ..strokeWidth = 1,
            );
          }
        }
        _dot(canvas, center);
      case SelectiveMode.brush:
        final Paint paint = Paint()
          ..color = primary.withValues(alpha: 0.85)
          ..strokeWidth = 3
          ..strokeCap = StrokeCap.round
          ..strokeJoin = StrokeJoin.round;
        for (final stroke in selective.strokes) {
          if (stroke.points.isEmpty) continue;
          final List<Offset> pts = <Offset>[
            for (var i = 0; i < stroke.points.length; i++)
              Offset(
                stroke.points[i].$1 * size.width,
                stroke.points[i].$2 * size.height,
              ),
          ];
          if (pts.length == 1) {
            canvas.drawCircle(pts.single, 2, paint);
          } else {
            canvas.drawPoints(ui.PointMode.polygon, pts, paint);
          }
        }
    }
  }

  void _dot(Canvas canvas, Offset center) {
    // 28pt touch handle language: small filled core + 28pt ring.
    canvas.drawCircle(center, 5, Paint()..color = primary);
    canvas.drawCircle(
      center,
      14,
      Paint()
        ..color = primary.withValues(alpha: 0.5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1,
    );
  }

  @override
  bool shouldRepaint(_SelectivePainter oldDelegate) =>
      oldDelegate.selective != selective || oldDelegate.primary != primary;
}
