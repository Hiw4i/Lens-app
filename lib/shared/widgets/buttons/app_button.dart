import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/motion/tokens/app_durations.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/app_tokens.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/animation/pressable_scale.dart';

enum AppButtonVariant { primary, secondary, ghost }

/// Presentation overrides; unspecified values come from the button preset.
@immutable
class AppButtonStyle {
  const AppButtonStyle({
    this.backgroundColor,
    this.glassBackgroundColor,
    this.foregroundColor,
    this.iconColor,
    this.textStyle,
    this.border,
    this.hasBlur = false,
    this.blurSigma = 15,
    this.isGlowing = false,
    this.boxShadow,
  });

  final Color? backgroundColor;
  final Color? glassBackgroundColor;
  final Color? foregroundColor;
  final Color? iconColor;
  final TextStyle? textStyle;
  final BorderSide? border;
  final bool hasBlur;
  final double blurSigma;
  final bool isGlowing;
  final List<BoxShadow>? boxShadow;
}

/// Shared branded button: primary / secondary / ghost.
///
/// The glass variant paints a translucent fill with an optional
/// [BackdropFilter] blur. The blur subtree is isolated in a [RepaintBoundary]
/// (inside the [ClipRRect]) so the expensive backdrop only repaints with the
/// button itself; tooltips use the framework [Tooltip]. Press/click feedback
/// and the tap haptic tick come from [PressableScale].
class AppButton extends StatefulWidget {
  const AppButton.primary({
    super.key,
    this.label,
    this.icon,
    this.child,
    this.onTap,
    this.enabled = true,
    this.width,
    this.height,
    this.minHeight = 48,
    this.borderRadius = AppRadius.pill,
    this.padding = AppSpacing.buttonPadding,
    this.iconSize = 18,
    this.shrinkWrap = false,
    this.style = const AppButtonStyle(),
    this.tooltip,
    this.semanticLabel,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
  }) : variant = AppButtonVariant.primary,
       _surfaceOnly = false,
       assert(child != null || label != null || icon != null),
       assert(child == null || (label == null && icon == null));

  const AppButton.secondary({
    super.key,
    this.label,
    this.icon,
    this.child,
    this.onTap,
    this.enabled = true,
    this.width,
    this.height,
    this.minHeight = 48,
    this.borderRadius = AppRadius.pill,
    this.padding = AppSpacing.buttonPadding,
    this.iconSize = 16,
    this.shrinkWrap = false,
    this.style = const AppButtonStyle(),
    this.tooltip,
    this.semanticLabel,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
  }) : variant = AppButtonVariant.secondary,
       _surfaceOnly = false,
       assert(child != null || label != null || icon != null),
       assert(child == null || (label == null && icon == null));

  /// Compact icon-only ghost button for floating chrome: tight radius,
  /// zero padding, 44px tap target ([size] wide, [minHeight] tall — the
  /// editor's 40×44 chrome buttons and the library's 44×44 rows share this
  /// preset). One factory for the back/save/undo/row buttons that used to
  /// be configured identically nine times.
  factory AppButton.iconGhost({
    Key? key,
    required IconData icon,
    required VoidCallback? onTap,
    String? tooltip,
    String? semanticLabel,
    double size = 40,
    double minHeight = 44,
    double iconSize = 16,
    AppButtonStyle style = const AppButtonStyle(),
  }) {
    return AppButton.ghost(
      key: key,
      icon: icon,
      onTap: onTap,
      tooltip: tooltip,
      semanticLabel: semanticLabel,
      width: size,
      height: null,
      minHeight: minHeight,
      shrinkWrap: true,
      padding: EdgeInsets.zero,
      borderRadius: AppRadius.sm,
      iconSize: iconSize,
      style: style,
    );
  }

  const AppButton.ghost({
    super.key,
    this.label,
    this.icon,
    this.child,
    this.onTap,
    this.enabled = true,
    this.width,
    this.height,
    this.minHeight = 48,
    this.borderRadius = AppRadius.pill,
    this.padding = AppSpacing.buttonPadding,
    this.iconSize = 16,
    this.shrinkWrap = false,
    this.style = const AppButtonStyle(),
    this.tooltip,
    this.semanticLabel,
    this.mouseCursor,
    this.focusNode,
    this.autofocus = false,
  }) : variant = AppButtonVariant.ghost,
       _surfaceOnly = false,
       assert(child != null || label != null || icon != null),
       assert(child == null || (label == null && icon == null));

  /// Visual surface only. The owner supplies gestures, semantics and enabled state.
  const AppButton.surface({
    super.key,
    required this.child,
    this.variant = AppButtonVariant.secondary,
    this.enabled = true,
    this.width,
    this.height,
    this.minHeight = 48,
    this.borderRadius = AppRadius.pill,
    this.shrinkWrap = false,
    this.style = const AppButtonStyle(),
    this.tooltip,
    this.mouseCursor,
  }) : _surfaceOnly = true,
       label = null,
       icon = null,
       onTap = null,
       padding = EdgeInsets.zero,
       iconSize = 18,
       semanticLabel = null,
       focusNode = null,
       autofocus = false;

