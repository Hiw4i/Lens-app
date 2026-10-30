import 'package:lens/features/crop/crop_spec.dart';
import 'package:lens/features/editor/logic/editor_state.dart';

/// Crop geometry export bridge.
///
/// Crop never reaches [LensParams] — it is geometry, not a grade — so it
/// travels to the isolate as its own flat record of plain doubles (a custom
/// class is not Sendable). Null when the photo is uncropped and unrotated, so
/// the exporter can skip the resample entirely.
extension CropExport on EditorState {
  CropGeometry? encodeCropGeometry() {
    final CropSpec spec = crop;
    if (spec.isDefault) return null;
    return (
      angleDegrees: spec.angleDegrees,
      left: spec.rect.left,
      top: spec.rect.top,
      width: spec.rect.width,
      height: spec.rect.height,
      quarterTurns: spec.quarterTurns,
    );
  }
}
