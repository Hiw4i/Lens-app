import 'dart:math' as math;
import 'dart:ui';

/// Aspect presets offered by the crop panel.
///
/// [free] is the null-ratio member: it keeps whatever shape the user dragged.
/// Every other value is width / height, and locking one keeps the window in
/// that shape while it is moved and resized.
enum CropRatio {
  free(null),
  square(1.0),
  portrait4x5(4 / 5),
  portrait3x4(3 / 4),
  landscape3x2(3 / 2),
  landscape4x3(4 / 3),
  landscape16x9(16 / 9),
  portrait9x16(9 / 16);

  const CropRatio(this.value);

  /// Width / height, or null for [free].
  final double? value;

  String get label => switch (this) {
    CropRatio.free => 'Free',
    CropRatio.square => '1:1',
    CropRatio.portrait4x5 => '4:5',
    CropRatio.portrait3x4 => '3:4',
    CropRatio.landscape3x2 => '3:2',
    CropRatio.landscape4x3 => '4:3',
    CropRatio.landscape16x9 => '16:9',
    CropRatio.portrait9x16 => '9:16',
  };
}

/// Which corner of the crop window a resize drag owns.
///
/// Public because the pure [CropSpec.resizeWindow] maths is tested without a
/// widget tree; the stage only translates pointer travel into normalized
/// units and calls it.
enum CropCorner {
  topLeft(-1, -1),
  topRight(1, -1),
  bottomLeft(-1, 1),
  bottomRight(1, 1);

  const CropCorner(this.x, this.y);

  /// -1 for the left/top edge, +1 for the right/bottom edge.
  final int x;
  final int y;

  Offset pointIn(Rect rect) =>
      Offset(x < 0 ? rect.left : rect.right, y < 0 ? rect.top : rect.bottom);

  CropCorner get opposite => switch (this) {
    CropCorner.topLeft => CropCorner.bottomRight,
    CropCorner.topRight => CropCorner.bottomLeft,
    CropCorner.bottomLeft => CropCorner.topRight,
    CropCorner.bottomRight => CropCorner.topLeft,
  };
}

/// The crop tool's complete geometry.
///
/// Deliberately a pure value type with no Flutter widget dependencies beyond
/// [Rect]/[Size]/[Offset] from `dart:ui`, so BOTH the preview overlay and the
/// CPU exporter derive their maths from this one file and cannot drift apart.
///
/// Two coordinate frames are in play and it is worth naming them:
///
/// * **turned frame** — the source after `quarterTurns` 90° steps. Its size
///   is [turnedSize].
/// * **rotated frame** — the turned image rotated by [angleDegrees] about its
///   centre, so its size is the bounding box of that rotation, [rotatedSize].
///   Straightening always *grows* this box (the corners go transparent),
///   which is why [rect] is re-fitted after every angle change.
///
/// [rect] is always normalized (0..1) against the **rotated** frame, so it
/// survives a source-resolution change (preview vs full-res export) and is
/// directly usable by the exporter.
class CropSpec {
  const CropSpec({
    this.quarterTurns = 0,
    this.angleDegrees = 0,
    this.rect = const Rect.fromLTWH(0, 0, 1, 1),
    this.ratio,
  });

  /// Source-after-quarter-turns rect covering the whole rotated frame.
  static const Rect kFullRect = Rect.fromLTWH(0, 0, 1, 1);

  /// 90° steps clockwise, 0..3. Driven by the panel's rotate button.
  final int quarterTurns;

  /// Straightening angle in degrees, clamped to [kMaxAngleDegrees].
  ///
  /// Positive rotates the photo clockwise on screen, matching both
  /// `Transform.rotateZ` in the preview and `img.copyRotate` in the exporter.
  final double angleDegrees;

  /// Crop window, normalized 0..1 against the rotated frame.
  final Rect rect;

  /// Locked width/height of the crop window, or null for a free shape.
  final double? ratio;

  /// Straightening past this starts showing nothing but empty corners, and
  /// no real photo needs it.
  static const double kMaxAngleDegrees = 45;

