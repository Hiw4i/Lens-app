import 'package:image/image.dart' as img;

import 'package:lens/features/crop/crop_spec.dart';

/// Applies crop + straighten to a decoded image.
///
/// Two stages, in the same order the preview composes them:
///
/// 1. **Quarter turns** — `quarterTurns * 90°` in one call, sampled
///    [img.Interpolation.nearest]. A multiple of 90° maps pixel centres onto
///    pixel centres, so nearest is not just cheap here, it is exact: no
///    resampling loss on the rotation the user only nudged a degree at a time.
/// 2. **Straighten** — [angleDegrees] on top, sampled [img.Interpolation.cubic]
///    because this one is genuinely fractional.
///
/// The crop window is then cut from the size the rotations ACTUALLY produced,
/// not from a size predicted up front. That is deliberate: it makes the
/// exporter immune to any difference in bounding-box convention between this
/// code, `package:image` and the preview's widget transform. All three agree
/// on "the frame that came out", and the normalized window maps onto it.
img.Image applyCropGeometry(img.Image src, CropGeometry crop) {
  img.Image out = src;
  final int turns = crop.quarterTurns % 4;
  if (turns != 0) {
    out = img.copyRotate(
      out,
      angle: turns * 90.0,
      interpolation: img.Interpolation.nearest,
    );
  }
  if (crop.angleDegrees != 0) {
    out = img.copyRotate(
      out,
      angle: crop.angleDegrees,
      interpolation: img.Interpolation.cubic,
    );
  }

  // A window covering (almost) everything is a no-op crop: skip the second
  // full-frame copy, which is pure cost for identical output.
  final bool wholeFrame =
      crop.left <= 0.0001 &&
      crop.top <= 0.0001 &&
      crop.width >= 0.9999 &&
      crop.height >= 0.9999;
  if (wholeFrame) return out;

  final int w = out.width;
  final int h = out.height;
  if (w <= 0 || h <= 0) return out;

  final int cw = (crop.width * w).round().clamp(1, w);
  final int ch = (crop.height * h).round().clamp(1, h);
  final int cx = (crop.left * w).round().clamp(0, w - cw);
  final int cy = (crop.top * h).round().clamp(0, h - ch);
  if (cx == 0 && cy == 0 && cw == w && ch == h) return out;

  return img.copyCrop(out, x: cx, y: cy, width: cw, height: ch);
}
