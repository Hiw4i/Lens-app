import 'dart:isolate';
import 'dart:typed_data';

import 'package:google_mlkit_selfie_segmentation/google_mlkit_selfie_segmentation.dart';
import 'package:image/image.dart' as img;

/// Foreground-mask resolution (Task 6.1).
///
/// The ML Kit raw mask is 256 on each side (`enableRawSizeMask`); the
/// provider contract fixes the output at 256×256 and any native size is
/// bilinear-resampled here ([_resampleToSize]). Bilinear upsampling in the
/// 6.2 apply path smooths the rest — same reasoning as the 128 brush
/// raster in `mask_raster.dart`.
const int kSubjectMaskSize = 256;

/// Max long side of the bitmap handed to the segmenter.
///
/// Full-res JPEG bytes (e.g. 12 MP → ~48 MB RGBA) would be copied over the
/// method channel on every one-shot call while the raw model output is 256
/// anyway, so anything above 512 buys nothing but latency.
const int kSegmentInputMaxDim = 512;

/// Which subject mask the blur stage (этап 6) should use.
enum SubjectSource {
  /// ML Kit selfie segmentation; falls back to [manual] when unavailable.
  auto,

  /// Hand-painted brush raster from selective (`mask_raster.dart`, 6.4).
  manual,
}

/// Foreground-mask provider (Task 6.1).
///
/// Returns a `size × size` row-major mask in 0..1 (`1` = subject, stays
/// sharp) or `null` when no mask is available — the caller then switches
/// the UI to the manual brush. `null` is a normal outcome (desktop, no
/// subject, undecodable bytes), never an error.
///
/// **Never-throw contract:** implementations MUST NOT throw — every failure
/// maps to `null` inside the implementation, so callers (6.4) can `await`
/// without `try/catch`. Third-party providers of unknown provenance go
/// through [SafeSubjectMask], which enforces the contract from the outside.
///
/// The interface itself is pure `dart:typed_data` — Flutter enters only
/// inside [MlKitSubjectMask] via the plugin's method channel.
abstract interface class SubjectMaskProvider {
  /// Returns the `size × size` foreground mask, or `null` if unavailable.
  ///
  /// Never throws (see contract above).
  Future<Float32List?> foregroundMask(Uint8List bytes, {int size});
}

/// ML Kit selfie segmentation (Task 6.1).
///
/// One-shot per call: the JPEG [bytes] are decoded with `package:image`
/// (the plugin has no JPEG/RGBA `InputImageFormat` — only NV21/YUV/BGRA —
/// so the documented `InputImage.fromBitmap` raw-bitmap path is used),
/// downscaled to [kSegmentInputMaxDim], and sent through a fresh
/// [SelfieSegmenter] in [SegmenterMode.single] with `enableRawSizeMask`
/// (256), closed in `finally` — no long-lived native instance, no
/// lifecycle wiring. The native mask is bilinear-resampled to `size`.
///
/// Every exception (desktop `MissingPluginException`, undecodable bytes,
/// native errors) maps to `null`; this method never throws.
class MlKitSubjectMask implements SubjectMaskProvider {
  /// Creates a stateless one-shot provider (no native resources held).
  const MlKitSubjectMask();

  @override
  Future<Float32List?> foregroundMask(
    Uint8List bytes, {
    int size = kSubjectMaskSize,
  }) async {
    try {
      if (bytes.isEmpty || size <= 0) return null;
      // Decode + downscale + RGBA pack run on a worker isolate: a 12MP
      // `img.decodeImage` costs seconds and hundreds of MB transient, and
      // on the UI isolate it froze every frame of the photo open whenever
      // auto blur armed. The ML Kit call itself must stay HERE — the
      // plugin's method channel exists only on the root isolate.
      final ({Uint8List rgba, int width, int height})? packed =
          await Isolate.run(() => _decodeAndPack(bytes, kSegmentInputMaxDim));
      if (packed == null) return null;
      final InputImage input = InputImage.fromBitmap(
        bitmap: packed.rgba,
        width: packed.width,
        height: packed.height,
      );

      final SelfieSegmenter segmenter = SelfieSegmenter(
        mode: SegmenterMode.single,
        enableRawSizeMask: true,
      );
      try {
        final SegmentationMask? mask = await segmenter.processImage(input);
        if (mask == null) return null;
        return _resampleToSize(mask, size);
      } finally {
        // Guarded so a teardown failure can never discard a valid mask —
        // and never violate the never-throw contract.
        try {
          await segmenter.close();
        } catch (_) {
          // Native teardown is best-effort on this path.
        }
      }
    } catch (_) {
      // MissingPluginException on desktop/tests, undecodable bytes,
      // native errors, isolate failures — all map to null (manual
      // fallback). Never throws.
      return null;
    }
  }
}

