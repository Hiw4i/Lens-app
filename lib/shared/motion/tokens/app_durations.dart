/// Motion duration scale.
///
/// Lives next to the `UiPerformancePolicy` that scales it: every value
/// below is motion (never a timer, delay or timeout) and is meant to be
/// consumed through `policy.motionDuration/colorDuration/stateChangeDuration`.
///
/// Durations intentionally left outside this scale (audited 2026-09-06).
/// Do not "normalize" them without a design decision — each group has a
/// reason to stay off-token:
/// * Named domain constants with their own single source of truth:
///   library grid transitions (`content_zoom_swap.dart`), navigation motion,
///   policy transitions (`UiPerformancePolicy`), editor tool-rail timings
///   (`tool_rail.dart`), press animations (`pressable_scale.dart`),
///   lifecycle and session timeouts.
/// * One-off motion values tuned per widget (25–1800 ms in backgrounds,
///   dialogs, charts, sheets and paginators).
/// * Sequencing delays (`Future.delayed`, `Timer`, `dragStartDelay`) and
///   second-based timeouts — delays are not motion.
/// * Data conversions (`Duration(milliseconds: someDbValue)`) — not motion.
class AppDurations {
  AppDurations._();

  static const Duration fastest = Duration(milliseconds: 220);
  static const Duration fast = Duration(milliseconds: 280);
  static const Duration normal = Duration(milliseconds: 300);
  static const Duration medium = Duration(milliseconds: 350);
  static const Duration pressDown = Duration(milliseconds: 170);
  static const Duration press = Duration(milliseconds: 400);
  static const Duration slow = Duration(milliseconds: 600);

  /// How long transient banners / auto-hidden chrome stay visible.
  /// Replaces scattered `Timer(const Duration(seconds: 3))` copies.
  static const Duration bannerHide = Duration(seconds: 3);
}
