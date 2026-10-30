/// Shared metrics for the editor's bottom control sheet.
///
/// The sheet is full-bleed (no outer insets) and sized to the tool panel it
/// currently hosts: sparse tools (Adjust, Filters) get a short sheet, dense
/// ones (Blur, Selective) get a taller one, and the editor animates between
/// the two while the preview re-composes to match. No tool scrolls
/// vertically, and [maxSheetHeight] is the ceiling that keeps the preview
/// readable on short screens.
class EditorPanelMetrics {
  EditorPanelMetrics._();

  /// Gap between the tool content and the divider above the rail.
  static const double railGap = 6;

  /// Height of the hairline divider between the panel and the tool rail.
  static const double railDividerHeight = 1;

  /// Tool rail (tab) row height.
  static const double railHeight = 48;

  /// Padding below the tool rail, above the bottom system inset.
  static const double bottomPadding = 6;

  /// Breathing room above and below a tool panel's own content.
  ///
  /// This is what gives Adjust / Filters their compact sheet: they have far
  /// less to show than Blur, so their sheet is correspondingly shorter.
  static const double bodyPadding = 8;

  /// Upper bound for a sheet, used as the pre-measurement placeholder and
  /// as the clamp on very short screens.
  ///
  /// Sized just above the tallest real panel — Selective (and Blur) with the
  /// mask active: 241 of body plus rail, divider and insets comes to 326 —
  /// so the clamp never bites on a normal phone. It only engages below a
  /// ~610dp-tall screen, where the sheet must yield to the preview anyway.
  static const double maxSheetHeight = 336;

  /// Height of the sheet that hosts the Adjust panel.
  ///
  /// The editor always opens with Adjust, and that panel has a fixed height
  /// (a slider row, a card strip, the rail under it), so the opening
  /// composition can be known without measuring anything: 134 of panel plus
  /// rail, divider and padding.
  static const double adjustSheetHeight = 195;

  /// Duration of the sheet's height transition when a tool changes.
  static const Duration resizeDuration = Duration(milliseconds: 220);

  /// Height of a parameter card in a horizontal carousel.
  static const double cardHeight = 64;

  /// Width of a parameter card.
  static const double cardWidth = 84;

  /// Track height of a [LensSlider].
  static const double sliderHeight = 42;

  /// Height of a segmented mode row (Auto / Manual / Off).
  static const double modeRowHeight = 36;

  /// Height of the shared Strength + Invert row. Matches the slider track
  /// height so the slider inside it is never squeezed.
  static const double secondaryRowHeight = 44;

  /// Filter thumbnail edge in the Filters strip.
  static const double filterThumb = 56;

  /// Height of the floating top bar's pill row. The "Original" badge is
  /// parked below it so it never lands under the status bar.
  static const double topBarHeight = 52;

  /// Gap between the status bar and the floating top bar.
  static const double topBarPadding = 8;

  /// The space the floating top bar takes, including the status-bar inset.
  ///
  /// This is the top of the area the photo rests in: the top bar floats over
  /// the picture, so the picture starts below it.
  static double topBarInset(double topPadding) =>
      topPadding + topBarPadding + topBarHeight;

  /// Free space kept beside the crop window so its corners can be grabbed.
  ///
  /// The crop handles are tested against the pointer, and a handle flush
  /// with the screen edge is half off it — this margin keeps all four
  /// corners reachable.
  static const double cropHandleMargin = 28;

  /// Horizontal inset shared by every sheet row.
  static const double hPad = 16;

  /// Gap between stacked rows.
  static const double gap = 6;
}