  /// Smallest crop window, as a fraction of the rotated frame's shorter side.
  /// Stops a drag from collapsing the frame to nothing.
  static const double kMinFraction = 0.12;

  /// Nominal source size used to turn normalized crop geometry into layout
  /// sizes.
  ///
  /// Crop geometry is scale-invariant — everything downstream is a ratio — so
  /// the absolute value cancels out. It only has to be CONSISTENT between the
  /// panel and the stage, which is why both call this rather than picking
  /// their own numbers.
  ///
  /// An invalid aspect must never produce an infinite or negative size: this
  /// value is fed straight into layout, where `Size(1000, Infinity)` would
  /// become a red error widget instead of a crop frame.
  static Size nominalSource(double aspect) {
    if (!aspect.isFinite || aspect <= 0) return const Size(1000, 1000);
    return aspect >= 1 ? Size(1000 * aspect, 1000) : Size(1000, 1000 / aspect);
  }

  bool get isDefault =>
      quarterTurns == 0 &&
      angleDegrees == 0 &&
      ratio == null &&
      rect == kFullRect;

  CropSpec copyWith({
    int? quarterTurns,
    double? angleDegrees,
    Rect? rect,
    double? ratio,
    bool clearRatio = false,
  }) => CropSpec(
    quarterTurns: quarterTurns ?? this.quarterTurns,
    angleDegrees: angleDegrees ?? this.angleDegrees,
    rect: rect ?? this.rect,
    ratio: clearRatio ? null : (ratio ?? this.ratio),
  );

  /// Source size after [quarterTurns].
  Size turnedSize(Size source) =>
      quarterTurns.isOdd ? Size(source.height, source.width) : source;

  /// Size of the rotated frame: the bounding box of the turned image rotated
  /// by [angleDegrees] about its centre.
  Size rotatedSize(Size source) {
    final Size turned = turnedSize(source);
    if (!angleDegrees.isFinite || angleDegrees == 0) return turned;
    final double t = angleDegrees * math.pi / 180.0;
    final double c = math.cos(t).abs();
    final double s = math.sin(t).abs();
    return Size(
      turned.width * c + turned.height * s,
      turned.width * s + turned.height * c,
    );
  }

  /// The crop window expressed in PIXELS of the rotated frame — the frame
  /// both the overlay and the exporter reason about.
  Rect pixelRect(Size source) {
    final Size frame = rotatedSize(source);
    return Rect.fromLTWH(
      rect.left * frame.width,
      rect.top * frame.height,
      rect.width * frame.width,
      rect.height * frame.height,
    );
  }

  /// Width / height of the visible result after quarter turns, straighten
  /// and the crop window. Falls back to the source aspect for degenerate
  /// geometry so callers can feed it straight into layout.
  double resultAspect(Size source) {
    if (source.width <= 0 || source.height <= 0) return 1;
    final double fallback = source.width / source.height;
    if (isDefault) return fallback;
    final Rect window = pixelRect(source);
    if (!window.isFinite || window.width <= 0 || window.height <= 0) {
      return fallback;
    }
    return window.width / window.height;
  }

  /// Largest [ratio]-shaped rect centred in [bounds]; [bounds] itself when
  /// [ratio] is null.
  static Rect largestWithRatio(Rect bounds, double? ratio) {
    if (ratio == null || !ratio.isFinite || ratio <= 0) return bounds;
    final double bw = bounds.width;
    final double bh = bounds.height;
    if (bw <= 0 || bh <= 0) return bounds;
    // bounds aspect (w/h) vs wanted aspect.
    final double boundsAspect = bw / bh;
    if (boundsAspect > ratio) {
      // Bounds are wider than we want: full height, narrower width.
      final double w = bh * ratio;
      return Rect.fromLTWH(bounds.left + (bw - w) / 2, bounds.top, w, bh);
    }
    final double h = bw / ratio;
    return Rect.fromLTWH(bounds.left, bounds.top + (bh - h) / 2, bw, h);
  }

