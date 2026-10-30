import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/selective/mask_raster.dart';
import 'package:lens/features/selective/selective_mask.dart' show SelectiveMode;

/// Brush export bridge (Task 4.4).
///
/// `toLensParams` carries the selective grade but NEVER the raster (like a
/// LUT id travels without its table): strokes cross the isolate boundary
/// as flat doubles via [ExportService.export] `brushStrokesFlat`, which
/// rasterizes them in-isolate at [kBrushExportMaskSize].
extension SelectiveBrushExport on EditorState {
  /// Flat [encodeBrushStrokes] encoding of the painted strokes, or null
  /// when there is nothing to rasterize: selective off, mode not brush,
  /// or no stroke with points (the Task 4.3 concern #2 fallback — brush
  /// mode with empty strokes grades nothing, and `toLensParams` maps it
  /// to selMode 0 for the same reason).
  List<double>? encodeSelectiveBrush() {
    final SelectiveState sel = selective;
    if (!sel.active || sel.mode != SelectiveMode.brush) return null;
    final List<BrushStroke> painted = sel.strokes
        .where((s) => s.points.isNotEmpty)
        .toList();
    if (painted.isEmpty) return null;
    return encodeBrushStrokes(painted);
  }
}