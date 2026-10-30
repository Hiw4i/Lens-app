import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// Intensity slider shell: value in 0..100, double-tap resets.
///
/// Stateless by design — the owner holds the value.
///
/// Haptics: a single [AppHaptics.selection] tick fires when the drag
/// crosses a 5-unit boundary, no matter how many boundaries one update
/// jumps over. A burst of N ticks for N crossed boundaries feels like a
/// buzz and costs N haptic calls per frame; one tick per update is the
/// correct UX (the boundary grid is only a rhythm cue, not a counter).
///
/// [onChangeStart]/[onChangeEnd] mirror [Slider.onChangeStart]/[onChangeEnd]
/// so owners can bracket a drag into one undoable stroke (see
/// `EditorStateNotifier.beginStroke/endStroke`). [displayValue] overrides
/// the trailing readout (e.g. real units like "+0.30"); when null the
/// normalized 0..100 value is shown. [semanticLabel] overrides the
/// screen-reader label; defaults to [label].
///
/// [snapNeutral] (in normalized 0..100 space) is an optional "rest" value
/// the thumb gently locks onto when dragged near it — used for bipolar
/// controls (e.g. temperature -100..+100) so returning to zero is easy.
/// [snapThreshold] is the half-width of that lock zone in normalized units.
class LensSlider extends StatelessWidget {
  const LensSlider({
    super.key,
    required this.value,
    required this.onChanged,
    required this.onReset,
    this.label = 'Intensity',
    this.onChangeStart,
    this.onChangeEnd,
    this.displayValue,
    this.semanticLabel,
    this.snapNeutral,
    this.snapThreshold = 2.0,
    this.showLabel = true,
    this.showValue = true,
  });

  final double value;
  final ValueChanged<double> onChanged;
  final VoidCallback onReset;
  final String label;
  final ValueChanged<double>? onChangeStart;
  final ValueChanged<double>? onChangeEnd;

  /// Overrides the trailing readout; defaults to the 0..100 value.
  final String? displayValue;

  /// Screen-reader label for the slider; defaults to [label].
  final String? semanticLabel;

  /// Optional snap target in normalized 0..100 space.
  final double? snapNeutral;

  /// Half-width of the snap zone in normalized 0..100 units.
  final double snapThreshold;

  /// Whether to show the leading label.
  final bool showLabel;

  /// Whether to show the trailing value readout.
  final bool showValue;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;

    /// One logical value change, bracketed as a single undoable stroke for
    /// semantics/keyboard input.
    void nudge(double delta) {
      final next = (value + delta).clamp(0.0, 100.0);
      if (next == value) return;
      onChangeStart?.call(value);
      onChanged(next);
      onChangeEnd?.call(next);
      if (context.hapticsEnabled) AppHaptics.selection();
    }