  /// The largest centred axis-aligned rect with the photo's own aspect that
  /// is still fully covered by pixels after straightening.
  ///
  /// The rotated frame is the bounding box of the turned photo, so its corners
  /// are transparent. Scaling the turned photo's rect down until its corners
  /// fit inside that box is the simple conservative bound used by the window:
  /// any sub-rect of it is guaranteed to contain real pixels. At 0° it is the
  /// full frame.
  ///
  /// Returned normalized against the rotated frame.
  Rect safeRect(Size source) {
    final Size turned = turnedSize(source);
    final Size frame = rotatedSize(source);
    if (!turned.isFinite ||
        turned.isEmpty ||
        !frame.isFinite ||
        frame.isEmpty) {
      return kFullRect;
    }
    if (angleDegrees == 0) return kFullRect;
    final double scale = math
        .min(turned.width / frame.width, turned.height / frame.height)
        .clamp(0.0, 1.0)
        .toDouble();
    final double width = scale * turned.width / frame.width;
    final double height = scale * turned.height / frame.height;
    return Rect.fromLTWH((1 - width) / 2, (1 - height) / 2, width, height);
  }

  /// [safeRect] in pixels of the rotated frame.
  Rect safePixelRect(Size source) {
    final Size frame = rotatedSize(source);
    if (!frame.isFinite || frame.isEmpty) return Rect.zero;
    final Rect safe = safeRect(source);
    return Rect.fromLTWH(
      safe.left * frame.width,
      safe.top * frame.height,
      safe.width * frame.width,
      safe.height * frame.height,
    );
  }

  /// Keeps [candidate] inside [bounds] and never smaller than
  /// [kMinFraction] of it.
  ///
  /// Both rects must be in the SAME space. The crop window passes the
  /// normalized safe area, not the full frame, so straightening cannot leave
  /// transparent corners inside the export.
  Rect clamp(Rect candidate, Rect bounds) {
    if (bounds.width <= 0 || bounds.height <= 0) return candidate;
    final double minW = bounds.shortestSide * kMinFraction;
    final double minH = bounds.shortestSide * kMinFraction;
    final double w = candidate.width
        .clamp(math.min(minW, bounds.width), bounds.width)
        .toDouble();
    final double h = candidate.height
        .clamp(math.min(minH, bounds.height), bounds.height)
        .toDouble();
    // `safeRect` is computed with divisions, so `top + height` can land one
    // ulp below `bottom`. Clamping against a limit that is a hair below the
    // lower bound would throw; max() makes the degenerate full-height case
    // stick to the top edge instead.
    final double maxLeft = math.max(bounds.left, bounds.right - w);
    final double maxTop = math.max(bounds.top, bounds.bottom - h);
    return Rect.fromLTWH(
      candidate.left.clamp(bounds.left, maxLeft).toDouble(),
      candidate.top.clamp(bounds.top, maxTop).toDouble(),
      w,
      h,
    );
  }

  /// Fits a candidate window into the safe area without changing its intent.
  ///
  /// A free window is only clamped. A locked one is converted to pixels first
  /// because [ratio] is a PIXEL aspect: normalized units look square at any
  /// photo aspect. The locked branch preserves the candidate's centre and as
  /// much size as the safe area allows; it deliberately does NOT jump back to
  /// the largest matching shape. That jump made a locked window impossible to
  /// move or shrink — every update re-centred it. [withRatio] is the explicit
  /// "maximise this lock" operation.
  Rect fitRect(Rect candidate, Size source) {
    final Size frame = rotatedSize(source);
    final Rect safe = safeRect(source);
    if (!frame.isFinite ||
        frame.isEmpty ||
        safe.isEmpty ||
        !candidate.isFinite) {
      return kFullRect;
    }
    final double? lock = ratio;
    if (lock == null || !lock.isFinite || lock <= 0) {
      return clamp(candidate, safe);
    }
    return _fitRatio(candidate, frame, safePixelRect(source), lock);
  }

