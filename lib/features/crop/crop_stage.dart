import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lens/features/crop/crop_spec.dart';

/// How a drag that started on the stage should be interpreted.
///
/// There is deliberately no "rotate" zone: the angle belongs to the panel's
/// straighten slider, so a gesture can never turn the photo on its own.
enum _Zone { none, move, resize }

/// Interactive crop + straighten stage.
///
/// Composition is deliberately two layers and one gesture detector:
///
/// * the photo, turned and straightened, laid out at its **rotated frame**
///   size and contained in the available area — the whole photo stays
///   visible so the user can see what they are cutting;
/// * one [CustomPaint] on top that dims everything outside the window,
///   draws the rule-of-thirds grid and the four corner brackets.
///
/// The dimmed surround is a hole punched with [PathOperation.difference]
/// rather than a second copy of the photo, so there is only ever one photo in
/// the tree. The scrim is limited to the PICTURE: the area around the photo
/// keeps the editor's background, exactly like every other tool. A scrim
/// over the whole stage turned the crop screen into a black rectangle.
///
/// Every gesture goes through a single `GestureDetector`. Handles are hit
/// TESTED against the pointer position instead of being their own widgets:
/// a per-handle recognizer competing with the scale/rotate recognizer in the
/// same arena is the usual source of "the corner sometimes doesn't grab".
///
/// Two fingers magnify the picture:
///
/// * the crop window keeps its place on screen, so the region of the photo
///   under the window — the crop itself — grows tighter as the picture
///   grows. Pinching back out restores it.
///
/// Straightening is the panel slider's job only: a twist of two fingers
/// must not tilt the photo by accident.
class CropStage extends StatefulWidget {
  const CropStage({
    super.key,
    required this.spec,
    required this.photoAspect,
    required this.photo,
    required this.onRectChanged,
  });

  /// Current geometry. Normalized, so it is independent of layout size.
  final CropSpec spec;

  /// width / height of the source photo.
  final double photoAspect;

  /// The rendered photo. Sized by this widget to the exact source aspect, so
  /// the shader's own fit cannot introduce a second scale factor.
  final Widget photo;

  final ValueChanged<Rect> onRectChanged;

  @override
  State<CropStage> createState() => _CropStageState();
}

class _CropStageState extends State<CropStage> {
  /// How close a pointer must be to a corner to grab it.
  static const double _handleHit = 28;

  /// How far the fingers have to part before a two-finger gesture counts as a
  /// pinch. Below this the very same gesture is read as a twist.
  static const double _pinchEpsilon = 0.02;

  /// Ceiling for the picture's magnification. The real limit is the crop
  /// window's minimum size (see [_maxZoomFor]); this one only stops a
  /// runaway gesture from turning the picture into a blur.
  static const double _zoomCeiling = 8;

  _Zone _zone = _Zone.none;

  /// Which corner the resize drag owns; null unless [_Zone.resize].
  CropCorner? _corner;

  /// Window size frozen at gesture start so resizing is computed from the
  /// frame the user actually grabbed, not from a value that already moved.
  Rect _startWindow = Rect.zero;

  /// The crop window in SCREEN pixels, frozen when a pinch starts. While the
  /// picture is magnified the window must stay exactly where it is: the
  /// picture grows under it, the window does not move.
  Rect _pinchWindow = Rect.zero;

  /// Total pointer travel since gesture start, accumulated across updates.
  Offset _dragged = Offset.zero;

  Offset _lastFocal = Offset.zero;

  /// The picture's magnification. 1 = the photo sits exactly in its frame.
  double _zoom = 1;

  /// The magnification the running pinch started from.
  double _zoomStart = 1;

  /// The point under the fingers when the pinch started, in frame units.
  Offset _zoomAnchor = Offset.zero;

  /// How far the picture has been moved inside the window, in screen pixels.
  ///
  /// Dragging inside the window moves the PICTURE, not the window: the
  /// window is the frame the user composes in and stays where it is, while
  /// the crop rectangle — what the exporter sees — follows the picture.
  Offset _pan = Offset.zero;

