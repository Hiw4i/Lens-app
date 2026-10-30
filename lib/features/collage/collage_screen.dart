import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:lens/features/collage/collage_renderer.dart';
import 'package:lens/features/imaging/export/save_service.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/inputs/app_choice_chip.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

class CollageScreen extends StatefulWidget {
  CollageScreen({super.key, required List<Uint8List> images})
    : images = List.unmodifiable(images) {
    if (images.length < 2 || images.length > 9) {
      throw ArgumentError('Choose 2–9 photos');
    }
  }
  final List<Uint8List> images;
  @override
  State<CollageScreen> createState() => _CollageScreenState();
}

class _CollageScreenState extends State<CollageScreen> {
  late int _columns = widget.images.length > 4 ? 3 : 2;
  double _ratio = 1;
  double _spacing = .012;
  bool _saving = false;
  String? _error;

  /// Whether the current [_error] can be retried after granting gallery
  /// access ([SaveException.denied]). Typed, not inferred from the message.
  bool _retryable = false;
  Uint8List? _rendered;

  void _change(VoidCallback change) => setState(() {
    change();
    _rendered = null;
    _error = null;
    _retryable = false;
  });

  Future<void> _save() async {
    if (_saving) return;
    setState(() {
      _saving = true;
      _error = null;
      _retryable = false;
    });
    try {
      final Uint8List bytes =
          _rendered ??
          await compute<CollageRequest, Uint8List>(
            renderCollage,
            CollageRequest(
              images: widget.images,
              columns: _columns,
              aspectRatio: _ratio,
              spacing: _spacing,
            ),
          );
      _rendered = bytes;
      if (!mounted) return;
      await SaveService.saveJpeg(
        bytes,
        name: 'lens-collage-${DateTime.now().millisecondsSinceEpoch}',
      );
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Collage saved to gallery')));
    } on SaveException catch (error) {
      if (mounted) {
        setState(() {
          _error = error.message;
          // The retry affordance follows the exception TYPE, not a message
          // substring: localisation or copy edits must not remove it.
          _retryable = error.denied;
        });
      }
    } catch (error, stackTrace) {
      // Covers render failures (compute OOM included) — bare `catch` on
      // purpose: any Error here is equally non-fatal to the session.
      AppLogger.e(
        'Collage render failed',
        context: 'collage_screen',
        error: error,
        stackTrace: stackTrace,
      );
      if (mounted) {
        setState(() {
          _error = 'Could not create the collage. Try different photos.';
          _retryable = false;
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _preview() => Padding(
    padding: const EdgeInsets.all(20),
    child: LayoutBuilder(
      builder: (context, bounds) {
        final width = math.min(bounds.maxWidth, bounds.maxHeight * _ratio);
        final cells = collageCells(
          count: widget.images.length,
          columns: _columns,
          aspectRatio: _ratio,
          spacing: _spacing,
        );
        return Center(
          child: Semantics(
            label: 'Collage preview, ${widget.images.length} photos',
            image: true,
            child: SizedBox(
              width: width,
              height: width / _ratio,
              child: ColoredBox(
                color: Colors.white,
                child: LayoutBuilder(
                  builder: (context, canvas) => Stack(
                    children: [
                      for (var i = 0; i < cells.length; i++)
                        Positioned(
                          left: cells[i].x * canvas.maxWidth,
                          top: cells[i].y * canvas.maxHeight,
                          width: cells[i].width * canvas.maxWidth,
                          height: cells[i].height * canvas.maxHeight,
                          child: Image.memory(
                            widget.images[i],
                            fit: BoxFit.cover,
                            cacheWidth: 800,
                            gaplessPlayback: true,
                            excludeFromSemantics: true,
                            errorBuilder: (_, _, _) => const ColoredBox(
                              color: Colors.white,
                              child: Center(child: Icon(LucideIcons.imageOff)),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        );
      },
    ),
  );

  Widget _controls() {
    final colors = context.themeColors;
    Widget label(String value) => Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        value,
        style: TextStyle(color: colors.primary, fontWeight: FontWeight.w500),
      ),
    );
    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          label('Layout'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final columns in [1, 2, 3])
                if (columns <= widget.images.length)
                  AppChoiceChip(
                    label: columns == 1 ? 'Stack' : '$columns columns',
                    selected: _columns == columns,
                    onTap: _saving
                        ? null
                        : () => _change(() => _columns = columns),
                  ),
            ],
          ),
          const SizedBox(height: 20),
          label('Aspect ratio'),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final ratio in const [
                ('1:1', 1.0),
                ('4:5', .8),
                ('16:9', 16 / 9),
              ])
                AppChoiceChip(
                  label: ratio.$1,
                  selected: _ratio == ratio.$2,
                  onTap: _saving
                      ? null
                      : () => _change(() => _ratio = ratio.$2),
                ),
            ],
          ),
          const SizedBox(height: 20),
          Row(
            children: [
              Expanded(child: label('Spacing')),
              Text(
                '${(_spacing * 100).toStringAsFixed(1)}%',
                style: TextStyle(color: colors.primary),
              ),
            ],
          ),
          Slider(
            value: _spacing,
            min: 0,
            max: .04,
            divisions: 20,
            semanticFormatterCallback: (value) =>
                '${(value * 100).toStringAsFixed(1)} percent',
            onChanged: _saving
                ? null
                : (value) => _change(() => _spacing = value),
          ),
          if (_error != null) ...[
            const SizedBox(height: 8),
            Semantics(
              liveRegion: true,
              child: Text(
                _error!,
                style: TextStyle(color: colors.primary, height: 1.5),
              ),
            ),
            if (_retryable)
              TextButton(
                onPressed: _saving ? null : _save,
                child: const Text('Retry save'),
              ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    return PopScope(
      canPop: !_saving,
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          surfaceTintColor: Colors.transparent,
          title: const Text('Collage'),
          leading: BackButton(
            onPressed: _saving ? null : () => Navigator.of(context).pop(),
          ),
          actions: [
            if (_saving)
              Padding(
                padding: const EdgeInsets.all(16),
                child: Semantics(
                  label: 'Saving collage',
                  liveRegion: true,
                  child: const SizedBox.square(
                    dimension: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  ),
                ),
              )
            else
              TextButton(
                onPressed: _save,
                style: TextButton.styleFrom(
                  foregroundColor: colors.primary,
                  minimumSize: const Size(72, 48),
                ),
                child: const Text('Save'),
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: LayoutBuilder(
            builder: (context, bounds) {
              if (bounds.maxWidth > bounds.maxHeight * 1.25) {
                return Row(
                  children: [
                    Expanded(flex: 6, child: _preview()),
                    Expanded(flex: 4, child: _controls()),
                  ],
                );
              }
              return Column(
                children: [
                  Expanded(child: _preview()),
                  SizedBox(
                    height: math.min(310, bounds.maxHeight * .5),
                    child: _controls(),
                  ),
                ],
              );
            },
          ),
        ),
      ),
    );
  }
}
