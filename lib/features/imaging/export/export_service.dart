import 'dart:async';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/selective/mask_raster.dart';

/// Error thrown by [ExportService.export].
///
/// [LensCpuException] (bad input / unsupported format) propagates unwrapped
/// so callers can match on it; OOM and unexpected isolate failures arrive
/// as [ExportException] with a human-readable [message].
class ExportException implements Exception {
  ExportException(this.message, [this.cause]);
  final String message;
  final Object? cause;

  @override
  String toString() =>
      'ExportException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Isolate payload: raw source bytes + grade as plain doubles + LUT id +
/// flat brush strokes.
///
/// A record of Sendable scalars/containers is used instead of passing
/// [LensParams] because `Uint8List` + `List<double>` + `int` are
/// guaranteed Sendable; [LensParams] is not (its library transitively
/// imports `flutter_riverpod`). The doubles follow [LensParams.toUniforms]
/// order; [filterId] (`LensFilterId.index`, 0..8) travels as a separate
/// int because a LUT id is categorical — it selects a texture/table, never
/// a float uniform. The LUT table itself is generated inside the isolate
/// (see `_lutCache` in `lens_cpu.dart`), so no megabyte-sized table
/// crosses the isolate boundary.
///
/// [brushFlat] carries brush strokes as [encodeBrushStrokes] output (a few
/// dozen plain doubles — cheap across the boundary, unlike the 256x256 =
/// 256KB raster, which is therefore rebuilt INSIDE the isolate via
/// [decodeBrushStrokes] + [rasterizeBrushMask] at [kBrushExportMaskSize]).
/// Null or empty means "no brush" (brush-mode selective then grades
/// nothing — see the divergence note in `lens_cpu.dart`). `BrushStroke`
/// itself never crosses the boundary (custom class = not Sendable).
///
/// [blurMask256] carries the READY subject mask (row-major square 0..1,
/// 1 = subject stays sharp — production passes 256x256: the
/// `BlurCache.get` output for auto mode or the manual raster, resolved by
/// the UI in Task 6.4). Unlike the brush strokes it crosses the boundary
/// AS the raster: the ML mask already exists on the UI side as a
/// `Float32List` (recomputing it in-isolate is impossible — no platform
/// channel there), and one 256KB copy per export is acceptable for a
/// one-shot op. `Float32List` is Sendable (structured-clone copy), so no
/// wrapper is needed. Null means "no mask" — an active blur block then
/// stays neutral (see `lens_cpu.dart`).
typedef _IsolateArgs = ({
  Uint8List bytes,
  List<double> uniforms,
  int filterId,
  List<double>? brushFlat,
  Float32List? blurMask256,
  CropGeometry? crop,
});

/// Isolate entry: must stay top-level for `Isolate.run`.
Uint8List _runGrade(_IsolateArgs args) {
  final List<double>? flat = args.brushFlat;
  final ({Float32List mask, int size})? brush = (flat == null || flat.isEmpty)
      ? null
      : (
          mask: rasterizeBrushMask(
            decodeBrushStrokes(flat),
            kBrushExportMaskSize,
          ),
          size: kBrushExportMaskSize,
        );
  return applyLensGrade(
    args.bytes,
    args.uniforms,
    args.filterId,
    brush,
    args.blurMask256,
    args.crop,
  );
}

/// Full-resolution CPU export of the Lens grade in a background isolate.
///
/// UI thread is never blocked by pixel work; callers `await` the result
/// and save/share the returned JPEG bytes.
abstract final class ExportService {
  /// Grades [srcBytes] with [params] and returns JPEG bytes (quality 95).
  ///
  /// [brushStrokesFlat] is the optional [encodeBrushStrokes] encoding of the
  /// brush strokes (Task 4.4 state will pass it; until then it stays null).
  /// Null or empty means "no brush". Non-empty input is rasterized inside
  /// the isolate, so only the flat doubles cross the boundary.
  ///
  /// [blurMask256] is the optional READY subject mask for the blur stage
  /// (Task 6.4 will pass `BlurCache.get` output or the manual raster;
  /// until then it stays null). Null means "no mask" (blur stays neutral
  /// even when active). The raster is copied across the boundary once per
  /// export (~256KB at 256x256) — acceptable for a one-shot op.
  ///
  /// [crop] is the optional crop + straighten geometry, as plain doubles
  /// (`EditorState.encodeCropGeometry`). Null for an untouched photo, in
  /// which case no resample runs at all. Applied BEFORE the grade so the
  /// exported pixels and the on-screen preview show the same frame.
  ///
  /// Throws [LensCpuException] for empty/unsupported input and
  /// [ExportException] when the device runs out of memory or the isolate
  /// fails unexpectedly.
  static Future<Uint8List> export({
    required Uint8List srcBytes,
    required LensParams params,
    List<double>? brushStrokesFlat,
    Float32List? blurMask256,
    CropGeometry? crop,
  }) async {
    final _IsolateArgs args = (
      bytes: srcBytes,
      uniforms: params.toUniforms(),
      filterId: params.filterId,
      brushFlat: brushStrokesFlat,
      blurMask256: blurMask256,
      crop: crop,
    );
    try {
      return await Isolate.run(() => _runGrade(args));
    } on OutOfMemoryError catch (e) {
      throw ExportException(
        'Not enough memory to export this photo. '
        'Try a smaller image or restart the app.',
        e,
      );
    } on LensCpuException {
      rethrow;
    } catch (e) {
      throw ExportException('Photo export failed.', e);
    }
  }
}
