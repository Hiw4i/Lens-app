import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:lens/features/crop/crop_spec.dart';

/// Shows only the cropped part of a source-sized child, rotated and
/// straightened exactly like the exporter.
///
/// The child is laid out at the SOURCE aspect, not at the viewport aspect.
/// That is what keeps interactive overlays honest: their local coordinates
/// stay in the source photo's uv space, which is also the frame the CPU grade
/// runs in (grade first, crop last). [RotatedBox] and [Transform] participate
/// in hit testing, so a finger that lands on the visible crop is mapped back
/// through the quarter turn and straighten before an overlay sees it.
///
/// The caller sizes this widget to the cropped result's aspect; the internal
/// scale then maps the crop window exactly onto the viewport. When the spec
/// is untouched the child is returned unchanged, so the normal preview takes
/// the old path with no extra layout or clip.
class CropViewport extends StatelessWidget {
  const CropViewport({
    super.key,
    required this.spec,
    required this.photoAspect,
    required this.child,
  });

  final CropSpec spec;

  /// Source width / height, before any quarter turn.
  final double photoAspect;

  /// Content laid out at the source aspect (photo and/or overlays).
  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (spec.isDefault) return child;
    final Size source = CropSpec.nominalSource(photoAspect);
    final Size frame = spec.rotatedSize(source);
    final Rect crop = spec.pixelRect(source);
    if (!frame.isFinite || frame.isEmpty || !crop.isFinite || crop.isEmpty) {
      return child;
    }
    return LayoutBuilder(
      builder: (context, constraints) {
        final Size area = Size(constraints.maxWidth, constraints.maxHeight);
        if (!area.isFinite || area.isEmpty) return const SizedBox.expand();
        final double scale = math.min(
          area.width / crop.width,
          area.height / crop.height,
        );
        if (!scale.isFinite || scale <= 0) return const SizedBox.expand();
        final Size shown = Size(crop.width * scale, crop.height * scale);
        // Centre when the parent gave a slightly different aspect (rounding
        // or a fractional device pixel); the crop window itself is exact.
        final Offset origin = Offset(
          (area.width - shown.width) / 2 - crop.left * scale,
          (area.height - shown.height) / 2 - crop.top * scale,
        );
        return ClipRect(
          child: Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: origin.dx,
                top: origin.dy,
                width: frame.width * scale,
                height: frame.height * scale,
                child: _TransformedSource(
                  spec: spec,
                  source: source,
                  scale: scale,
                  child: child,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// Quarter turns then straighten, in the same order as [CropViewport]'s
/// exporter counterpart (`applyCropGeometry`).
class _TransformedSource extends StatelessWidget {
  const _TransformedSource({
    required this.spec,
    required this.source,
    required this.scale,
    required this.child,
  });

  final CropSpec spec;
  final Size source;
  final double scale;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final Size turned = spec.turnedSize(source);
    final Size frame = spec.rotatedSize(source);
    Widget photo = SizedBox(
      width: source.width * scale,
      height: source.height * scale,
      child: child,
    );
    if (spec.quarterTurns != 0) {
      photo = RotatedBox(quarterTurns: spec.quarterTurns, child: photo);
    }
    return SizedBox(
      width: frame.width * scale,
      height: frame.height * scale,
      child: Center(
        child: Transform(
          alignment: Alignment.center,
          transform: Matrix4.identity()
            ..rotateZ(spec.angleDegrees * math.pi / 180.0),
          child: SizedBox(
            width: turned.width * scale,
            height: turned.height * scale,
            child: photo,
          ),
        ),
      ),
    );
  }
}
