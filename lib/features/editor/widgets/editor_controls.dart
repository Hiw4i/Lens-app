import 'package:fading_edge_scrollview/fading_edge_scrollview.dart';
import 'package:flutter/material.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/lens_slider.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Compact parameter card: icon (or the live value) over a one-line label
/// with an underline bar for the active entry.
///
/// Shared by the Adjust / Selective / Blur / Rays carousels so the four
/// panels stay pixel-identical in rhythm and height.
class EditorParamCard extends StatelessWidget {
  const EditorParamCard({
    super.key,
    required this.label,
    required this.icon,
    required this.active,
    required this.onTap,
    this.value,
  });

  final String label;
  final IconData icon;

  /// Drives the filled background, the bold label and the underline bar.
  final bool active;

  /// Current value; when null or empty the [icon] is shown instead.
  final String? value;

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final hasValue = (value ?? '').isNotEmpty;
    final duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 140),
    );
    return SizedBox(
      width: EditorPanelMetrics.cardWidth,
      child: Semantics(
        selected: active,
        value: value,
        button: true,
        child: AnimatedContainer(
          duration: duration,
          decoration: BoxDecoration(
            color: active ? colors.surfaceBright : Colors.transparent,
            borderRadius: BorderRadius.circular(14),
          ),
          child: TextButton(
            onPressed: onTap,
            style: TextButton.styleFrom(
              foregroundColor: colors.primary,
              backgroundColor: Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
              minimumSize: const Size(
                EditorPanelMetrics.cardWidth,
                EditorPanelMetrics.cardHeight,
              ),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(14),
              ),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                if (hasValue)
                  Text(
                    value!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                      height: 1.1,
                      color: colors.primary,
                    ),
                  )
                else
                  Icon(icon, size: 20),
                const SizedBox(height: 4),
                AnimatedDefaultTextStyle(
                  duration: duration,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.15,
                    fontWeight: active ? FontWeight.w600 : FontWeight.w400,
                    color: colors.primary,
                  ),
                  child: Text(
                    label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    textAlign: TextAlign.center,
                  ),
                ),
                const SizedBox(height: 3),
                AnimatedContainer(
                  duration: duration,
                  height: 2,
                  width: 16,
                  decoration: BoxDecoration(
                    color: active ? colors.primary : Colors.transparent,
                    borderRadius: BorderRadius.circular(1),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Horizontal carousel of [EditorParamCard]s with a persistent scroll
/// position.
///
/// Owning the [ScrollController] here (rather than creating one per build)
/// keeps the offset across rebuilds and disposes it exactly once — the
/// previous version rebuilt a controller on every build, so the strip
/// snapped back to the start whenever the selected card changed.
class EditorParamStrip extends StatefulWidget {
  const EditorParamStrip({
    super.key,
    required this.itemCount,
    required this.itemBuilder,
    this.stripKey,
  });

  final int itemCount;
  final NullableIndexedWidgetBuilder itemBuilder;

  /// Stable key so switching tools replaces the scrollable's state.
  final Key? stripKey;

  @override
  State<EditorParamStrip> createState() => _EditorParamStripState();
}

class _EditorParamStripState extends State<EditorParamStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: EditorPanelMetrics.cardHeight,
      child: FadingEdgeScrollView.fromScrollView(
        gradientFractionOnStart: 0.15,
        gradientFractionOnEnd: 0.15,
        child: ListView.separated(
          key: widget.stripKey,
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: EditorPanelMetrics.hPad,
          ),
          itemCount: widget.itemCount,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          // A list builder's context belongs to the SLIVER, not to the card
          // it builds: revealing THAT context scrolls the strip to the wrong
          // place and pushes the selected card off the screen. The Builder
          // hands the panel the card's own context, so a selected card can
          // be centred in the strip.
          itemBuilder: (context, index) => Builder(
            builder: (itemContext) =>
                widget.itemBuilder(itemContext, index) ?? const SizedBox.shrink(),
          ),
        ),
      ),
    );
  }
}

/// Horizontal single-child strip with fading edges and a persistent offset.
///
/// The controller is owned here for two reasons: the scroll position must
/// survive rebuilds, and [FadingEdgeScrollView.fromSingleChildScrollView]
/// throws in `build` when its child has no controller. Keeping that contract
/// in one place means a new strip cannot reintroduce the crop panel's red
/// error widget.
class EditorFadingRow extends StatefulWidget {
  const EditorFadingRow({
    super.key,
    required this.height,
    required this.child,
    this.padding = EdgeInsets.zero,
    this.gradientFraction = 0.12,
  });

  final double height;
  final Widget child;
  final EdgeInsetsGeometry padding;
  final double gradientFraction;

  @override
  State<EditorFadingRow> createState() => _EditorFadingRowState();
}

