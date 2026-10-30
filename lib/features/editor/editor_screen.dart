import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/app/router.dart';
import 'package:lens/features/adjust/adjust_panel.dart';
import 'package:lens/features/adjust/cards/enhance/enhance_cache.dart';
import 'package:lens/features/blur/blur_cache.dart';
import 'package:lens/features/blur/blur_panel.dart';
import 'package:lens/features/blur/subject_mask.dart';
import 'package:lens/features/crop/crop_panel.dart';
import 'package:lens/features/editor/export_screen.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/editor_chrome.dart';
import 'package:lens/features/editor/widgets/editor_panel_metrics.dart';
import 'package:lens/features/editor/widgets/editor_preview_area.dart';
import 'package:lens/features/editor/widgets/tool_rail.dart';
import 'package:lens/features/filters/filters_panel.dart';
import 'package:lens/features/rays/rays_panel.dart';
import 'package:lens/features/selective/selective_panel.dart';
import 'package:lens/shared/data/preferences/app_preference_keys.dart';
import 'package:lens/shared/data/preferences/shared_preferences_provider.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/app_tokens.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';
import 'package:lens/shared/widgets/indicators/app_badge.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Editor shell: preview + tool rail + tool panels + export.
///
/// This file owns the session scaffolding only — route-driven warm-up, the
/// return-flight snapshot debounce, the one-time compare hint, the
/// self-measuring tool sheet and the landscape/portrait chrome layout. The
/// floating chrome lives in `widgets/editor_chrome.dart`, the preview
/// composition (photo, overlays, crop morph, compare-hold) in
/// `widgets/editor_preview_area.dart`.
///
/// Adjust sliders drive [ShaderPreview] through `EditorStateToLensParams`;
/// compare-hold swaps in [LensParams.identity]; undo/redo go through the
/// stroke-bracketed history (tap = one step, hold = replay, see
/// [EditorHistoryStepButton]).
class EditorScreen extends ConsumerStatefulWidget {
  const EditorScreen({
    super.key,
    this.photoId,
    this.photoAspectRatio = 1,
    this.transitionBytes,
  });

  final String? photoId;
  final double photoAspectRatio;
  final Uint8List? transitionBytes;

  @override
  ConsumerState<EditorScreen> createState() => _EditorScreenState();
}

