import 'package:lens/features/adjust/adjust_state.dart' show AdjustParams;
import 'package:lens/features/blur/blur_state.dart' show BlurState;
import 'package:lens/features/crop/crop_spec.dart' show CropSpec;
import 'package:lens/features/filters/lut_definition.dart' show LensFilterId;
import 'package:lens/features/rays/rays_state.dart' show RaysState;
import 'package:lens/features/selective/selective_state.dart' show SelectiveState;

/// One undo-history entry: the full undoable grade (adjust + filter +
/// enhance + selective + blur + rays). A record, so snapshots compare by
/// value in `EditorStateNotifier`.
typedef GradeSnapshot = ({
  AdjustParams adjust,
  LensFilterId filterId,
  double filterStrength,
  double enhanceStrength,
  SelectiveState selective,
  BlurState blur,
  RaysState rays,
  CropSpec crop,
});