class _EditorFadingRowState extends State<EditorFadingRow> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: widget.height,
      child: FadingEdgeScrollView.fromSingleChildScrollView(
        gradientFractionOnStart: widget.gradientFraction,
        gradientFractionOnEnd: widget.gradientFraction,
        child: SingleChildScrollView(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: widget.padding,
          child: widget.child,
        ),
      ),
    );
  }
}

/// Segmented source/shape row (Auto / Manual / Off, Radial / Linear / Brush).
///
/// [entries] are `(label, value, selected)`; `onPick` receives the value, or
/// null for the trailing "Off" chip.
class EditorModeRow extends StatelessWidget {
  const EditorModeRow({
    super.key,
    required this.entries,
    required this.onPick,
    this.keyPrefix = 'mode',
  });

  final List<(String, Object?, bool)> entries;
  final ValueChanged<Object?> onPick;
  final String keyPrefix;

  /// Key suffix for one chip: `Enum.name` when the value is an enum (so
  /// `SelectiveMode.radial` becomes `radial`, not `SelectiveMode.radial`),
  /// `toString` otherwise, and `off` for null.
  static String _id(Object? value) {
    if (value == null) return 'off';
    if (value is Enum) return value.name;
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 140),
    );
    return SizedBox(
      height: EditorPanelMetrics.modeRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: EditorPanelMetrics.hPad - 4,
        ),
        child: Row(
          children: [
            for (final entry in entries)
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 2),
                  child: Semantics(
                    selected: entry.$3,
                    button: true,
                    child: AnimatedContainer(
                      duration: duration,
                      decoration: ShapeDecoration(
                        color: entry.$3
                            ? colors.surfaceBright
                            : Colors.transparent,
                        shape: StadiumBorder(
                          side: BorderSide(color: colors.border),
                        ),
                      ),
                      child: TextButton(
                        key: ValueKey('$keyPrefix-${_id(entry.$2)}'),
                        onPressed: () => onPick(entry.$2),
                        style: TextButton.styleFrom(
                          foregroundColor: colors.primary,
                          backgroundColor: Colors.transparent,
                          minimumSize: const Size(
                            0,
                            EditorPanelMetrics.modeRowHeight,
                          ),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          side: BorderSide.none,
                          shape: const StadiumBorder(),
                        ),
                        child: Text(
                          entry.$1,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 13, height: 1.1),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

/// Shared Strength slider + Invert toggle row.
///
/// Blur and Selective both need exactly these two controls; folding them
/// onto one row is what lets the panel fit the fixed sheet height. The
/// [invertKey] is shared because only one tool panel is mounted at a time.
class EditorStrengthInvertRow extends StatelessWidget {
  const EditorStrengthInvertRow({
    super.key,
    required this.strengthLabel,
    required this.strengthValue,
    required this.onStrengthChanged,
    required this.onStrengthStart,
    required this.onStrengthEnd,
    required this.onStrengthReset,
    required this.invert,
    required this.onInvertChanged,
  });

  final String strengthLabel;
  final double strengthValue;
  final ValueChanged<double> onStrengthChanged;
  final ValueChanged<double> onStrengthStart;
  final ValueChanged<double> onStrengthEnd;
  final VoidCallback onStrengthReset;
  final bool invert;
  final ValueChanged<bool> onInvertChanged;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 140),
    );
    return SizedBox(
      height: EditorPanelMetrics.secondaryRowHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(
          horizontal: EditorPanelMetrics.hPad,
        ),
        child: Row(
          children: [
            Expanded(
              child: LensSlider(
                label: strengthLabel,
                semanticLabel: strengthLabel,
                value: strengthValue,
                displayValue: strengthValue.round().toString(),
                onChanged: onStrengthChanged,
                onChangeStart: onStrengthStart,
                onChangeEnd: onStrengthEnd,
                onReset: onStrengthReset,
              ),
            ),
            const SizedBox(width: 12),
            Semantics(
              toggled: invert,
              button: true,
              child: InkWell(
                key: const ValueKey('invert-toggle'),
                onTap: () => onInvertChanged(!invert),
                borderRadius: BorderRadius.circular(10),
                child: AnimatedContainer(
                  duration: duration,
                  width: 36,
                  height: 36,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: invert ? colors.surfaceBright : Colors.transparent,
                    border: Border.all(
                      color: invert ? colors.primary : colors.border,
                    ),
                    borderRadius: BorderRadius.circular(10),
                  ),
                  child: TweenAnimationBuilder<Color?>(
                    tween: ColorTween(
                      end: invert ? colors.primary : colors.secondary,
                    ),
                    duration: duration,
                    builder: (context, color, _) => Icon(
                      LucideIcons.flipHorizontal2,
                      size: 17,
                      color: color ?? colors.secondary,
                    ),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