class _EditorScreenState extends ConsumerState<EditorScreen>
    with SingleTickerProviderStateMixin {
  Animation<double>? _routeAnimation;
  bool _warmed = false;
  final _previewKey = GlobalKey();
  Uint8List? _returnBytes;
  bool _leaving = false;
  bool _allowPop = false;

  /// Trailing-edge capture scheduled by [_scheduleSnapshot].
  Timer? _snapshotTimer;
  bool _snapshotting = false;

  /// One-time discoverability hint for press-and-hold compare.
  bool _showCompareHint = false;
  bool _compareHintResolved = false;
  Timer? _compareHintTimer;

  /// How long the grade must stay still before the snapshot is taken.
  static const Duration _snapshotIdle = Duration(milliseconds: 350);

  /// The sheet is sized to the tool panel it hosts: it hugs whatever the
  /// current panel needs (Adjust and Filters end up noticeably shorter than
  /// Blur or Selective), and [_sheetAnim] animates between those heights
  /// while the preview re-composes to match. [_sheetKey] is attached to the
  /// unconstrained sheet so its natural height can be measured after layout.
  final _sheetKey = GlobalKey();
  late final AnimationController _sheetAnim;
  double _sheetFrom = 0;
  double _sheetTo = 0;
  bool _sheetInitialised = false;

  Future<void> _leaveEditor() async {
    if (_leaving) return;
    _leaving = true;
    // Fast path: an idle snapshot is already current, so Back only flips the
    // PopScope flag and pops. The GPU readback + PNG encode used to run on
    // this exact frame and made the button feel stuck.
    if (!ref.read(editorStateProvider).isDefault && _returnBytes == null) {
      final raster = await _readPreviewRaster();
      if (!mounted) return;
      if (raster != null) setState(() => _returnBytes = raster);
    }
    if (!mounted) return;
    setState(() => _allowPop = true);
    await WidgetsBinding.instance.endOfFrame;
    if (mounted) Navigator.of(context).pop();
  }

  /// Schedules the reverse-flight snapshot after edits settle.
  ///
  /// Every grade/crop/compare change restarts the timer, so a slider drag
  /// never captures mid-gesture. A default state needs no snapshot at all.
  void _scheduleSnapshot() {
    _snapshotTimer?.cancel();
    if (!mounted) return;
    final state = ref.read(editorStateProvider);
    if (state.isDefault) {
      if (_returnBytes != null) setState(() => _returnBytes = null);
      return;
    }
    // Crop owns the artwork and is outside the capture boundary; the
    // uncropped transition raster flies back, exactly as before.
    if (state.showOriginal || state.tool == EditorTool.crop) return;
    _snapshotTimer = Timer(_snapshotIdle, _captureSnapshot);
  }

  Future<void> _captureSnapshot() async {
    if (!mounted || _snapshotting) return;
    final state = ref.read(editorStateProvider);
    if (state.isDefault ||
        state.showOriginal ||
        state.tool == EditorTool.crop) {
      return;
    }
    final boundary =
        _previewKey.currentContext?.findRenderObject()
            as RenderRepaintBoundary?;
    if (boundary == null) return;
    if (boundary.debugNeedsPaint) {
      // The edit has not been painted yet; try again once it lands.
      _snapshotTimer?.cancel();
      _snapshotTimer = Timer(
        const Duration(milliseconds: 80),
        _captureSnapshot,
      );
      return;
    }
    _snapshotting = true;
    try {
      final image = await boundary.toImage(
        pixelRatio: math.min(MediaQuery.devicePixelRatioOf(context), 2),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      if (!mounted || data == null) return;
      final raster = data.buffer.asUint8List();
      setState(() => _returnBytes = raster);
      // Warm the cache off the pop path so the reverse flight starts on a
      // decoded frame instead of decoding on its first tick.
      unawaited(
        precacheImage(MemoryImage(raster), context, onError: (_, _) {}),
      );
    } catch (error, stackTrace) {
      // Readback failure keeps the last snapshot; Back still works.
      AppLogger.d(
        'Return-flight snapshot failed; keeping the previous raster',
        context: 'editor_screen',
        error: error,
        stackTrace: stackTrace,
      );
    } finally {
      _snapshotting = false;
    }
  }

  /// One-shot readback used only when Back beats the idle debounce.
  Future<Uint8List?> _readPreviewRaster() async {
    try {
      final boundary =
          _previewKey.currentContext?.findRenderObject()
              as RenderRepaintBoundary?;
      if (boundary == null || boundary.debugNeedsPaint) return null;
      final image = await boundary.toImage(
        pixelRatio: math.min(MediaQuery.devicePixelRatioOf(context), 2),
      );
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      image.dispose();
      return data?.buffer.asUint8List();
    } catch (error, stackTrace) {
      AppLogger.d(
        'Preview readback failed; the hero falls back to the transition bytes',
        context: 'editor_screen',
        error: error,
        stackTrace: stackTrace,
      );
      return null;
    }
  }

  @override
  void initState() {
    super.initState();
    _sheetAnim = AnimationController(
      vsync: this,
      duration: EditorPanelMetrics.resizeDuration,
      value: 1,
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final animation = ModalRoute.of(context)?.animation;
    if (animation != _routeAnimation) {
      _routeAnimation?.removeStatusListener(_onRouteStatus);
      _routeAnimation = animation;
      animation?.addStatusListener(_onRouteStatus);
    }
    if (animation == null || animation.status == AnimationStatus.completed) {
      _warmEnhance();
    }
  }

  void _onRouteStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) _warmEnhance();
  }

  void _warmEnhance() {
    if (_warmed) return;
    _warmed = true;
    final bytes = ref.read(editorStateProvider).previewBytes;
    if (bytes == null) return;
    EnhanceCache.prewarm(
      bytes,
      onReady: () {
        if (mounted &&
            identical(ref.read(editorStateProvider).previewBytes, bytes)) {
          ref.read(editorStateProvider.notifier).bumpEnhanceVersion();
        }
      },
    );
    // Blur ML mask warms alongside enhance (same photo, same moment):
    // fire-and-forget, never throws; onReady bumps the blur nonce so the
    // preview re-reads `BlurCache.get` (mask or null). A null settle means
    // desktop/ML-fail — the UI then offers the manual brush (no spinner).
    BlurCache.prewarm(
      bytes,
      const MlKitSubjectMask(),
      onReady: () {
        if (mounted &&
            identical(ref.read(editorStateProvider).previewBytes, bytes)) {
          ref.read(editorStateProvider.notifier).bumpBlurVersion();
        }
      },
    );
  }

  @override
  void dispose() {
    _routeAnimation?.removeStatusListener(_onRouteStatus);
    _snapshotTimer?.cancel();
    _compareHintTimer?.cancel();
    _sheetAnim.dispose();
    super.dispose();
  }

  /// Shows "Hold the photo to compare" once, after the first real edit.
  ///
  /// The hint is deliberately late: comparing before there is anything to
  /// compare with would be noise. It is persisted so it never nags.
  void _maybeShowCompareHint() {
    if (_compareHintResolved) return;
    _compareHintResolved = true;
    // Prefs still loading (the editor is normally unreachable before they
    // resolve, but a provider rebuild can race): skip the nag rather than
    // throw from a UI callback.
    final prefs = ref.read(sharedPreferencesProvider).value;
    final hintSeen = prefs?.getBool(AppPreferenceKeys.compareHintSeen) ?? false;
    if (prefs == null || hintSeen) {
      return;
    }
    setState(() => _showCompareHint = true);
    _compareHintTimer?.cancel();
    _compareHintTimer = Timer(const Duration(seconds: 7), _dismissCompareHint);
  }

  void _dismissCompareHint() {
    _compareHintTimer?.cancel();
    if (_showCompareHint && mounted) {
      setState(() => _showCompareHint = false);
    }
    final prefs = ref.read(sharedPreferencesProvider).value;
    if (prefs != null &&
        !(prefs.getBool(AppPreferenceKeys.compareHintSeen) ?? false)) {
      unawaited(prefs.setBool(AppPreferenceKeys.compareHintSeen, true));
    }
  }

  /// Sheet height as currently painted — mid-transition while [_sheetAnim]
  /// runs, so the sheet and the preview inset stay in lockstep.
  double get _sheetHeight {
    if (!_sheetInitialised) {
      // The editor opens with Adjust, whose panel has a fixed height: the
      // opening composition is known without measuring anything.
      return (EditorPanelMetrics.adjustSheetHeight +
          MediaQuery.paddingOf(context).bottom);
    }
    final t = Curves.easeOutCubic.transform(_sheetAnim.value);
    return _sheetFrom + (_sheetTo - _sheetFrom) * t;
  }

  /// Re-measures the sheet after a layout pass.
  ///
  /// Always deferred to the post-frame callback: `SizeChangedLayoutNotifier`
  /// dispatches during layout, and `setState` is illegal there. Fires on a
  /// tool switch and on content that resizes on its own (the Rays one-tap
  /// button giving way to its sliders, for instance).
  void _measureSheet() {
    if (!mounted) return;
    final box = _sheetKey.currentContext?.findRenderObject() as RenderBox?;
    final natural = box?.size.height;
    if (natural == null || natural <= 0) return;
    // Never let the sheet swallow the preview on a short screen.
    final target = math.min(
      math.min(natural, EditorPanelMetrics.maxSheetHeight),
      MediaQuery.sizeOf(context).height * 0.55,
    );
    final wasInitialised = _sheetInitialised;
    if (wasInitialised && (target - _sheetTo).abs() < 0.5) return;
    setState(() {
      // Animate from whatever is on screen: the first measure already
      // happens on a tool switch, the opening height is known up front.
      _sheetFrom = _sheetHeight;
      _sheetTo = target;
      _sheetInitialised = true;
    });
    _sheetAnim.duration = context.uiPerformance.motionDuration(
      EditorPanelMetrics.resizeDuration,
    );
    _sheetAnim.forward(from: 0);
  }

  void _openExportScreen(BuildContext context) {
    LensRouter.pushPage(context, ExportScreen(photoId: widget.photoId));
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;

    // Keep the reverse-flight raster warm (see _scheduleSnapshot): grade,
    // crop, compare and tool changes all change what the flight should show.
    ref.listen(editorStateProvider.select((s) => s.toLensParams()), (_, _) {
      _scheduleSnapshot();
    });
    ref.listen(editorStateProvider.select((s) => s.crop), (_, _) {
      _scheduleSnapshot();
    });
    ref.listen(editorStateProvider.select((s) => s.showOriginal), (_, next) {
      _scheduleSnapshot();
      if (next) _dismissCompareHint();
    });
    ref.listen(editorStateProvider.select((s) => s.tool), (_, next) {
      if (next != EditorTool.crop) _scheduleSnapshot();
    });
    ref.listen(editorStateProvider.select((s) => s.isDefault), (
      previous,
      next,
    ) {
      if (previous == true && next == false) {
        final tool = ref.read(editorStateProvider).tool;
        if (tool == EditorTool.adjust || tool == EditorTool.filters) {
          _maybeShowCompareHint();
        }
      }
    });

    final unmodified = ref.watch(
      editorStateProvider.select((state) => state.isDefault),
    );
    final showOriginal = ref.watch(
      editorStateProvider.select((state) => state.showOriginal),
    );
    final previewBytes = ref.watch(
      editorStateProvider.select((state) => state.previewBytes),
    );
    final blurState = ref.watch(
      editorStateProvider.select((state) => state.blur),
    );
    final activeTool = ref.watch(
      editorStateProvider.select((state) => state.tool),
    );
    final autoMiss = _blurAutoMiss(
      blurState: blurState,
      showOriginal: showOriginal,
      activeTool: activeTool,
      previewBytes: previewBytes,
    );
    return PopScope(
      canPop: _allowPop || unmodified,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop) _leaveEditor();
      },
      child: Scaffold(
        backgroundColor: colors.background,
        body: LayoutBuilder(
          builder: (context, bounds) {
            final landscape = bounds.maxWidth > bounds.maxHeight * 1.25;
            final insets = MediaQuery.paddingOf(context);
            // The sheet owns a slice of the screen that depends on the tool.
            // The preview is inset by exactly the sheet's *current* height so
            // the photograph is composed in the space the user can actually
            // see, instead of being centred on the full screen and hidden
            // behind the controls.
            final sheetWidth = landscape
                ? math.min(bounds.maxWidth * 0.42, 380.0)
                : bounds.maxWidth;

            final sheetSurface = SizeChangedLayoutNotifier(
              child: ClipRRect(
                key: _sheetKey,
                borderRadius: landscape
                    ? const BorderRadius.horizontal(left: Radius.circular(24))
                    : const BorderRadius.vertical(top: Radius.circular(24)),
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: colors.surface,
                    border: Border(
                      top: landscape
                          ? BorderSide.none
                          : BorderSide(color: colors.border),
                      left: landscape
                          ? BorderSide(color: colors.border)
                          : BorderSide.none,
                    ),
                  ),
                  child: SafeArea(
                    top: false,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      mainAxisAlignment: landscape
                          ? MainAxisAlignment.end
                          : MainAxisAlignment.start,
                      children: [
                        const _BottomPanel(),
                        const SizedBox(height: EditorPanelMetrics.railGap),
                        Divider(
                          height: EditorPanelMetrics.railDividerHeight,
                          thickness: EditorPanelMetrics.railDividerHeight,
                          color: colors.border,
                        ),
                        const _ToolRailArea(),
                        const SizedBox(
                          height: EditorPanelMetrics.bottomPadding,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );

            final topBar = SafeArea(
              bottom: false,
              child: Padding(
                // The `Positioned` below already reserves the sheet's width
                // in landscape, so this padding is a plain inset.
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 0),
                child: Row(
                  children: [
                    EditorFloatingPill(
                      child: AppButton.iconGhost(
                        icon: LucideIcons.arrowLeft,
                        tooltip: 'Back',
                        onTap: _leaveEditor,
                      ),
                    ),
                    const Spacer(),
                    const EditorFloatingPill(child: EditorUndoActions()),
                    const Spacer(),
                    EditorFloatingPill(
                      child: AppButton.iconGhost(
                        icon: LucideIcons.save,
                        tooltip: 'Save',
                        onTap: () => _openExportScreen(context),
                        style: AppButtonStyle(foregroundColor: colors.primary),
                      ),
                    ),
                  ],
                ),
              ),
            );
            // Below the top bar, never under the status bar: the badge used
            // to be positioned at top:8 with no SafeArea and collided with
            // the system clock.
            final badgeTop = EditorPanelMetrics.topBarInset(insets.top) + 10;
            return NotificationListener<SizeChangedLayoutNotification>(
              // The sheet re-measures itself whenever its natural size
              // changes; the notification arrives during layout, so the read
              // is deferred to the post-frame callback.
              onNotification: (_) {
                WidgetsBinding.instance.addPostFrameCallback(
                  (_) => _measureSheet(),
                );
                return false;
              },
              // The sheet and the preview's visible area read the *animating*
              // height, so they grow together — but the photo keeps its own
              // frame inside that area and only moves when the sheet would
              // cover it.
              child: AnimatedBuilder(
                animation: _sheetAnim,
                builder: (context, _) {
                  // The photo rests in the area the floating chrome leaves
                  // free. The canvas itself stays the whole screen, so a
                  // zoomed photo can cover it and slide under the top bar.
                  final visibleInsets = EdgeInsets.only(
                    top: EditorPanelMetrics.topBarInset(insets.top),
                    bottom: landscape ? 0 : _sheetHeight,
                    right: landscape ? sheetWidth : 0,
                  );
                  // The crop stage keeps clear of the chrome and leaves
                  // room beside the screen so its corner handles stay
                  // reachable.
                  final cropInsets = EdgeInsets.only(
                    top: visibleInsets.top,
                    bottom: visibleInsets.bottom > 0
                        ? visibleInsets.bottom +
                              EditorPanelMetrics.cropHandleMargin
                        : EditorPanelMetrics.cropHandleMargin,
                    left: EditorPanelMetrics.cropHandleMargin,
                    right:
                        visibleInsets.right +
                        EditorPanelMetrics.cropHandleMargin,
                  );
                  final preview = EditorPreviewArea(
                    photoId: widget.photoId,
                    aspectRatio: widget.photoAspectRatio,
                    transitionBytes: _returnBytes ?? widget.transitionBytes,
                    captureKey: _previewKey,
                    visibleInsets: visibleInsets,
                    cropInsets: cropInsets,
                  );
                  return Stack(
                    fit: StackFit.expand,
                    children: [
                      Positioned.fill(child: preview),
                      Positioned(
                        top: badgeTop,
                        left: 8,
                        right: landscape ? sheetWidth + 8 : 8,
                        child: AnimatedSwitcher(
                          duration: context.uiPerformance.motionDuration(
                            const Duration(milliseconds: 180),
                          ),
                          switchInCurve: Curves.easeOutCubic,
                          switchOutCurve: Curves.easeInCubic,
                          transitionBuilder: (child, animation) =>
                              FadeTransition(
                                opacity: animation,
                                child: SlideTransition(
                                  position: Tween<Offset>(
                                    begin: const Offset(0, -0.06),
                                    end: Offset.zero,
                                  ).animate(animation),
                                  child: child,
                                ),
                              ),
                          child: autoMiss && !showOriginal
                              ? _BlurAutoMissBadge(
                                  key: const ValueKey('blur-auto-miss'),
                                  onManual: () {
                                    if (context.hapticsEnabled) {
                                      AppHaptics.selection();
                                    }
                                    ref
                                        .read(editorStateProvider.notifier)
                                        .setBlurSource(SubjectSource.manual);
                                  },
                                )
                              : const SizedBox.shrink(
                                  key: ValueKey('blur-auto-miss-none'),
                                ),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        left: 0,
                        right: landscape ? sheetWidth : 0,
                        child: topBar,
                      ),
                      // One-time compare hint: float it just above the sheet
                      // so it never covers the photo's centre or the chrome.
                      Positioned(
                        left: 8,
                        right: landscape ? sheetWidth + 8 : 8,
                        bottom:
                            (landscape ? insets.bottom : _sheetHeight) + 12,
                        child: IgnorePointer(
                          child: AnimatedSwitcher(
                            duration: context.uiPerformance.motionDuration(
                              const Duration(milliseconds: 180),
                            ),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: _showCompareHint && !showOriginal
                                ? const _CompareHintBadge(
                                    key: ValueKey('compare-hint'),
                                  )
                                : const SizedBox.shrink(
                                    key: ValueKey('compare-hint-hidden'),
                                  ),
                          ),
                        ),
                      ),
                      if (landscape)
                        Positioned(
                          top: 0,
                          bottom: 0,
                          right: 0,
                          width: sheetWidth,
                          child: sheetSurface,
                        )
                      else
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 0,
                          child: SizedBox(
                            height: _sheetHeight,
                            // The OverflowBox lifts the height constraint
                            // off the sheet so it keeps laying out at its
                            // natural size and stays measurable, while the
                            // outer box animates and the ClipRect trims
                            // the slack.
                            child: ClipRect(
                              child: OverflowBox(
                                alignment: Alignment.bottomCenter,
                                minWidth: bounds.maxWidth,
                                maxWidth: bounds.maxWidth,
                                minHeight: 0,
                                maxHeight: double.infinity,
                                child: sheetSurface,
                              ),
                            ),
                          ),
                        ),
                    ],
                  );
                },
              ),
            );
          },
        ),
      ),
    );
  }

  /// True when the auto subject-mask path is still empty (ML miss pending
  /// or failed) while the blur grade is live: the badge offers the manual
  /// brush instead of a spinner.
  static bool _blurAutoMiss({
    required BlurState blurState,
    required bool showOriginal,
    required EditorTool activeTool,
    required Uint8List? previewBytes,
  }) {
    final hasBlurPaint = blurState.strokes.any((s) => s.points.isNotEmpty);
    final blurMaskActive =
        !showOriginal &&
        blurState.strength > 0 &&
        !(blurState.source == SubjectSource.manual && !hasBlurPaint);
    return blurMaskActive &&
        // The crop stage owns the preview outright, so the blur hint would
        // float over a frame it has nothing to do with.
        activeTool != EditorTool.crop &&
        blurState.source == SubjectSource.auto &&
        previewBytes != null &&
        BlurCache.get(previewBytes) == null;
  }
}

