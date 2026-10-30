import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/physics.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/motion/tokens/app_springs.dart';

/// Full-screen photo viewport with a stable resting frame.
///
/// The canvas is the whole screen: the floating top bar and the tool sheet
/// sit above it, so a photo that is zoomed in really does cover the display
/// instead of being boxed into the gap between the panels.
///
/// The photo itself rests inside the *visible* area — the canvas minus the
/// chrome the editor floats over it — and keeps that frame while the chrome
/// changes size. It is moved only when the sheet would cover it, and not at
/// all once the user has panned or zoomed the photo themselves.
///
/// The gestures are handled here instead of through [InteractiveViewer]
/// because the resting frame has to survive chrome resizes, and because a
/// release has to snap the photo back onto that frame: InteractiveViewer
/// owns its matrix and would undo both.
class PhotoViewport extends StatefulWidget {
  const PhotoViewport({
    super.key,
    required this.aspectRatio,
    required this.visibleInsets,
    required this.child,
    this.maxScale = 4,
  });

  /// width / height of the photo as it is displayed.
  final double aspectRatio;

  /// The area the floating chrome leaves free.
  final EdgeInsets visibleInsets;

  /// The photo. Laid out by the viewport at the resting size.
  final Widget child;

  /// How far the photo may be zoomed in, relative to its resting size.
  final double maxScale;

  @override
  State<PhotoViewport> createState() => _PhotoViewportState();
}