  /// The pan at the start of the running gesture, so a drag always measures
  /// from where the picture was, not from the last frame's offset.
  Offset _panStart = Offset.zero;

  /// Whether the running gesture is a pinch. A pinch owns the gesture until
  /// the fingers are lifted: the picture is magnified, the window is not.
  bool _pinching = false;

  /// The rotated frame at 1x, as the last layout placed it.
  ///
  /// The gesture handlers rebuild the picture from this instead of trusting
  /// the value the last painted frame carried: a pinch update arrives
  /// before the rebuild that would show it, and the picture it measured
  /// would still be the un-zoomed one.
  Rect _frame = Rect.zero;

  @override
  void didUpdateWidget(covariant CropStage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.spec == oldWidget.spec) return;
    // A new ratio, a straighten or a rotate puts the picture back into its
    // resting place. A change of the crop rectangle keeps the picture where
    // the user put it.
    final bool geometryChanged =
        widget.spec.ratio != oldWidget.spec.ratio ||
        widget.spec.angleDegrees != oldWidget.spec.angleDegrees ||
        widget.spec.quarterTurns != oldWidget.spec.quarterTurns;
    if (geometryChanged && (_pan != Offset.zero || _zoom != 1)) {
      setState(() {
        _pan = Offset.zero;
        _zoom = 1;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Size source = CropSpec.nominalSource(widget.photoAspect);
    final Size rotated = widget.spec.rotatedSize(source);

    return LayoutBuilder(
      builder: (context, constraints) {
        final Size area = Size(constraints.maxWidth, constraints.maxHeight);
        if (!area.isFinite || area.isEmpty) {
          return const SizedBox.expand();
        }
        // Contain the whole rotated frame: the user must see the corners
        // they are about to rotate into existence.
        final double k = math.min(
          area.width / rotated.width,
          area.height / rotated.height,
        );
        if (!k.isFinite || k <= 0) return const SizedBox.expand();
        final Size frameSize = Size(rotated.width * k, rotated.height * k);
        final Rect frame = Alignment.center.inscribe(
          frameSize,
          Offset.zero & area,
        );
        _frame = frame;
        // The picture is the frame, magnified and slid. The crop window is
        // derived from the picture, so the two can never drift apart.
        final Rect picture = _pictureRect(frame);
        final Rect window = _windowIn(picture, widget.spec.rect);

        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onScaleStart: (d) => _onStart(d.localFocalPoint),
          onScaleUpdate: (d) => _onUpdate(d, source),
          child: Stack(
            fit: StackFit.expand,
            children: [
              Positioned.fromRect(
                rect: picture,
                child: ClipRect(
                  child: Stack(
                    children: [
                      Positioned(
                        left: 0,
                        top: 0,
                        width: frame.width,
                        height: frame.height,
                        child: Transform(
                          // The magnification is a TRANSFORM, not a layout
                          // size: the shader keeps painting the preview at
                          // its own resolution instead of re-rendering a
                          // magnified one every frame.
                          transform: Matrix4.identity()
                            ..scaleByDouble(_zoom, _zoom, 1, 1),
                          alignment: Alignment.topLeft,
                          child: _turnedPhoto(source, rotated, k),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _CropFramePainter(
                      window: window,
                      frame: picture,
                      colors: context.themeColorsLikeCrop,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  /// The picture's screen rect: the frame, magnified about its centre and
  /// then slid by the pan.
  Rect _pictureRect(Rect frame) {
    final Rect magnified = Rect.fromCenter(
      center: frame.center,
      width: frame.width * _zoom,
      height: frame.height * _zoom,
    );
    return magnified.shift(_pan);
  }

  /// The crop window expressed in the picture's coordinates.
  Rect _windowIn(Rect picture, Rect normalized) => Rect.fromLTWH(
    picture.left + normalized.left * picture.width,
    picture.top + normalized.top * picture.height,
    normalized.width * picture.width,
    normalized.height * picture.height,
  );

  /// Quarter turns, then the straighten, then nothing else — the same order
  /// the exporter resamples in, so the two agree on the rotated frame.
  Widget _turnedPhoto(Size source, Size rotated, double k) {
    final Size turned = widget.spec.turnedSize(source);
    Widget photo = SizedBox(
      width: source.width * k,
      height: source.height * k,
      child: widget.photo,
    );
    if (widget.spec.quarterTurns != 0) {
      photo = RotatedBox(quarterTurns: widget.spec.quarterTurns, child: photo);
    }
    return SizedBox(
      width: rotated.width * k,
      height: rotated.height * k,
      child: Center(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..rotateZ(widget.spec.angleDegrees * math.pi / 180.0),
          child: SizedBox(
            width: turned.width * k,
            height: turned.height * k,
            child: photo,
          ),
        ),
      ),
    );
  }

  void _onStart(Offset focal) {
    final Rect window = _windowIn(_pictureRect(_frame), widget.spec.rect);
    _lastFocal = focal;
    _startWindow = widget.spec.rect;
    _dragged = Offset.zero;
    _panStart = _pan;
    _zoomStart = _zoom;
    _pinching = false;
    final CropCorner? hit = _cornerNear(focal, window);
    // Only a real corner hit arms resize. Entering it regardless would send
    // every in-window drag down the resize path with a null corner.
    if (hit != null) {
      _corner = hit;
      _zone = _Zone.resize;
      return;
    }
    if (window.inflate(_handleHit * 0.5).contains(focal)) {
      _zone = _Zone.move;
      return;
    }
    // Outside the window: a drag there does nothing. Two fingers still
    // magnify the picture, which is why the zone flips in _onUpdate.
    _zone = _Zone.none;
  }

  void _onUpdate(ScaleUpdateDetails d, Size source) {
    final Rect picture = _pictureRect(_frame);
    final Offset focal = d.localFocalPoint;

    if (d.pointerCount >= 2) {
      // Two fingers own the gesture. This branch wins over a resize drag,
      // so lifting one finger mid-gesture does not abandon a half-resized
      // window.
      _onTwoFinger(d, source, picture);
      return;
    }

    if (_pinching) {
      // The gesture was a pinch: the finger that is left starts a fresh
      // drag instead of jumping by the pinch's travel.
      _pinching = false;
      _dragged = Offset.zero;
      _lastFocal = focal;
      return;
    }

    final Offset delta = focal - _lastFocal;

    if (_zone == _Zone.none || delta == Offset.zero) return;
    // `_dragged` accumulates, because `delta` is per-update while the window
    // is always rebuilt from the frame frozen at gesture start. Using the
    // incremental delta against the start rect would make the window jump
    // back toward its origin on every slow frame.
    _dragged += delta;
    _lastFocal = focal;

    // Normalize against the DISPLAYED picture, not the nominal source. The
    // stage is usually much smaller than `nominalSource` (a 400pt-wide
    // preview vs a 1333pt nominal landscape frame), so dividing by the
    // nominal size made the window crawl at a fraction of the finger speed.
    if (!picture.isFinite || picture.isEmpty) return;
    final Offset drag = Offset(
      _dragged.dx / picture.width,
      _dragged.dy / picture.height,
    );

    if (_zone == _Zone.move) {
      // The picture follows the finger and the window stays put: the crop
      // rectangle moves the other way inside the picture, so the two
      // together leave the window where the user sees it.
      final Rect candidate = _startWindow.shift(-drag);
      final Rect clamped = widget.spec.clamp(
        candidate,
        widget.spec.safeRect(source),
      );
      // Whatever the picture could actually travel is what the window gives
      // back, so a picture at its edge does not drag the window along.
      final Offset applied = clamped.topLeft - _startWindow.topLeft;
      setState(() {
        _pan =
            _panStart -
            Offset(applied.dx * picture.width, applied.dy * picture.height);
      });
      widget.onRectChanged(clamped);
      return;
    }

    widget.onRectChanged(
      widget.spec.resizeWindow(
        start: _startWindow,
        corner: _corner!,
        drag: drag,
        source: source,
      ),
    );
  }

  /// Two fingers: a pinch magnifies the picture.
  ///
  /// There is deliberately nothing else here: a twist of two fingers does
  /// NOT straighten the photo. Straightening is the panel slider's job, and
  /// a hand that pinches always carries a little rotation with it.
  void _onTwoFinger(ScaleUpdateDetails d, Size source, Rect picture) {
    final bool pinching = (d.scale - 1).abs() > _pinchEpsilon;
    if (!pinching) return;
    if (!_pinching) {
      _pinching = true;
      _zoomStart = _zoom;
      _zoomAnchor = _anchorAt(d.localFocalPoint, picture);
      // The window is frozen for the whole pinch: it must not move while
      // the picture is magnified underneath it.
      _pinchWindow = _windowIn(picture, widget.spec.rect);
    }
    _applyZoom(d, picture, source);
  }

  /// Magnifies the picture around the fingers.
  ///
  /// The crop window keeps its place on screen, so the crop RECTANGLE in the
  /// photo shrinks to whatever is left under the window: a pinch in is a
  /// tighter crop of the same picture, exactly like the zoom in the other
  /// tools. Pinching back out restores the previous crop.
  void _applyZoom(ScaleUpdateDetails d, Rect picture, Size source) {
    final double ceiling = _maxZoomFor(picture, source);
    final double zoom = (_zoomStart * d.scale)
        .clamp(1.0, math.max(1.0, ceiling))
        .toDouble();
    // The picture's own box at 1x, recovered from the current one.
    final Size base = Size(picture.width / _zoom, picture.height / _zoom);
    final Offset baseCenter = picture.center - _pan;
    final Size magnified = Size(base.width * zoom, base.height * zoom);
    // The point under the fingers stays under the fingers.
    final Offset wanted =
        d.localFocalPoint -
        Offset(
          _zoomAnchor.dx * magnified.width,
          _zoomAnchor.dy * magnified.height,
        );
    final Rect placed = _placePicture(wanted, magnified, source);
    final Rect magnifiedFrame = Rect.fromCenter(
      center: baseCenter,
      width: magnified.width,
      height: magnified.height,
    );
    setState(() {
      _zoom = zoom;
      _pan = placed.topLeft - magnifiedFrame.topLeft;
    });
    widget.onRectChanged(_regionUnder(placed, _pinchWindow));
  }

  /// Keeps the picture inside the safe area.
  ///
  /// The window is fixed, so sliding the picture too far would push the
  /// cropped region out of the frame — into the transparent corners a
  /// straightened photo has. The picture is stopped at that edge instead.
  Rect _placePicture(Offset topLeft, Size magnified, Size source) {
    final Rect safe = widget.spec.safeRect(source);
    final double minLeft = _pinchWindow.left - safe.right * magnified.width;
    final double maxLeft = _pinchWindow.left - safe.left * magnified.width;
    final double minTop = _pinchWindow.top - safe.bottom * magnified.height;
    final double maxTop = _pinchWindow.top - safe.top * magnified.height;
    final double left = topLeft.dx.clamp(
      math.min(minLeft, maxLeft),
      math.max(minLeft, maxLeft),
    );
    final double top = topLeft.dy.clamp(
      math.min(minTop, maxTop),
      math.max(minTop, maxTop),
    );
    return Rect.fromLTWH(left, top, magnified.width, magnified.height);
  }

  /// The point under [focal], in frame units.
  Offset _anchorAt(Offset focal, Rect picture) {
    if (picture.width <= 0 || picture.height <= 0) return Offset.zero;
    return Offset(
      (focal.dx - picture.left) / picture.width,
      (focal.dy - picture.top) / picture.height,
    );
  }

  /// The part of the picture that sits under [window], in frame units.
  Rect _regionUnder(Rect picture, Rect window) => Rect.fromLTWH(
    (window.left - picture.left) / picture.width,
    (window.top - picture.top) / picture.height,
    window.width / picture.width,
    window.height / picture.height,
  );

  /// The magnification at which the cropped region would fall below the
  /// smallest window the crop allows.
  double _maxZoomFor(Rect picture, Size source) {
    final Rect safe = widget.spec.safeRect(source);
    final double minSide = safe.shortestSide * CropSpec.kMinFraction;
    if (minSide <= 0 || picture.width <= 0 || picture.height <= 0) {
      return _zoomCeiling;
    }
    // The window is frozen; the picture grows under it, so the region the
    // window covers shrinks. That region must stay at least [minSide] wide
    // and tall, or the exporter would be asked for an impossible crop.
    final double byWidth =
        _pinchWindow.width * _zoom / (picture.width * minSide);
    final double byHeight =
        _pinchWindow.height * _zoom / (picture.height * minSide);
    return math.min(_zoomCeiling, math.min(byWidth, byHeight));
  }

  CropCorner? _cornerNear(Offset point, Rect window) {
    CropCorner? best;
    double bestDistance = _handleHit;
    for (final corner in CropCorner.values) {
      final Offset at = corner.pointIn(window);
      final double d = (at - point).distance;
      if (d < bestDistance) {
        bestDistance = d;
        best = corner;
      }
    }
    return best;
  }
}

/// Dimmed surround + thirds grid + corner brackets, in one paint.
class _CropFramePainter extends CustomPainter {
  _CropFramePainter({
    required this.window,
    required this.frame,
    required this.colors,
  });

  final Rect window;

  /// The picture's own box. The scrim stops there: the area around the
  /// photo keeps the editor's background, like every other tool.
  final Rect frame;

  final CropPalette colors;

  @override
  void paint(Canvas canvas, Size size) {
    // 1. Dim the picture outside the window, punch the window back out.
    final Path scrim = Path.combine(
      PathOperation.difference,
      Path()..addRect(frame),
      Path()..addRect(window),
    );
    canvas.drawPath(scrim, Paint()..color = colors.scrim);

    // 2. Thirds inside the window.
    final Paint grid = Paint()
      ..color = colors.grid
      ..strokeWidth = 0.5;
    for (var i = 1; i < 3; i++) {
      final double x = window.left + window.width * i / 3;
      final double y = window.top + window.height * i / 3;
      canvas.drawLine(Offset(x, window.top), Offset(x, window.bottom), grid);
      canvas.drawLine(Offset(window.left, y), Offset(window.right, y), grid);
    }

    // 3. Corner brackets: short Ls, not a full border. The window is already
    //    legible from the contrast with the scrim, so a rectangle would only
    //    add noise.
    final Paint bracket = Paint()
      ..color = colors.bracket
      ..strokeWidth = 2
      ..strokeCap = StrokeCap.round;
    const double arm = 22;
    for (final corner in CropCorner.values) {
      final Offset p = corner.pointIn(window);
      final double dx = corner.x < 0 ? 1 : -1;
      final double dy = corner.y < 0 ? 1 : -1;
      canvas.drawLine(p, p.translate(arm * dx, 0), bracket);
      canvas.drawLine(p, p.translate(0, arm * dy), bracket);
    }
  }

  @override
  bool shouldRepaint(_CropFramePainter old) =>
      old.window != window || old.frame != frame || old.colors != colors;
}

/// Tiny palette so the painter does not reach into the widget tree.
@immutable
class CropPalette {
  const CropPalette({
    required this.scrim,
    required this.grid,
    required this.bracket,
  });

  factory CropPalette.of(BuildContext context) {
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    return CropPalette(
      // Light theme needs a stronger scrim: the surface behind the photo is
      // already light, so a faint wash would not read as "outside".
      scrim: dark ? const Color(0xCC000000) : const Color(0xB3000000),
      grid: dark ? const Color(0x4DFFFFFF) : const Color(0x40000000),
      bracket: const Color(0xFFFFFFFF),
    );
  }

  final Color scrim;
  final Color grid;
  final Color bracket;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CropPalette &&
          other.scrim == scrim &&
          other.grid == grid &&
          other.bracket == bracket;

  @override
  int get hashCode => Object.hash(scrim, grid, bracket);
}

/// Extension used by the stage; kept here so the painter stays self-contained.
extension CropThemeColors on BuildContext {
  CropPalette get themeColorsLikeCrop => CropPalette.of(this);
}