    KeyEventResult onKeyEvent(FocusNode node, KeyEvent event) {
      if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
        return KeyEventResult.ignored;
      }
      final int direction;
      if (event.logicalKey == LogicalKeyboardKey.arrowLeft ||
          event.logicalKey == LogicalKeyboardKey.arrowDown) {
        direction = -1;
      } else if (event.logicalKey == LogicalKeyboardKey.arrowRight ||
          event.logicalKey == LogicalKeyboardKey.arrowUp) {
        direction = 1;
      } else {
        return KeyEventResult.ignored;
      }
      // Shift gives the coarse 20-unit step on desktop; the unmodified grid
      // step is the same 5 units the painted scale uses.
      nudge(direction * (HardwareKeyboard.instance.isShiftPressed ? 20 : 5));
      return KeyEventResult.handled;
    }

    /// Keeps the screen-reader readout in the same unit as [displayValue]
    /// (degrees, multipliers, decimals) when it announces a 5-unit step.
    String stepLabel(double delta) {
      final next = (value + delta).clamp(0.0, 100.0);
      final text = displayValue;
      if (text == null) return next.round().toString();
      final match = RegExp(r'^([^\d\-+]*)([+\-]?\d+(?:\.\d+)?)(.*)$')
          .firstMatch(text);
      if (match == null) return next.round().toString();
      final number = match.group(2)!;
      final decimals = number.contains('.') ? number.split('.').last.length : 0;
      return '${match.group(1)}${next.toStringAsFixed(decimals)}'
          '${match.group(3)}';
    }

    return Focus(
      onKeyEvent: onKeyEvent,
      child: Builder(
        builder: (focusContext) => Listener(
          // Clicking/dragging the slider focuses it so desktop arrow keys
          // continue from the value under the pointer.
          onPointerDown: (_) => Focus.of(focusContext).requestFocus(),
          child: GestureDetector(
            onDoubleTap: () {
              if (context.hapticsEnabled) AppHaptics.selection();
              onReset();
            },
            child: Container(
              constraints: const BoxConstraints(
                minHeight: EditorPanelMetrics.sliderHeight,
              ),
              color: Colors.transparent,
              child: Row(
                children: [
                  if (showLabel)
                    SizedBox(
                      width: 76,
                      child: Text(
                        label,
                        style: AppTextStyles.smallDim(context),
                      ),
                    ),
                  Expanded(
                    child: LayoutBuilder(
                      builder: (context, constraints) {
                        final width = constraints.maxWidth;
                        final spacing = width <= 0 ? 1.0 : width / 100.0;
                        return GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onHorizontalDragStart: (_) =>
                              onChangeStart?.call(value),
                          onHorizontalDragUpdate: (details) {
                            if (spacing <= 0) return;
                            final deltaValue = -details.delta.dx / spacing;
                            final next = (value + deltaValue).clamp(0.0, 100.0);
                            // The painted grid is 20 divisions of 5 units:
                            // one tick per 5-unit boundary, not per unit.
                            final crossed =
                                (next / 5).floor() != (value / 5).floor();
                            if (crossed && context.hapticsEnabled) {
                              AppHaptics.selection();
                            }
                            onChanged(next);
                          },
                          onHorizontalDragEnd: (_) => onChangeEnd?.call(value),
                          onHorizontalDragCancel: () =>
                              onChangeEnd?.call(value),
                          child: Semantics(
                            label: semanticLabel ?? label,
                            value: displayValue ?? value.round().toString(),
                            increasedValue: stepLabel(5),
                            decreasedValue: stepLabel(-5),
                            slider: true,
                            onIncrease: () => nudge(5),
                            onDecrease: () => nudge(-5),
                            customSemanticsActions:
                                <CustomSemanticsAction, VoidCallback>{
                                  const CustomSemanticsAction(
                                    label: 'Increase by 20',
                                  ): () =>
                                      nudge(20),
                                  const CustomSemanticsAction(
                                    label: 'Decrease by 20',
                                  ): () =>
                                      nudge(-20),
                                },
                            child: CustomPaint(
                              size: const Size(
                                double.infinity,
                                EditorPanelMetrics.sliderHeight,
                              ),
                              painter: _ScaleSliderPainter(
                                value: value.clamp(0, 100),
                                colors: colors,
                                zeroTick: (((snapNeutral ?? 0) / 5)
                                    .round()
                                    .clamp(0, 20)),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                  if (showValue)
                    SizedBox(
                      width: 52,
                      child: Text(
                        displayValue ?? value.round().toString(),
                        style: AppTextStyles.monoSmall(context),
                        textAlign: TextAlign.end,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _ScaleSliderPainter extends CustomPainter {
  _ScaleSliderPainter({
    required this.value,
    required this.colors,
    required this.zeroTick,
  });

  final double value;
  final AppColors colors;
  final int zeroTick;

  @override
  void paint(Canvas canvas, Size size) {
    final centerY = size.height / 2;
    final center = size.width / 2;
    const divisions = 20.0;
    final spacing = size.width <= 0 ? 1.0 : size.width / divisions;
    final valuePos = value / 5.0;

    // Moving ticks: the scale slides under the fixed indicator.
    final tickPaint = Paint()
      ..strokeWidth = 1.4
      ..strokeCap = StrokeCap.round;
    for (var i = 0; i <= divisions.toInt(); i++) {
      final x = center + (i - valuePos) * spacing;
      if (x < -4 || x > size.width + 4) continue;
      // Fade towards edges.
      final distFromCenter = (x - center).abs() / (size.width / 2);
      final edgeFade = (1.0 - distFromCenter * 0.85).clamp(0.15, 1.0);
      tickPaint.color = colors.secondary.withValues(alpha: 0.65 * edgeFade);
      const tickHeight = 14.0;
      canvas.drawLine(
        Offset(x, centerY - tickHeight / 2),
        Offset(x, centerY + tickHeight / 2),
        tickPaint,
      );
      // Dot above the zero tick for orientation.
      if (i == zeroTick) {
        final dotPaint = Paint()
          ..color = colors.secondary.withValues(alpha: 0.9 * edgeFade);
        canvas.drawCircle(
          Offset(x, centerY - tickHeight / 2 - 6),
          1.8,
          dotPaint,
        );
      }
    }

    // Fixed center indicator (drawn last so ticks never show through it).
    final indicatorPaint = Paint()
      ..color = colors.primary.withValues(alpha: 1.0)
      ..strokeWidth = 2.6
      ..strokeCap = StrokeCap.round;
    canvas.drawLine(
      Offset(center, centerY - 16),
      Offset(center, centerY + 16),
      indicatorPaint,
    );
  }

  @override
  bool shouldRepaint(covariant _ScaleSliderPainter oldDelegate) =>
      oldDelegate.value != value ||
      oldDelegate.colors != colors ||
      oldDelegate.zeroTick != zeroTick;
}