  final AppButtonVariant variant;
  final String? label;
  final IconData? icon;
  final Widget? child;
  final VoidCallback? onTap;
  final bool enabled;
  final double? width;
  final double? height;
  final double minHeight;
  final double borderRadius;

  /// Padding for generated labels. Custom children own their internal layout.
  final EdgeInsetsGeometry padding;
  final double iconSize;
  final bool shrinkWrap;
  final AppButtonStyle style;
  final String? tooltip;
  final String? semanticLabel;
  final MouseCursor? mouseCursor;
  final FocusNode? focusNode;
  final bool autofocus;
  final bool _surfaceOnly;

  bool get isEnabled => enabled && (_surfaceOnly || onTap != null);

  @override
  State<AppButton> createState() => _AppButtonState();
}

class _AppButtonState extends State<AppButton> {
  bool _hovered = false;
  bool _focused = false;
  bool _showFocus = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (context
            .dependOnInheritedWidgetOfExactType<_ButtonAvailability>()
            ?.enabled ==
        false) {
      _hovered = false;
      _focused = false;
      _showFocus = false;
    }
  }

  @override
  void didUpdateWidget(AppButton oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.isEnabled || widget._surfaceOnly) {
      _hovered = false;
      _focused = false;
      _showFocus = false;
    }
  }

  void _activate() {
    if (widget.isEnabled &&
        !widget._surfaceOnly &&
        (context
                .dependOnInheritedWidgetOfExactType<_ButtonAvailability>()
                ?.enabled ??
            true)) {
      widget.onTap?.call();
    }
  }

  @override
  Widget build(BuildContext context) {
    final inherited = context
        .dependOnInheritedWidgetOfExactType<_ButtonAvailability>();
    final active = widget.isEnabled && (inherited?.enabled ?? true);
    final colors = context.themeColors;
    final policy = context.uiPerformance;
    final style = widget.style;
    final primary = widget.variant == AppButtonVariant.primary;
    final ghost = widget.variant == AppButtonVariant.ghost;
    final background =
        style.backgroundColor ??
        (primary
            ? colors.primary
            : ghost
            ? Colors.transparent
            : colors.surface);
    final foreground =
        style.foregroundColor ??
        (primary
            ? colors.primaryInverse
            : ghost
            ? colors.accent
            : colors.primary);
    final iconColor = style.iconColor ?? foreground;
    final border =
        style.border ??
        (widget.variant == AppButtonVariant.secondary
            ? BorderSide(color: colors.border)
            : BorderSide.none);
    final textStyle = AppTextStyles.button(context)
        .copyWith(decoration: TextDecoration.none)
        .merge(style.textStyle)
        .copyWith(
          color: style.foregroundColor ?? style.textStyle?.color ?? foreground,
        );
    final radius = AppRadius.circular(widget.borderRadius);
    final duration = policy.motionDuration(AppDurations.normal);
    final hasLabel = widget.label != null;
    final content =
        widget.child ??
        _AppButtonContent(label: widget.label, icon: widget.icon);
    final styledContent = AnimatedDefaultTextStyle(
      duration: duration,
      style: textStyle,
      child: IconTheme.merge(
        data: IconThemeData(color: iconColor, size: widget.iconSize),
        child: content,
      ),
    );
    final useBlur = style.hasBlur && policy.blurEnabled;
    final surfaceColor = useBlur
        ? (style.glassBackgroundColor ?? background.withValues(alpha: 0.7))
        : background;
    final surfaceBody = AnimatedContainer(
      duration: duration,
      width: widget.width,
      height: widget.height,
      constraints: widget.height == null
          ? BoxConstraints(minHeight: widget.minHeight)
          : null,
      padding: widget.child != null || !hasLabel
          ? EdgeInsets.zero
          : widget.padding,
      decoration: BoxDecoration(
        color: useBlur ? Colors.transparent : surfaceColor,
        borderRadius: radius,
        border: Border.fromBorderSide(border),
      ),
      foregroundDecoration: _showFocus && active
          ? BoxDecoration(
              borderRadius: radius,
              border: Border.all(color: colors.accent, width: 2),
            )
          : null,
      child: useBlur
          ? RepaintBoundary(
              child: ClipRRect(
                borderRadius: radius,
                child: BackdropFilter(
                  filter: ImageFilter.blur(
                    sigmaX: style.blurSigma,
                    sigmaY: style.blurSigma,
                  ),
                  child: ColoredBox(
                    color: surfaceColor,
                    child: widget.shrinkWrap
                        ? styledContent
                        : Align(
                            widthFactor: widget.width == null ? 1 : null,
                            heightFactor: widget.height == null ? 1 : null,
                            child: styledContent,
                          ),
                  ),
                ),
              ),
            )
          : (widget.shrinkWrap
                ? styledContent
                : Align(
                    // Hug content when no fixed width is given: outer width is
                    // then text + icon + padding. With a tight parent (stretch,
                    // Expanded, infinity) this still expands to the parent.
                    widthFactor: widget.width == null ? 1 : null,
                    heightFactor: widget.height == null ? 1 : null,
                    child: styledContent,
                  )),
    );
    final shadows = policy.isPerformance
        ? null
        : [
            ...?style.boxShadow,
            if (active && style.isGlowing)
              BoxShadow(
                color: background.withValues(alpha: _hovered ? 0.8 : 0.5),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
          ];
    final visual = _ButtonAvailability(
      enabled: active,
      dimmed: !active || (inherited?.dimmed ?? false),
      child: Opacity(
        opacity: active || (inherited?.dimmed ?? false) ? 1 : 0.5,
        child: IgnorePointer(
          ignoring: !active && !widget._surfaceOnly,
          child: AnimatedContainer(
            duration: duration,
            decoration: BoxDecoration(borderRadius: radius, boxShadow: shadows),
            child: surfaceBody,
          ),
        ),
      ),
    );

    final Widget button;
    if (widget._surfaceOnly) {
      button = widget.mouseCursor == null
          ? visual
          : MouseRegion(cursor: widget.mouseCursor!, child: visual);
    } else {
      button = Semantics(
        container: true,
        button: true,
        enabled: active,
        focusable: active,
        focused: _focused && active,
        label: widget.semanticLabel ?? widget.label ?? widget.tooltip,
        onTap: active ? _activate : null,
        child: Focus(
          canRequestFocus: false,
          skipTraversal: true,
          includeSemantics: false,
          // Consume repeats before they fall through to WidgetsApp's shortcuts.
          onKeyEvent: (_, event) =>
              event is KeyRepeatEvent &&
                  (event.logicalKey == LogicalKeyboardKey.enter ||
                      event.logicalKey == LogicalKeyboardKey.numpadEnter ||
                      event.logicalKey == LogicalKeyboardKey.space)
              ? KeyEventResult.handled
              : KeyEventResult.ignored,
          child: FocusableActionDetector(
            enabled: active,
            descendantsAreFocusable: active,
            descendantsAreTraversable: active,
            focusNode: widget.focusNode,
            autofocus: widget.autofocus,
            includeFocusSemantics: false,
            shortcuts: const {
              SingleActivator(LogicalKeyboardKey.enter, includeRepeats: false):
                  ActivateIntent(),
              SingleActivator(
                LogicalKeyboardKey.numpadEnter,
                includeRepeats: false,
              ): ActivateIntent(),
              SingleActivator(LogicalKeyboardKey.space, includeRepeats: false):
                  ActivateIntent(),
            },
            actions: {
              ActivateIntent: CallbackAction<ActivateIntent>(
                onInvoke: (_) {
                  _activate();
                  return null;
                },
              ),
            },
            onFocusChange: (focused) => setState(() => _focused = focused),
            onShowFocusHighlight: (show) => setState(() => _showFocus = show),
            child: PressableScale(
              enabled: active,
              onTap: active ? _activate : null,
              excludeFromSemantics: true,
              // A filtered transform isolates its subtree, so a BackdropFilter
              // inside would lose its backdrop mid-animation. Blurred buttons
              // scale through a transform layer instead; the region is tiny,
              // so no extra caching is introduced.
              filterQuality: style.hasBlur && policy.blurEnabled
                  ? null
                  : FilterQuality.medium,
              mouseCursor: widget.mouseCursor,
              onHoverChanged: style.isGlowing
                  ? (hovered) => setState(() => _hovered = hovered)
                  : null,
              child: widget.child == null
                  ? ExcludeSemantics(child: visual)
                  : visual,
            ),
          ),
        ),
      );
    }
    final tooltip = widget.tooltip;
    return tooltip == null || tooltip.isEmpty
        ? button
        : Tooltip(message: tooltip, child: button);
  }
}

