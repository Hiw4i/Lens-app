/// Editing tool rail selection.
///
/// Enhance has no tool of its own: it is a card inside the Adjust
/// carousel, so the rail stays for the tools a photo is composed with.
enum EditorTool { filters, adjust, selective, blur, rays, crop }

/// Cap for the undo/redo stacks in `EditorStateNotifier`.
const int kHistoryLimit = 20;

/// TG-like 1-tap Enhance default strength, UI units 0..100.
const double kEnhanceOneTapStrength = 70;

/// 1-tap Blur default strength, UI units 0..100 (Task 6.4).
/// Mirrors the Enhance one-tap contract: default 0 = off, tap turns on.
const double kBlurOneTapStrength = 60;

/// 1-tap Rays default strength, UI units 0..100 (Task 7.4).
/// Mirrors the Blur one-tap contract: default 0 = off, tap turns on at 65
/// with the sun at the default (.5, .2) when previously off.
const double kRaysOneTapStrength = 65;
