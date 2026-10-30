import 'dart:typed_data';

import 'package:fading_edge_scrollview/fading_edge_scrollview.dart';
import 'package:flutter/material.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/filters/lut_definition.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/imaging/widgets/shader_preview.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/theme_colors.dart';

/// Live filter strip: one GPU-graded thumb per [LensFilterId].
///
/// Each thumb is a small [ShaderPreview] of the current photo graded with
/// identity adjust + that thumb's filter at full strength, so the strip
/// shows the pure look (not the current grade). Atlas builds stay async and
/// cached inside [LutManager] — `build` never generates pixels synchronously.
///
/// Perf notes:
/// * Thumbs decode at 192px (`previewMaxDim`) — ~144KB RGBA each instead of
///   a shared 1080p texture per thumb (~8MB x 9).
/// * [ListView] builds lazily (only visible thumbs materialize atlases) and
/// * each item is keep-alive + repaint-bounded, so scrolling back never
///   rebuilds a shader.
/// * [previewBytes] == null (no photo yet) falls back to letter tiles.
class FilterStrip extends StatefulWidget {
  const FilterStrip({
    super.key,
    required this.selectedId,
    required this.previewBytes,
    required this.onSelect,
  });

  /// Active look; [LensFilterId.none] renders the ungraded photo.
  final LensFilterId selectedId;

  /// Current photo bytes shared by all thumbs (null = letter placeholders).
  final Uint8List? previewBytes;

  /// One undoable step per tap (owner calls `setFilterId` — no stroking).
  final ValueChanged<LensFilterId> onSelect;

  static String labelOf(LensFilterId id) => switch (id) {
    LensFilterId.none => 'None',
    LensFilterId.bw => 'BW',
    LensFilterId.cinematic => 'Cinematic',
    LensFilterId.golden => 'Golden',
    LensFilterId.noir => 'Noir',
    LensFilterId.fade => 'Fade',
    LensFilterId.vivid => 'Vivid',
    LensFilterId.warm => 'Warm',
    LensFilterId.cool => 'Cool',
  };

  @override
  State<FilterStrip> createState() => _FilterStripState();
}

class _FilterStripState extends State<FilterStrip> {
  final ScrollController _controller = ScrollController();

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: EditorPanelMetrics.filterThumb + 20,
      child: FadingEdgeScrollView.fromScrollView(
        gradientFractionOnStart: 0.12,
        gradientFractionOnEnd: 0.12,
        child: ListView.separated(
          controller: _controller,
          scrollDirection: Axis.horizontal,
          padding: const EdgeInsets.symmetric(
            horizontal: EditorPanelMetrics.hPad,
          ),
          itemCount: LensFilterId.values.length,
          separatorBuilder: (_, _) => const SizedBox(width: 8),
          itemBuilder: (context, index) {
            final id = LensFilterId.values[index];
            return _FilterThumb(
              id: id,
              label: FilterStrip.labelOf(id),
              selected: id == widget.selectedId,
              previewBytes: widget.previewBytes,
              onTap: () {
                if (context.hapticsEnabled) AppHaptics.selection();
                widget.onSelect(id);
              },
            );
          },
        ),
      ),
    );
  }
}

/// Single keep-alive thumb: accent ring + pop on selection.
class _FilterThumb extends StatefulWidget {
  const _FilterThumb({
    required this.id,
    required this.label,
    required this.selected,
    required this.previewBytes,
    required this.onTap,
  });

  final LensFilterId id;
  final String label;
  final bool selected;
  final Uint8List? previewBytes;
  final VoidCallback onTap;

  @override
  State<_FilterThumb> createState() => _FilterThumbState();
}

class _FilterThumbState extends State<_FilterThumb>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final colors = context.themeColors;
    final duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 140),
    );
    final labelStyle = AppTextStyles.small(context).copyWith(
      color: widget.selected ? colors.accent : colors.secondary,
      fontWeight: widget.selected ? FontWeight.w600 : FontWeight.w400,
      fontSize: 11,
      height: 1.1,
    );
    return Semantics(
      button: true,
      selected: widget.selected,
      label: 'Filter ${widget.label}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              AnimatedScale(
                scale: widget.selected ? 1.06 : 1.0,
                duration: duration,
                curve: Curves.easeOut,
                child: AnimatedContainer(
                  duration: duration,
                  curve: Curves.easeOut,
                  width: EditorPanelMetrics.filterThumb,
                  height: EditorPanelMetrics.filterThumb,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    // Constant 1 px layout border: a 1 -> 2 px change used to
                    // shrink the inner image by a pixel and make the selected
                    // thumb visibly jump.
                    border: Border.all(color: colors.border),
                  ),
                  foregroundDecoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: widget.selected
                          ? colors.accent
                          : Colors.transparent,
                      width: 2,
                    ),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(10),
                    child: RepaintBoundary(child: _ThumbBody(widget: widget)),
                  ),
                ),
              ),
              const SizedBox(height: 4),
              SizedBox(
                height: 16,
                child: AnimatedDefaultTextStyle(
                  duration: duration,
                  style: labelStyle,
                  child: Text(
                    widget.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Thumb pixels: live GPU grade, or a letter tile with no photo.
///
/// While the thumb is still decoding its atlas the tile shows a soft
/// surface fill instead of a black hole, so opening Filters reads as
/// "loading" rather than "broken".
class _ThumbBody extends StatelessWidget {
  const _ThumbBody({required this.widget});

  final _FilterThumb widget;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final bytes = widget.previewBytes;
    return ColoredBox(
      color: colors.surface,
      child: bytes == null
          ? Center(
              child: Text(
                widget.label.characters.first,
                style: AppTextStyles.subheading(context),
              ),
            )
          : ShaderPreview(
              imageBytes: bytes,
              params: LensParams(filterId: widget.id.index, filterStrength: 1),
              // Cover, not contain: a square tile is only aesthetic when the
              // photo fills it edge to edge, so non-square frames crop
              // instead of leaving surface-coloured bars.
              fit: BoxFit.cover,
              // The same crop in the pixels: the source is already square,
              // so the tile is filled by construction on every path (the
              // CPU fallback and the GPU one show the same picture).
              squareCrop: true,
              previewMaxDim: 192,
            ),
    );
  }
}