/// Decode + aspect-fit + RGBA pack of the segmentation input. Top-level so
/// [Isolate.run] can reference it; never throws (any failure maps to null,
/// which the caller treats as "no mask").
({Uint8List rgba, int width, int height})? _decodeAndPack(
  Uint8List bytes,
  int maxDim,
) {
  try {
    final img.Image? decoded = img.decodeImage(bytes);
    if (decoded == null || decoded.width <= 0 || decoded.height <= 0) {
      return null;
    }
    final img.Image small = _fitInside(decoded, maxDim);
    return (rgba: _toRgba(small), width: small.width, height: small.height);
  } catch (_) {
    return null;
  }
}

/// Manual-brush signal (Task 6.1).
///
/// Always returns `null`: there is no automatic subject, the caller must
/// show the brush UI. Honest null, no fake mask — the hand-painted raster
/// itself is produced by the existing selective path (`mask_raster.dart`)
/// and wired in 6.4.
class ManualSubjectMask implements SubjectMaskProvider {
  /// Creates the always-null manual signal.
  const ManualSubjectMask();

  @override
  Future<Float32List?> foregroundMask(
    Uint8List bytes, {
    int size = kSubjectMaskSize,
  }) async => null;
}

/// Never-throw wrapper for providers of unknown provenance (Task 6.1).
///
/// [MlKitSubjectMask] and [ManualSubjectMask] already honor the contract
/// internally; this wrapper enforces it from the outside for fakes and
/// future third-party providers (synchronous and asynchronous throws both
/// map to `null`). [BlurCache] routes every call through it.
class SafeSubjectMask implements SubjectMaskProvider {
  /// Wraps [inner], mapping every throw to `null`.
  const SafeSubjectMask(this.inner);

  /// The wrapped provider.
  final SubjectMaskProvider inner;

  @override
  Future<Float32List?> foregroundMask(
    Uint8List bytes, {
    int size = kSubjectMaskSize,
  }) async {
    try {
      return await inner.foregroundMask(bytes, size: size);
    } catch (_) {
      return null;
    }
  }
}

/// Aspect-preserving fit of [src] inside a [maxDim] long side.
///
/// Returns [src] untouched when it already fits (no copy). Mirrors the
/// prewarm downscale in `enhance_cache.dart`.
img.Image _fitInside(img.Image src, int maxDim) {
  final int w = src.width;
  final int h = src.height;
  final int longSide = w > h ? w : h;
  if (longSide <= maxDim) return src;
  final int sw = (w * maxDim / longSide).round().clamp(1, w);
  final int sh = (h * maxDim / longSide).round().clamp(1, h);
  return img.copyResize(src, width: sw, height: sh);
}

/// Packs [image] pixels into raw RGBA bytes for `InputImage.fromBitmap`.
///
/// Normalizes once to 8-bit RGBA and returns the raw byte buffer, so no
/// per-pixel `getPixel` dispatch (and no boxed `num` getters) runs on the
/// worker isolate.
Uint8List _toRgba(img.Image image) {
  final img.Image flat = image.convert(
    format: img.Format.uint8,
    numChannels: 4,
  );
  return flat.data is img.ImageDataUint8
      ? (flat.data as img.ImageDataUint8).data
      : flat.getBytes();
}

/// Bilinear-resamples the native [SegmentationMask] to `size × size`.
///
/// Returns `null` on shape mismatch (`confidences.length != width*height`)
/// — a malformed native reply degrades to manual, like every other failure.
/// Output is clamped to 0..1. `1` = foreground (subject, stays sharp).
Float32List? _resampleToSize(SegmentationMask mask, int size) {
  final int sw = mask.width;
  final int sh = mask.height;
  final List<double> src = mask.confidences;
  if (sw <= 0 || sh <= 0 || src.length != sw * sh) return null;
  final Float32List out = Float32List(size * size);
  for (int y = 0; y < size; y++) {
    final double sy = ((y + 0.5) * sh / size - 0.5).clamp(
      0.0,
      (sh - 1).toDouble(),
    );
    final int y0 = sy.floor();
    final int y1 = (y0 + 1).clamp(0, sh - 1);
    final double fy = sy - y0;
    for (int x = 0; x < size; x++) {
      final double sx = ((x + 0.5) * sw / size - 0.5).clamp(
        0.0,
        (sw - 1).toDouble(),
      );
      final int x0 = sx.floor();
      final int x1 = (x0 + 1).clamp(0, sw - 1);
      final double fx = sx - x0;
      final double top =
          src[y0 * sw + x0] * (1.0 - fx) + src[y0 * sw + x1] * fx;
      final double bottom =
          src[y1 * sw + x0] * (1.0 - fx) + src[y1 * sw + x1] * fx;
      out[y * size + x] = (top * (1.0 - fy) + bottom * fy).clamp(0.0, 1.0);
    }
  }
  return out;
}