/// "Finding subject… Paint manually" hint shown while the auto ML mask has
/// not landed for a live blur grade.
class _BlurAutoMissBadge extends StatelessWidget {
  const _BlurAutoMissBadge({super.key, required this.onManual});

  final VoidCallback onManual;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    return AppBadge(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      radius: AppRadius.sm,
      child: Row(
        children: [
          Icon(LucideIcons.scanFace, size: 18, color: colors.primary),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              'Finding subject… Paint manually',
              style: AppTextStyles.small(context),
            ),
          ),
          const SizedBox(width: 8),
          AppButton.ghost(
            key: const ValueKey('blur-fallback-manual'),
            label: 'Manual',
            icon: LucideIcons.paintbrush,
            onTap: onManual,
            minHeight: 44,
            style: AppButtonStyle(foregroundColor: colors.primary),
          ),
        ],
      ),
    );
  }
}

/// One-time "Hold the photo to compare" discoverability hint.
class _CompareHintBadge extends StatelessWidget {
  const _CompareHintBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    return Center(
      child: AppBadge(
        child: MediaQuery.withClampedTextScaling(
          maxScaleFactor: 1.3,
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(LucideIcons.eye, size: 14, color: colors.secondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  'Hold the photo to compare',
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: AppTextStyles.smallDim(
                    context,
                  ).copyWith(fontSize: 11),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Tool rail: rebuilds only when [EditorState.tool] changes.
class _ToolRailArea extends ConsumerWidget {
  const _ToolRailArea();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = ref.watch(editorStateProvider.select((s) => s.tool));
    final notifier = ref.read(editorStateProvider.notifier);
    return ToolRail(
      selected: tool,
      onSelect: (selected) {
        if (context.hapticsEnabled) AppHaptics.selection();
        notifier.setTool(selected);
      },
    );
  }
}

/// Tool panel switch: Adjust sliders vs live filter strip vs Enhance
/// 1-tap vs Selective vs Blur. Rebuilds only on tool change. Filter
/// selection lives in the provider ([EditorState.filterId], one undoable
/// step per tap) — no local index.
///
/// Every branch sizes itself to its content; nothing scrolls vertically, no
/// control can end up below the fold, and the sheet animates to whatever
/// height the current tool needs.
class _BottomPanel extends ConsumerWidget {
  const _BottomPanel();

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final tool = ref.watch(editorStateProvider.select((s) => s.tool));
    // The sheet body has a hard height, so text scaling is clamped: past
    // ~1.3x a two-line label or hint would outgrow the row it sits in.
    final panel = switch (tool) {
      EditorTool.filters => const FiltersPanel(),
      EditorTool.adjust => const AdjustPanel(),
      EditorTool.selective => const SelectivePanel(),
      EditorTool.blur => const BlurPanel(),
      EditorTool.rays => const RaysPanel(),
      EditorTool.crop => const CropPanel(),
    };
    // A tool switch swaps the panel while the sheet animates its height.
    // Fade only the INCOMING panel (one layer): an AnimatedSwitcher would
    // keep the taller outgoing panel in the measurement and make the sheet
    // overshoot before settling. The 6px lift hides the swap behind the
    // height change instead of drawing attention to it.
    return MediaQuery.withClampedTextScaling(
      minScaleFactor: 1,
      maxScaleFactor: 1.3,
      child: TweenAnimationBuilder<double>(
        key: ValueKey(tool),
        tween: Tween<double>(begin: 0, end: 1),
        duration: context.uiPerformance.motionDuration(
          const Duration(milliseconds: 160),
        ),
        curve: Curves.easeOutCubic,
        builder: (context, t, child) => Opacity(
          opacity: t,
          child: Transform.translate(
            offset: Offset(0, (1 - t) * 6),
            child: child,
          ),
        ),
        child: panel,
      ),
    );
  }
}