  Rect _fitRatio(Rect candidate, Size frame, Rect safe, double lock) {
    if (safe.isEmpty) return kFullRect;
    final Rect candidatePx = Rect.fromLTWH(
      candidate.left * frame.width,
      candidate.top * frame.height,
      candidate.width * frame.width,
      candidate.height * frame.height,
    );
    final double maxW = safe.width;
    final double maxH = safe.height;
    final double minSide = kMinFraction * math.min(frame.width, frame.height);

    double w = candidatePx.width;
    if (!w.isFinite || w <= 0) w = maxW;
    w = w.clamp(math.min(minSide, maxW), maxW).toDouble();
    double h = w / lock;
    if (h > maxH) {
      h = maxH;
      w = h * lock;
    }
    if (w > maxW) {
      w = maxW;
      h = w / lock;
    }
    final double minW = math.min(minSide, maxW);
    final double minH = math.min(minSide / lock, maxH);
    if (w < minW) {
      w = minW;
      h = w / lock;
    }
    if (h < minH) {
      h = minH;
      w = h * lock;
    }
    if (w > maxW) {
      w = maxW;
      h = w / lock;
    }
    if (h > maxH) {
      h = maxH;
      w = h * lock;
    }

    final double left = (candidatePx.center.dx - w / 2)
        .clamp(safe.left, math.max(safe.left, safe.right - w))
        .toDouble();
    final double top = (candidatePx.center.dy - h / 2)
        .clamp(safe.top, math.max(safe.top, safe.bottom - h))
        .toDouble();
    return _normalize(Rect.fromLTWH(left, top, w, h), frame);
  }

  /// Re-fits [rect] after a geometry change where the frame itself moved
  /// (angle or quarter turn).
  ///
  /// Preserving the NORMALIZED rect would change the window's pixel size when
  /// the rotated bbox grows, so a user who had shrunk the window would see it
  /// grow back. Instead the previous pixel size and centre are projected onto
  /// the new frame and then clamped by [fitRect].
  CropSpec refittedFrom(CropSpec previous, Size source) {
    final Size frame = rotatedSize(source);
    final Size previousFrame = previous.rotatedSize(source);
    if (!frame.isFinite ||
        frame.isEmpty ||
        !previousFrame.isFinite ||
        previousFrame.isEmpty) {
      return refitted(source);
    }
    final Rect previousPixels = previous.pixelRect(source);
    final Rect candidate = Rect.fromCenter(
      center: Offset(
        rect.center.dx * frame.width,
        rect.center.dy * frame.height,
      ),
      width: previousPixels.width,
      height: previousPixels.height,
    );
    return copyWith(rect: fitRect(_normalize(candidate, frame), source));
  }

  /// Re-fits [rect] against the current frame. Used for direct window edits
  /// and source-size changes; see [refittedFrom] for angle/turn changes.
  CropSpec refitted(Size source) => copyWith(rect: fitRect(rect, source));

  /// Locks [value] and snaps to the largest matching shape in the safe area.
  /// Null clears the lock and simply re-fits the current window. An invalid
  /// non-null value is ignored rather than stored, so a bad caller cannot
  /// leave a NaN in [ratio] or silently unlock the window.
  CropSpec withRatio(double? value, Size source) {
    if (value != null && (!value.isFinite || value <= 0)) {
      return refitted(source);
    }
    final CropSpec base = copyWith(ratio: value, clearRatio: value == null);
    if (value == null) return base.refitted(source);
    final Size frame = rotatedSize(source);
    final Rect safe = safePixelRect(source);
    if (!frame.isFinite || frame.isEmpty || safe.isEmpty) return base;
    return base.copyWith(
      rect: _normalize(largestWithRatio(safe, value), frame),
    );
  }

