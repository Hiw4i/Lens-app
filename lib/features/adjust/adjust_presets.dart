import 'package:lens/features/editor/logic/editor_state.dart';

/// Named Adjust starting points for the future preset UI (Task 1.4).
///
/// Values are in [AdjustParams] UI units: exposure in stops (-3..+3),
/// everything else in -100..100 (structure -100..100).
const AdjustParams kAdjustNatural = AdjustParams(
  exposure: 0.3,
  shadows: 20,
  highlights: -10,
);

const AdjustParams kAdjustPunchy = AdjustParams(
  contrast: 25,
  saturation: 15,
  structure: 30,
);

const AdjustParams kAdjustMuted = AdjustParams(
  contrast: -15,
  saturation: -25,
  structure: 10,
);
