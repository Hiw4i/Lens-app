import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/imaging/export/export_service.dart';
import 'package:lens/features/imaging/export/save_service.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart' show LensCpuException;
import 'package:lens/features/library/photo_hero.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/animation/pressable_scale.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// Full-screen export result: the editor chrome fades away, the photo moves to
/// the centre and the full-resolution render is prepared in the background.
///
/// Nothing is written to the gallery until the user taps **Save**. The previous
/// version saved automatically on open and labelled generic share-sheet actions
/// as Telegram/WhatsApp, which was both a consent and an honesty problem.
/// Saving and sharing are now explicit, and the labels say exactly what they do.
class ExportScreen extends ConsumerStatefulWidget {
  const ExportScreen({super.key, this.photoId});

  final String? photoId;

  @override
  ConsumerState<ExportScreen> createState() => _ExportScreenState();
}

class _ExportScreenState extends ConsumerState<ExportScreen> {
  bool _running = true;
  bool _saving = false;
  bool _saved = false;
  bool _sharing = false;
  Uint8List? _rendered;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _run());
  }

  Future<void> _run() async {
    if (!mounted) return;
    final state = ref.read(editorStateProvider);
    final src = state.previewBytes;
    if (src == null) {
      if (mounted) {
        setState(() {
          _running = false;
          _error = 'No photo — import from Library first.';
        });
      }
      return;
    }
    setState(() {
      _running = true;
      _rendered = null;
      _error = null;
      _saved = false;
    });
    try {
      final out = await ExportService.export(
        srcBytes: src,
        params: state.toLensParams(),
        brushStrokesFlat: state.encodeSelectiveBrush(),
        blurMask256: state.resolveBlurMask256(),
        crop: state.encodeCropGeometry(),
      );
      if (!mounted) return;
      setState(() {
        _rendered = out;
        _running = false;
      });
      // Deliberately no `_save(out)` here: rendering is not consent to write
      // to the user's gallery.
    } on ExportException catch (e) {
      // ExportException carries a human-readable message (the OOM copy is
      // actionable); surface it instead of a generic line.
      _fail(e.message, e);
    } on LensCpuException catch (e) {
      _fail(e.message, e);
    } on Exception catch (e) {
      // Unknown failures keep the honest generic copy; the details are in
      // the log, never in the user's face as a raw exception string.
      _fail('Photo export failed.', e);
    } on Error catch (e, s) {
      // A programming error thrown by the state encoders must not leave
      // the spinner running forever — same UI path, logged at error level.
      _fail('Photo export failed.', e, stackTrace: s);
    }
  }

  /// Shared failure path: informative user copy, full details logged,
  /// spinner released exactly once.
  void _fail(
    String message,
    Object error, {
    StackTrace? stackTrace,
  }) {
    AppLogger.e(
      'Export failed',
      context: 'export_screen',
      error: error,
      stackTrace: stackTrace,
    );
    if (!mounted) return;
    setState(() {
      _error = message;
      _running = false;
    });
  }

  Future<void> _save(Uint8List bytes) async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
    });
    try {
      await SaveService.saveJpeg(bytes);
      if (!mounted) return;
      setState(() {
        _saved = true;
      });
      if (context.hapticsEnabled) AppHaptics.medium();
    } on SaveException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(e.message),
          action: e.denied
              ? SnackBarAction(label: 'Retry', onPressed: () => _save(bytes))
              : null,
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _share() async {
    final bytes = _rendered;
    if (bytes == null || _sharing) return;
    setState(() {
      _sharing = true;
      _error = null;
    });
    try {
      await SaveService.shareJpeg(bytes);
    } on SaveException catch (e) {
      if (!mounted) return;
      setState(() => _error = e.message);
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(e.message)));
    } finally {
      if (mounted) setState(() => _sharing = false);
    }
  }

  /// Closes the editor and brings the gallery back.
  ///
  /// The checkmark means "I am done with this photo": the export screen and
  /// the editor underneath it go away together, so the gallery — the start
  /// window — is what is left on screen.
  ///
  /// The editor keeps its own pop guard: an edited photo still flies back
  /// to the grid with its snapshot instead of vanishing.
  void _closeEditor() {
    final NavigatorState navigator = Navigator.of(context);
    // The export screen first, the editor right below it.
    navigator.pop();
    if (navigator.canPop()) navigator.pop();
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final previewBytes = ref.watch(
      editorStateProvider.select((s) => s.previewBytes),
    );
    final imageBytes = _rendered ?? previewBytes;
    final busy = _running || _saving || _sharing;

    return Scaffold(
      backgroundColor: colors.background,
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  _CircleButton(
                    // A U-turn arrow: the button takes the user back to the
                    // editor. The old X read as "throw the photo away".
                    icon: LucideIcons.undo2,
                    tooltip: 'Close',
                    onTap: () => Navigator.of(context).pop(),
                  ),
                  Flexible(
                    child: Text(
                      'Export',
                      style: AppTextStyles.subheading(context),
                      textAlign: TextAlign.center,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  _CircleButton(
                    icon: LucideIcons.check,
                    tooltip: 'Done',
                    onTap: _closeEditor,
                    foreground: colors.primary,
                  ),
                ],
              ),
            ),
            Expanded(
              child: Center(
                child: Padding(
                  padding: const EdgeInsets.all(24),
                  child: imageBytes == null
                      ? Text(
                          'No photo — import from Library first.',
                          style: AppTextStyles.bodyDim(context),
                        )
                      : PhotoHero(
                          id: widget.photoId ?? 'export-preview',
                          bytes: imageBytes,
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(20),
                            child: Image.memory(
                              imageBytes,
                              fit: BoxFit.contain,
                              gaplessPlayback: true,
                            ),
                          ),
                        ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
              // The action area grows with Dynamic Type, but at 2.0 it can
              // squeeze the photo to nothing on a short phone. 1.5 keeps the
              // controls comfortably larger without making the layout unusable.
              child: MediaQuery.withClampedTextScaling(
                maxScaleFactor: 1.5,
                child: AnimatedSize(
                  duration: context.uiPerformance.motionDuration(
                    const Duration(milliseconds: 200),
                  ),
                  curve: Curves.easeOutCubic,
                  alignment: Alignment.bottomCenter,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      if (busy)
                        Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox.square(
                              dimension: 28,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            ),
                            const SizedBox(height: 8),
                            AnimatedSwitcher(
                              duration: context.uiPerformance.motionDuration(
                                const Duration(milliseconds: 140),
                              ),
                              child: Text(
                                _running
                                    ? 'Rendering at full resolution…'
                                    : _saving
                                    ? 'Saving to gallery…'
                                    : 'Opening share sheet…',
                                key: ValueKey((_running, _saving, _sharing)),
                                style: AppTextStyles.smallDim(context),
                                textAlign: TextAlign.center,
                              ),
                            ),
                          ],
                        )
                      else ...[
                        Semantics(
                          liveRegion: true,
                          child: AnimatedSwitcher(
                            duration: context.uiPerformance.motionDuration(
                              const Duration(milliseconds: 180),
                            ),
                            switchInCurve: Curves.easeOutCubic,
                            switchOutCurve: Curves.easeInCubic,
                            child: _saved
                                ? Row(
                                    key: const ValueKey('saved'),
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      ExcludeSemantics(
                                        child: Icon(
                                          LucideIcons.check,
                                          size: 14,
                                          color: colors.secondary,
                                        ),
                                      ),
                                      const SizedBox(width: 4),
                                      Text(
                                        'Saved to gallery',
                                        style: AppTextStyles.smallDim(context),
                                      ),
                                    ],
                                  )
                                : Text(
                                    _error ?? 'Ready to save or share.',
                                    key: ValueKey(_error ?? 'ready'),
                                    style: AppTextStyles.smallDim(context),
                                    textAlign: TextAlign.center,
                                  ),
                          ),
                        ),
                        if (_error != null && _rendered == null) ...[
                          const SizedBox(height: 8),
                          AppButton.ghost(
                            label: 'Retry',
                            onTap: _run,
                            shrinkWrap: true,
                            minHeight: 44,
                            style: AppButtonStyle(
                              foregroundColor: colors.primary,
                              textStyle: AppTextStyles.buttonSmall,
                            ),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Row(
                          mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                          children: [
                            _ShareButton(
                              icon: LucideIcons.download,
                              label: _saved ? 'Save again' : 'Save',
                              onTap: _rendered == null
                                  ? null
                                  : () => _save(_rendered!),
                            ),
                            _ShareButton(
                              icon: LucideIcons.share2,
                              label: 'Share',
                              onTap: _rendered == null ? null : _share,
                            ),
                          ],
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _CircleButton extends StatelessWidget {
  const _CircleButton({
    required this.icon,
    required this.onTap,
    this.foreground,
    this.tooltip,
  });

  final IconData icon;
  final VoidCallback onTap;
  final Color? foreground;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final label = tooltip ?? 'Button';
    final button = PressableScale(
      onTap: onTap,
      child: Container(
        width: 44,
        height: 44,
        decoration: BoxDecoration(
          color: colors.surfaceTranslucent,
          shape: BoxShape.circle,
          border: Border.all(color: colors.border),
        ),
        child: ExcludeSemantics(
          child: Icon(icon, size: 20, color: foreground ?? colors.primary),
        ),
      ),
    );
    return Semantics(
      button: true,
      label: label,
      onTap: onTap,
      child: Tooltip(message: label, excludeFromSemantics: true, child: button),
    );
  }
}

class _ShareButton extends StatelessWidget {
  const _ShareButton({
    required this.icon,
    required this.label,
    required this.onTap,
  });

  final IconData icon;
  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final enabled = onTap != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: label,
      onTap: onTap,
      child: ExcludeSemantics(
        child: Opacity(
          opacity: enabled ? 1 : 0.45,
          child: PressableScale(
            onTap: onTap,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  width: 56,
                  height: 56,
                  decoration: BoxDecoration(
                    color: colors.surfaceBright,
                    shape: BoxShape.circle,
                    border: Border.all(color: colors.border),
                  ),
                  child: ExcludeSemantics(
                    child: Icon(icon, size: 24, color: colors.primary),
                  ),
                ),
                const SizedBox(height: 6),
                SizedBox(
                  width: 72,
                  child: Text(
                    label,
                    style: AppTextStyles.smallDim(context),
                    textAlign: TextAlign.center,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