  /// A corner-drag candidate in normalized coordinates.
  ///
  /// [drag] is the total pointer travel expressed in normalized frame units;
  /// [start] is the window frozen at gesture start. With a locked [ratio] the
  /// whole shape scales from the opposite corner, so the aspect never changes
  /// and that anchor stays put while the finger moves.
  Rect resizeWindow({
    required Rect start,
    required CropCorner corner,
    required Offset drag,
    required Size source,
  }) {
    final Size frame = rotatedSize(source);
    if (!start.isFinite || !drag.isFinite || !frame.isFinite || frame.isEmpty) {
      return start;
    }
    final Rect startPx = Rect.fromLTWH(
      start.left * frame.width,
      start.top * frame.height,
      start.width * frame.width,
      start.height * frame.height,
    );
    final Offset dragPx = Offset(drag.dx * frame.width, drag.dy * frame.height);
    final double? lock = ratio;
    if (lock == null || !lock.isFinite || lock <= 0) {
      final Offset moving = corner.pointIn(startPx) + dragPx;
      double left = startPx.left;
      double top = startPx.top;
      double right = startPx.right;
      double bottom = startPx.bottom;
      if (corner.x < 0) {
        left = moving.dx;
      } else {
        right = moving.dx;
      }
      if (corner.y < 0) {
        top = moving.dy;
      } else {
        bottom = moving.dy;
      }
      if (right < left) {
        final double swap = left;
        left = right;
        right = swap;
      }
      if (bottom < top) {
        final double swap = top;
        top = bottom;
        bottom = swap;
      }
      return _normalize(Rect.fromLTRB(left, top, right, bottom), frame);
    }

    final Rect safe = safePixelRect(source);
    final Offset anchor = corner.opposite.pointIn(startPx);
    final double startW = startPx.width;
    final double startH = startPx.height;
    if (startW <= 0 || startH <= 0 || safe.isEmpty) return start;
    final Offset moving = corner.pointIn(startPx) + dragPx;
    final double rawW = (corner.x < 0 ? -1 : 1) * (moving.dx - anchor.dx);
    final double rawH = (corner.y < 0 ? -1 : 1) * (moving.dy - anchor.dy);
    final double rawScale = math.max(rawW / startW, rawH / startH);
    final double maxW = corner.x < 0
        ? anchor.dx - safe.left
        : safe.right - anchor.dx;
    final double maxH = corner.y < 0
        ? anchor.dy - safe.top
        : safe.bottom - anchor.dy;
    final double minSide = kMinFraction * math.min(frame.width, frame.height);
    final double minScale = math.max(minSide / startW, minSide / startH);
    final double maxScale = math.min(maxW / startW, maxH / startH);
    final double scale = rawScale
        .clamp(math.min(minScale, maxScale), maxScale)
        .toDouble();
    double w = startW * scale;
    double h = w / lock;
    if (h > maxH) {
      h = maxH;
      w = h * lock;
    }
    if (w > maxW) {
      w = maxW;
      h = w / lock;
    }
    final double left = corner.x < 0 ? anchor.dx - w : anchor.dx;
    final double top = corner.y < 0 ? anchor.dy - h : anchor.dy;
    return _normalize(Rect.fromLTWH(left, top, w, h), frame);
  }

  static Rect _normalize(Rect pixels, Size frame) => Rect.fromLTWH(
    pixels.left / frame.width,
    pixels.top / frame.height,
    pixels.width / frame.width,
    pixels.height / frame.height,
  );

  /// The window's current pixel shape (width / height), or null when the
  /// rect is degenerate.
  double? get rectAspect {
    if (rect.height <= 0) return null;
    return rect.width / rect.height;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is CropSpec &&
          other.quarterTurns == quarterTurns &&
          other.angleDegrees == angleDegrees &&
          other.ratio == ratio &&
          other.rect == rect;

  @override
  int get hashCode => Object.hash(quarterTurns, angleDegrees, ratio, rect);

  @override
  String toString() =>
      'CropSpec(turns: $quarterTurns, angle: $angleDegrees, '
      'ratio: $ratio, rect: $rect)';
}

/// Crop geometry flattened for the export isolate.
///
/// A record of plain doubles because custom classes are NOT Sendable and this
/// value crosses an isolate boundary.
typedef CropGeometry = ({
  double angleDegrees,
  double left,
  double top,
  double width,
  double height,
  int quarterTurns,
});