class _PhotoViewportState extends State<PhotoViewport>
    with SingleTickerProviderStateMixin {
  /// The photo's frame at scale 1 with no user offset.
  ///
  /// The largest rect with the photo's aspect that fits the visible area,
  /// centred. It follows the chrome: while the sheet grows the picture keeps
  /// its frame as long as the sheet does not reach it, and it takes the space
  /// back as soon as the sheet gives it.
  Rect _rest = Rect.zero;

  /// The user's zoom, relative to the resting size.
  double _scale = 1;

  /// The user's pan, relative to [_rest].
  Offset _offset = Offset.zero;

  /// The canvas the viewport covers.
  Size _canvas = Size.zero;

  /// The area the floating chrome leaves free.
  Rect _visible = Rect.zero;

  /// The photo's aspect the current resting frame was composed for.
  double _aspect = 1;

  /// The scale the running gesture started at.
  double _gestureScale = 1;

  /// The photo-local point that was grabbed, in resting pixels.
  Offset _gestureAnchor = Offset.zero;

  /// Whether the running gesture actually moved the photo.
  bool _gestured = false;

  /// The snap home and the fling share one controller: both animate the
  /// painted frame from one rect to another.
  late final AnimationController _motion =
      AnimationController.unbounded(vsync: this)
        ..addListener(_onMotionTick)
        ..addStatusListener(_onMotionStatus);

  /// The frames the running motion animates between.
  Rect? _motionFrom;
  Rect? _motionTo;

  /// Whether the running motion is the spring rather than the fling.
  bool _springing = false;

  /// How close to 1x the photo must be for the release to snap it home.
  static const double _snapScaleTolerance = 0.03;

  /// The drag the fling decays with — the same constant InteractiveViewer
  /// uses, so the photo keeps its current glide.
  static const double _flingDrag = 0.0000135;

  @override
  void dispose() {
    _motion.dispose();
    super.dispose();
  }

  /// Whether the user has moved the photo themselves.
  bool get _userMoved => _scale != 1 || _offset != Offset.zero;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        _syncLayout(constraints.biggest);
        final Rect painted = _paintedRect();
        if (_rest.isEmpty || painted.isEmpty) return const SizedBox.expand();
        // The photo is laid out at its resting size and scaled on the
        // canvas, so a zoom costs a repaint instead of a relayout.
        final double zoom = painted.width / _rest.width;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: _onScaleStart,
          onScaleUpdate: _onScaleUpdate,
          onScaleEnd: _onScaleEnd,
          child: Listener(
            onPointerSignal: _onPointerSignal,
            child: Stack(
              fit: StackFit.expand,
              children: [
                Positioned(
                  left: painted.left,
                  top: painted.top,
                  width: _rest.width,
                  height: _rest.height,
                  child: Transform(
                    transform: Matrix4.identity()
                      ..scaleByDouble(zoom, zoom, 1, 1),
                    alignment: Alignment.topLeft,
                    child: widget.child,
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Keeps the resting frame in step with the canvas and the chrome.
  ///
  /// Runs during layout, so it only updates fields — never the widget tree
  /// — and the new frame is painted in the same frame.
  ///
  /// The chrome drives the composition: a sheet that grows leaves the photo
  /// alone as long as it does not reach it, and the photo takes the space
  /// back as soon as the sheet gives it. A photo the user has zoomed or
  /// moved is never touched.
  void _syncLayout(Size canvas) {
    final Rect visible = _visibleArea(canvas);
    final bool canvasChanged = canvas != _canvas;
    final bool visibleChanged = visible != _visible;
    final bool aspectChanged = widget.aspectRatio != _aspect;
    final bool chromeGrew =
        visible.width >= _visible.width && visible.height >= _visible.height;
    _canvas = canvas;
    _visible = visible;
    _aspect = widget.aspectRatio;

    if (canvasChanged || aspectChanged) {
      // A new canvas (rotation) or a new photo shape: compose from scratch.
      _rest = _fitRect(visible);
      _scale = 1;
      _offset = Offset.zero;
      return;
    }
    if (!visibleChanged || _userMoved) return;
    if (chromeGrew) {
      // The chrome gave the space back: the photo takes it.
      _rest = _fitRect(visible);
      return;
    }
    if (_fits(_rest, visible)) return;
    // The chrome reached the photo: make room for it.
    _rest = _clearOfChrome(_rest, visible);
  }

  /// The area the chrome leaves free.
  Rect _visibleArea(Size canvas) {
    final EdgeInsets insets = widget.visibleInsets;
    final double left = insets.left.clamp(0.0, canvas.width);
    final double top = insets.top.clamp(0.0, canvas.height);
    final double right = (canvas.width - insets.right).clamp(
      left,
      canvas.width,
    );
    final double bottom = (canvas.height - insets.bottom).clamp(
      top,
      canvas.height,
    );
    return Rect.fromLTRB(left, top, right, bottom);
  }

  /// The largest rect with the photo's aspect that fits [area], centred.
  Rect _fitRect(Rect area) {
    if (area.isEmpty) return Rect.zero;
    final double aspect = widget.aspectRatio.isFinite && widget.aspectRatio > 0
        ? widget.aspectRatio
        : 1;
    double width = area.width;
    double height = width / aspect;
    if (height > area.height) {
      height = area.height;
      width = height * aspect;
    }
    return Rect.fromLTWH(
      area.left + (area.width - width) / 2,
      area.top + (area.height - height) / 2,
      width,
      height,
    );
  }

  /// The frame the photo keeps when the chrome changes.
  ///
  /// The photo holds its size and slides up when the sheet grows over it;
  /// when it no longer fits under the top bar it is re-fitted into the
  /// visible area instead.
  Rect _clearOfChrome(Rect rest, Rect visible) {
    if (visible.isEmpty || rest.isEmpty) return rest;
    if (_fits(rest, visible)) return rest;
    final double overflow = rest.bottom - visible.bottom;
    final double room = rest.top - visible.top;
    if (overflow > 0 && room > 0) {
      return rest.shift(Offset(0, -math.min(overflow, room)));
    }
    return _fitRect(visible);
  }

  /// Whether [rest] sits inside [visible] without touching its edges.
  ///
  /// Compared edge by edge: Rect.contains treats its far edges as exclusive,
  /// and a photo that fills the window exactly is inside it.
  bool _fits(Rect rest, Rect visible) =>
      rest.left >= visible.left &&
      rest.top >= visible.top &&
      rest.right <= visible.right &&
      rest.bottom <= visible.bottom;

  /// The photo's painted frame.
  Rect _paintedRect() {
    final Rect? from = _motionFrom;
    final Rect? to = _motionTo;
    if (from != null && to != null) {
      final double t = _springing
          ? _motion.value
          : Curves.decelerate.transform(_motion.value.clamp(0.0, 1.0));
      return Rect.lerp(from, to, t) ?? to;
    }
    return Rect.fromLTWH(
      _rest.left + _offset.dx,
      _rest.top + _offset.dy,
      _rest.width * _scale,
      _rest.height * _scale,
    );
  }

  /// The photo-local point (in resting pixels) under a screen point.
  Offset _localAt(Offset point) {
    if (_scale <= 0) return Offset.zero;
    return (point - _rest.topLeft - _offset) / _scale;
  }

  /// Keeps the photo reachable: it may not be dragged out of the canvas,
  /// and when it is larger than the canvas it has to cover it.
  Offset _clampOffset(Offset offset, double scale) {
    if (_rest.isEmpty || _canvas.isEmpty) return offset;
    return Offset(
      _clampAxis(offset.dx, _rest.left, _rest.width * scale, _canvas.width),
      _clampAxis(offset.dy, _rest.top, _rest.height * scale, _canvas.height),
    );
  }

  double _clampAxis(double value, double origin, double extent, double canvas) {
    final double leading = -origin;
    final double trailing = canvas - origin - extent;
    return value
        .clamp(math.min(leading, trailing), math.max(leading, trailing))
        .toDouble();
  }

  void _onScaleStart(ScaleStartDetails details) {
    if (_motion.isAnimating) {
      _freezeMotion();
      setState(() {});
    }
    _gestureScale = _scale;
    _gestureAnchor = _localAt(details.localFocalPoint);
    _gestured = false;
  }

  void _onScaleUpdate(ScaleUpdateDetails details) {
    final double scale = (_gestureScale * details.scale)
        .clamp(1.0, widget.maxScale)
        .toDouble();
    // The grabbed point stays under the finger: the photo is scaled about it
    // and follows the finger from there.
    final Offset offset =
        details.localFocalPoint - _rest.topLeft - _gestureAnchor * scale;
    final Offset clamped = _clampOffset(offset, scale);
    if (clamped != _offset || scale != _scale) _gestured = true;
    setState(() {
      _scale = scale;
      _offset = clamped;
    });
  }

  void _onScaleEnd(ScaleEndDetails details) {
    // A tap that never moved the photo is left alone: the press-and-hold
    // comparison must not send the photo home.
    if (_gestured && (_scale - 1).abs() <= _snapScaleTolerance) {
      _snapHome();
      return;
    }
    _fling(details.velocity.pixelsPerSecond);
  }

  /// Zooms with the mouse wheel, about the pointer.
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is! PointerScrollEvent) return;
    if (event.scrollDelta.dy == 0) return;
    final bool wasAnimating = _motion.isAnimating;
    if (wasAnimating) _freezeMotion();
    final double scale = (_scale * math.exp(-event.scrollDelta.dy / 200))
        .clamp(1.0, widget.maxScale)
        .toDouble();
    if (scale == _scale && !wasAnimating) return;
    final Offset anchor = _localAt(event.localPosition);
    final Offset offset = event.localPosition - _rest.topLeft - anchor * scale;
    setState(() {
      _scale = scale;
      _offset = _clampOffset(offset, scale);
    });
  }

  /// Glides the photo back onto its resting frame.
  ///
  /// The photo lands on the canonical frame for the visible area: that is
  /// where the user expects it when they pinch back to 1x.
  void _snapHome() => _glideTo(_fitRect(_visible));

  /// Glides the painted frame onto [target].
  void _glideTo(Rect target) {
    if (target.isEmpty) return;
    final Duration duration = context.uiPerformance.motionDuration(
      AppSprings.photoSnapHome.duration,
    );
    if (duration <= Duration.zero) {
      setState(() {
        _rest = target;
        _scale = 1;
        _offset = Offset.zero;
      });
      return;
    }
    _motionFrom = _paintedRect();
    _motionTo = target;
    _springing = true;
    _motion.value = 0;
    _motion.animateWith(
      SpringSimulation(
        SpringDescription.withDurationAndBounce(
          duration: duration,
          bounce: AppSprings.photoSnapHome.bounce,
        ),
        0,
        1,
        0,
      ),
    );
  }

  /// Lets the photo glide on after the finger lifts.
  void _fling(Offset velocity) {
    if (velocity.distance < kMinFlingVelocity) return;
    final Rect painted = _paintedRect();
    final FrictionSimulation x = FrictionSimulation(_flingDrag, 0, velocity.dx);
    final FrictionSimulation y = FrictionSimulation(_flingDrag, 0, velocity.dy);
    final Offset travel = Offset(x.finalX, y.finalX);
    if (travel.distance < 0.5) return;
    final Offset target = _clampOffset(_offset + travel, _scale);
    final Rect destination = Rect.fromLTWH(
      _rest.left + target.dx,
      _rest.top + target.dy,
      _rest.width * _scale,
      _rest.height * _scale,
    );
    final Duration duration = Duration(
      milliseconds: (_finalTime(velocity.distance) * 1000).round(),
    );
    if (duration <= Duration.zero) {
      setState(() => _offset = target);
      return;
    }
    _motionFrom = painted;
    _motionTo = destination;
    _springing = false;
    _motion.value = 0;
    _motion.animateTo(1, duration: duration);
  }

  /// How long the fling runs, matching InteractiveViewer's budget.
  double _finalTime(double velocity) {
    const double effectivelyMotionless = 10;
    final double seconds =
        math.log(effectivelyMotionless / velocity) / math.log(_flingDrag / 100);
    return seconds.isFinite && seconds > 0 ? seconds : 0;
  }

  /// Freezes the running motion, keeping the photo exactly where it is.
  void _freezeMotion() {
    final Rect painted = _paintedRect();
    _motionFrom = null;
    _motionTo = null;
    if (painted.isEmpty || _rest.isEmpty || _rest.width <= 0) return;
    _scale = (painted.width / _rest.width)
        .clamp(1.0, widget.maxScale)
        .toDouble();
    _offset = painted.topLeft - _rest.topLeft;
  }

  void _onMotionStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _commitMotion();
    } else if (status == AnimationStatus.dismissed) {
      _motionFrom = null;
      _motionTo = null;
    }
    if (mounted) setState(() {});
  }

  /// Repaints the photo on every frame of a running motion.
  void _onMotionTick() {
    if (mounted) setState(() {});
  }

  /// Applies the finished motion.
  void _commitMotion() {
    final Rect? to = _motionTo;
    _motionFrom = null;
    _motionTo = null;
    if (to == null) return;
    if (_springing) {
      // The photo is home: the resting frame becomes the canonical one.
      _rest = to;
      _scale = 1;
      _offset = Offset.zero;
      return;
    }
    _offset = to.topLeft - _rest.topLeft;
  }
}