/// Shared label layout; presentation comes from DefaultTextStyle and IconTheme.
class _AppButtonContent extends StatelessWidget {
  const _AppButtonContent({this.label, this.icon, this.maxLines = 1})
    : assert(label != null || icon != null),
      assert(maxLines > 0);

  final String? label;
  final IconData? icon;
  final int maxLines;

  @override
  Widget build(BuildContext context) {
    final iconTheme = IconTheme.of(context);
    return Row(
      mainAxisSize: MainAxisSize.min,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        if (icon != null)
          Icon(icon, color: iconTheme.color, size: iconTheme.size),
        if (icon != null && label != null) const SizedBox(width: AppSpacing.sm),
        if (label != null)
          Flexible(
            child: Text(
              label!,
              maxLines: maxLines,
              overflow: TextOverflow.ellipsis,
              textAlign: TextAlign.center,
            ),
          ),
      ],
    );
  }
}

/// Nested actions inherit disabled state without multiplying the dimming.
class _ButtonAvailability extends InheritedWidget {
  const _ButtonAvailability({
    required this.enabled,
    required this.dimmed,
    required super.child,
  });

  final bool enabled;
  final bool dimmed;

  @override
  bool updateShouldNotify(_ButtonAvailability oldWidget) =>
      oldWidget.enabled != enabled || oldWidget.dimmed != dimmed;
}
