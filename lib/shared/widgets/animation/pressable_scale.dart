import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/widgets/animation/press_motion_controller.dart';

/// Hover/press scale animation shared by all pressable controls.
///
/// Disabled controls neither animate nor dispatch gestures.
/// Enabled surfaces can still hover when [onTap] is null.
///
/// A successful tap also plays a light haptic tick while the global
/// "Haptic Feedback" setting is on, so every branded button ([AppButton],
/// tiles, close controls) shares one pleasant response.
class PressableScale extends StatefulWidget {
  final VoidCallback? onTap;
  final GestureTapDownCallback? onTapDown;
  final GestureTapUpCallback? onTapUp;
  final VoidCallback? onTapCancel;
  final ValueChanged<bool>? onHoverChanged;
  final bool enabled;
  final MouseCursor? mouseCursor;
  final bool excludeFromSemantics;

  /// Local haptic opt-out combined with the global "Haptic Feedback" setting:
  /// the tap tick plays only when both are on.
  final bool hapticsEnabled;

  /// Smoothing for the scale transform. A non-null value rasterizes through
  /// an image-filter layer where a [BackdropFilter] below loses its backdrop,
  /// so blurred surfaces must pass null and scale via a transform layer.
  final FilterQuality? filterQuality;
  final Widget child;

  const PressableScale({
    super.key,
    required this.child,
    this.onTap,
    this.onTapDown,
    this.onTapUp,
    this.onTapCancel,
    this.onHoverChanged,
    this.enabled = true,
    this.mouseCursor,
    this.excludeFromSemantics = false,
    this.hapticsEnabled = true,
    this.filterQuality = FilterQuality.medium,
  });

  @override
  State<PressableScale> createState() => _PressableScaleState();
}

class _PressableScaleState extends State<PressableScale>
    with SingleTickerProviderStateMixin {
  late final _motion = PressMotionController(vsync: this);
  int? _pointer;
  Offset? _downPosition;

  /// Pointers already pressed by a nested [PressableScale].
  ///
  /// Raw pointer events bubble from the deepest [Listener] outward, while a
  /// nested tap wins the gesture arena outright: the outer [GestureDetector]
  /// then receives neither [onTapUp] nor [onTapCancel], so an outer press
  /// started from the same pointer would never release and stay compressed
  /// (e.g. a track card staying small after tapping its preview button).
  /// The deepest pressable claims the pointer first, ancestors skip theirs.
  static final Set<int> _claimedPointers = <int>{};

  bool get _canTap => widget.enabled && widget.onTap != null;

  void _releaseClaim(int pointer) => _claimedPointers.remove(pointer);

  void _abandonPointer() {
    final pointer = _pointer;
    _pointer = null;
    if (pointer != null) _releaseClaim(pointer);
    _motion.resetInteraction();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final policy = context.uiPerformance;
    _motion.setMotionEnabled(
      policy.motionEnabled &&
          !policy.isPerformance &&
          !MediaQuery.disableAnimationsOf(context),
    );
    if (!TickerMode.valuesOf(context).enabled) {
      _abandonPointer();
    }
  }

  @override
  void didUpdateWidget(covariant PressableScale oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!widget.enabled || (oldWidget.onTap != null && widget.onTap == null)) {
      _abandonPointer();
    }
  }

  @override
  void dispose() {
    final pointer = _pointer;
    _pointer = null;
    if (pointer != null) _releaseClaim(pointer);
    _motion.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: widget.enabled
          ? widget.mouseCursor ??
                (_canTap ? SystemMouseCursors.click : MouseCursor.defer)
          : MouseCursor.defer,
      onEnter: (_) {
        if (!widget.enabled) return;
        _motion.hover(true);
        widget.onHoverChanged?.call(true);
      },
      onExit: (_) {
        if (!widget.enabled) return;
        _motion.hover(false);
        widget.onHoverChanged?.call(false);
      },
      child: Listener(
        onPointerDown: (event) {
          if (!_canTap || _pointer != null || event.buttons != kPrimaryButton) {
            return;
          }
          if (_claimedPointers.contains(event.pointer)) return;
          _pointer = event.pointer;
          _claimedPointers.add(event.pointer);
          _downPosition = event.position;
          final box = context.findRenderObject();
          final extent = box is RenderBox && box.hasSize
              ? box.size.longestSide
              : 200.0;
          // Bound travel for cards, while small icon controls remain legible.
          final scale = extent > 0 ? 1 - (10 / extent).clamp(0.02, 0.10) : 0.95;
          _motion.press(targetScale: scale);
        },
        onPointerMove: (event) {
          if (_pointer != event.pointer) return;
          if ((event.position - _downPosition!).distance >
              computeHitSlop(
                event.kind,
                MediaQuery.gestureSettingsOf(context),
              )) {
            _pointer = null;
            _releaseClaim(event.pointer);
            _motion.cancel();
          }
        },
        onPointerUp: (event) {
          if (_pointer == event.pointer) {
            _pointer = null;
            _releaseClaim(event.pointer);
          }
        },
        onPointerCancel: (event) {
          if (_pointer != event.pointer) return;
          _pointer = null;
          _releaseClaim(event.pointer);
          _motion.cancel();
        },
        child: GestureDetector(
          excludeFromSemantics: widget.excludeFromSemantics,
          onTapDown: !_canTap
              ? null
              : (details) {
                  if (!_canTap) return;
                  widget.onTapDown?.call(details);
                },
          onTapUp: !_canTap
              ? null
              : (details) {
                  if (!_canTap) return;
                  _motion.release();
                  widget.onTapUp?.call(details);
                },
          onTapCancel: !_canTap
              ? null
              : () {
                  if (!_canTap) return;
                  _motion.cancel();
                  widget.onTapCancel?.call();
                },
          onTap: !_canTap
              ? null
              : () {
                  if (_canTap) {
                    if (widget.hapticsEnabled && context.hapticsEnabled) {
                      AppHaptics.tap();
                    }
                    widget.onTap?.call();
                  }
                },
          child: AnimatedBuilder(
            animation: _motion,
            builder: (context, child) => Transform.scale(
              scale: _motion.value,
              // Bilinear sampling smooths the final frames of tiny hover scales
              // on Windows; cheaper than high (bicubic) for a 2% transform.
              // Null keeps a transform layer so an inner BackdropFilter still
              // samples its backdrop instead of an isolated buffer.
              filterQuality: widget.filterQuality,
              child: child,
            ),
            child: widget.child,
          ),
        ),
      ),
    );
  }
}
