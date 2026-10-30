import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:fading_edge_scrollview/fading_edge_scrollview.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show PlatformException;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:image_picker/image_picker.dart';
import 'package:lens/app/router.dart';
import 'package:lens/features/collage/collage_screen.dart';
import 'package:lens/features/editor/editor_screen.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/imaging/cache/preview_cache.dart';
import 'package:lens/features/library/logic/device_gallery_provider.dart';
import 'package:lens/features/library/logic/library_provider.dart';
import 'package:lens/features/library/photo_hero.dart';
import 'package:lens/features/settings/settings_screen.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';
import 'package:lens/shared/haptics/app_haptics.dart';
import 'package:lens/shared/haptics/haptics_scope.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';
import 'package:lens/shared/theme/app_text_styles.dart';
import 'package:lens/shared/theme/theme_colors.dart';
import 'package:lens/shared/widgets/buttons/app_button.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';
import 'package:photo_manager/photo_manager.dart';

class LibraryScreen extends ConsumerStatefulWidget {
  const LibraryScreen({super.key});
  @override
  ConsumerState<LibraryScreen> createState() => _LibraryScreenState();
}

class _LibraryScreenState extends ConsumerState<LibraryScreen>
    with WidgetsBindingObserver {
  final _scroll = ScrollController();
  final _albumScroll = ScrollController();
  final _selected = <String, GalleryPhoto>{};
  bool _selecting = false;
  bool _busy = false;
  String? _openingId;

  /// True from the album tap until its first page lands. Dims the outgoing
  /// grid so the old/new photo swap happens under a fade instead of a cut.
  bool _switchingAlbum = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _scroll.addListener(_loadMore);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _scroll.dispose();
    _albumScroll.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !_busy &&
        (ModalRoute.of(context)?.isCurrent ?? false)) {
      ref.invalidate(deviceGalleryProvider);
    }
  }

  void _loadMore() {
    if (_scroll.hasClients && _scroll.position.extentAfter < 700) {
      final gallery = ref.read(deviceGalleryProvider).asData?.value;
      if (gallery != null && !gallery.pageFailed) {
        ref.read(deviceGalleryProvider.notifier).loadMore();
      }
    }
  }

  void _message(String message) {
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(SnackBar(content: Text(message)));
  }

  /// Best-effort platform call: a failure opening a system dialog must not
  /// become an unhandled async error — nothing above the UI catches one.
  Future<void> _runPlatformCall(Future<void> Function() call, String what) async {
    try {
      await call();
    } catch (error, stackTrace) {
      AppLogger.e(
        'Platform call failed: $what',
        context: 'library',
        error: error,
        stackTrace: stackTrace,
      );
    }
  }

  /// Some Android gallery builds surface a user cancel as a platform
  /// exception instead of an empty result. A cancel is not an error.
  bool _isPickerCancel(PlatformException e) =>
      e.code.toLowerCase().contains('cancel');

  Future<void> _import() async {
    if (_busy) return;
    setState(() => _busy = true);
    var requested = 0;
    var imported = 0;
    try {
      if (_selecting) {
        final files = await ImagePicker().pickMultiImage(limit: 9);
        if (!mounted) return;
        final slots = 9 - _selected.length;
        requested = math.min(files.length, slots);
        for (final file in files.take(slots)) {
          try {
            final bytes = await file.readAsBytes();
            if (!mounted) return;
            if (bytes.isEmpty) continue;
            ref.read(libraryImagesProvider.notifier).addImage(bytes);
            final photo = GalleryPhoto.imported(bytes);
            _selected[photo.id] = photo;
            imported++;
          } on Exception catch (error, stackTrace) {
            // One unreadable file must not lose the ones that decoded:
            // they are already in the grid.
            AppLogger.w(
              'Import failed for one photo',
              context: 'library',
              error: error,
              stackTrace: stackTrace,
            );
          }
        }
        if (mounted && requested > 0 && imported < requested) {
          _message(
            imported == 0
                ? 'Could not read the selected photos.'
                : 'Imported $imported of $requested photos.',
          );
        }
      } else {
        final file = await ImagePicker().pickImage(source: ImageSource.gallery);
        if (file == null || !mounted) return;
        final bytes = await file.readAsBytes();
        if (!mounted || bytes.isEmpty) return;
        ref.read(libraryImagesProvider.notifier).addImage(bytes);
        setState(() => _busy = false);
        // Give the new thumbnail its first layout before the Hero lookup.
        await WidgetsBinding.instance.endOfFrame;
        if (mounted) await _open(GalleryPhoto.imported(bytes));
      }
    } on PlatformException catch (error, stackTrace) {
      if (_isPickerCancel(error)) {
        AppLogger.d('Photo picker cancelled', context: 'library');
      } else {
        AppLogger.e(
          'Photo picker failed',
          context: 'library',
          error: error,
          stackTrace: stackTrace,
        );
        _message('Could not open the photo. Please choose another image.');
      }
    } catch (error, stackTrace) {
      AppLogger.e(
        'Import failed',
        context: 'library',
        error: error,
        stackTrace: stackTrace,
      );
      _message('Could not open the photo. Please choose another image.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _open(GalleryPhoto photo) async {
    if (_busy) return;
    if (context.hapticsEnabled) AppHaptics.selection();
    setState(() {
      _busy = true;
      _openingId = photo.id;
    });
    try {
      final bytes = await photo.original();
      final preview = await PreviewCache.previewBytes(bytes);
      final ui.Codec codec = await ui.instantiateImageCodec(preview);
      final double aspect;
      ui.FrameInfo? frame;
      try {
        frame = await codec.getNextFrame();
        aspect = frame.image.width / frame.image.height;
      } finally {
        // The codec and its frame are native handles: they must be
        // released even when the aspect read or a later step throws.
        frame?.image.dispose();
        codec.dispose();
      }
      if (!mounted) return;
      Object? decodeError;
      await precacheImage(
        MemoryImage(preview),
        context,
        onError: (error, _) => decodeError = error,
      );
      if (!mounted) return;
      if (decodeError != null) throw decodeError!;
      ref.read(editorStateProvider.notifier).setPreviewBytes(bytes);
      ref.read(editorStateProvider.notifier).setPhotoAspect(aspect);
      final duration = context.uiPerformance.motionDuration(
        const Duration(milliseconds: 480),
      );
      setState(() => _openingId = null);
      await LensRouter.pushPage<void>(
        context,
        EditorScreen(
          photoId: photo.id,
          photoAspectRatio: aspect,
          transitionBytes: preview,
        ),
        name: 'editor',
        transitionDuration: duration,
      );
      if (mounted) ref.invalidate(deviceGalleryProvider);
    } catch (error, stackTrace) {
      AppLogger.e(
        'Photo could not be opened',
        context: 'library',
        error: error,
        stackTrace: stackTrace,
      );
      _message(
        'This photo could not be loaded. Try another photo or download it to your device.',
      );
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _openingId = null;
        });
      }
    }
  }

  void _toggle(GalleryPhoto photo) {
    if (_busy) return;
    if (_selected.containsKey(photo.id)) {
      if (context.hapticsEnabled) AppHaptics.selection();
      setState(() => _selected.remove(photo.id));
    } else if (_selected.length < 9) {
      if (context.hapticsEnabled) AppHaptics.selection();
      setState(() => _selected[photo.id] = photo);
    } else {
      _message('Choose up to 9 photos for one collage.');
    }
  }

  /// Switches the album with a short scroll reset and a dim over the old
  /// grid. The provider keeps the previous photos on screen while the first
  /// page loads, so without the dim the new page would replace them with a
  /// hard cut.
  void _selectAlbum(AssetPathEntity album) {
    if (_busy || _switchingAlbum) return;
    final DeviceGallery? current = ref
        .read(deviceGalleryProvider)
        .asData
        ?.value;
    if (current?.selectedAlbum?.id == album.id) return;
    final Duration duration = context.uiPerformance.motionDuration(
      const Duration(milliseconds: 240),
    );
    if (_scroll.hasClients && _scroll.offset > 0) {
      if (duration == Duration.zero) {
        _scroll.jumpTo(0);
      } else {
        _scroll.animateTo(0, duration: duration, curve: Curves.easeOutCubic);
      }
    }
    setState(() => _switchingAlbum = true);
    ref.read(deviceGalleryProvider.notifier).selectAlbum(album);
  }

  Future<void> _createCollage() async {
    if (_busy || _selected.length < 2) return;
    setState(() => _busy = true);
    try {
      final images = <Uint8List>[];
      for (final photo in _selected.values) {
        images.add(await photo.original());
        if (!mounted) return;
      }
      await LensRouter.pushMaterial<void>(
        context,
        CollageScreen(images: images),
        name: 'collage',
      );
      if (mounted) ref.invalidate(deviceGalleryProvider);
    } catch (error, stackTrace) {
      AppLogger.e(
        'Collage could not be created',
        context: 'library',
        error: error,
        stackTrace: stackTrace,
      );
      _message(
        'A selected photo is unavailable. Choose another photo and try again.',
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    final gallery = ref.watch(deviceGalleryProvider);
    // The dim is only for the album-switch window: clear it as soon as the
    // new first page is in (or the switch failed and settled).
    ref.listen(deviceGalleryProvider, (previous, next) {
      if (!_switchingAlbum) return;
      final DeviceGallery? value = next.asData?.value;
      if (value != null && !value.loadingMore) {
        setState(() => _switchingAlbum = false);
      }
    });
    final device = gallery.value;
    final images = [
      ...ref.watch(libraryImagesProvider).reversed.map(GalleryPhoto.imported),
      ...?device?.photos,
    ];
    return PopScope(
      canPop: !_selecting && !_busy,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && _selecting && !_busy) {
          setState(() {
            _selecting = false;
            _selected.clear();
          });
        }
      },
      child: Scaffold(
        backgroundColor: colors.background,
        appBar: AppBar(
          backgroundColor: colors.background,
          surfaceTintColor: Colors.transparent,
          automaticallyImplyLeading: false,
          title: AnimatedSwitcher(
            duration: context.uiPerformance.motionDuration(
              const Duration(milliseconds: 160),
            ),
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            child: MediaQuery.withClampedTextScaling(
              maxScaleFactor: 1.3,
              child: Text(
                _selecting ? 'Choose photos' : 'Lens',
                key: ValueKey(_selecting),
                style: TextStyle(
                  color: colors.primary,
                  fontSize: 26,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ),
          actions: [
            if (_selecting)
              AppButton.iconGhost(
                icon: LucideIcons.x,
                tooltip: 'Cancel selection',
                size: 44,
                iconSize: 20,
                onTap: _busy
                    ? null
                    : () => setState(() {
                        _selecting = false;
                        _selected.clear();
                      }),
                style: AppButtonStyle(foregroundColor: colors.primary),
              )
            else
              AppButton.ghost(
                icon: LucideIcons.settings2,
                tooltip: 'Settings',
                onTap: _busy
                    ? null
                    : () => LensRouter.pushMaterial(
                        context,
                        const SettingsScreen(),
                        name: 'settings',
                      ),
                width: 44,
                height: 44,
                minHeight: 44,
                shrinkWrap: true,
                padding: EdgeInsets.zero,
                borderRadius: 12,
                iconSize: 20,
                style: AppButtonStyle(foregroundColor: colors.primary),
              ),
            const SizedBox(width: 8),
          ],
        ),
        body: SafeArea(
          top: false,
          child: Stack(
            children: [
              NotificationListener<ScrollMetricsNotification>(
                onNotification: (_) {
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    if (mounted) _loadMore();
                  });
                  return false;
                },
                child: CustomScrollView(
                  key: const PageStorageKey('library-grid'),
                  controller: _scroll,
                  slivers: [
                    SliverToBoxAdapter(
                      child: AnimatedSize(
                        duration: context.uiPerformance.motionDuration(
                          const Duration(milliseconds: 220),
                        ),
                        curve: Curves.easeOutCubic,
                        alignment: Alignment.topCenter,
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(20, 16, 20, 24),
                          // Only the current child exists (no stacked outgoing
                          // layer), so the buttons can never be tapped invisibly
                          // while the header fades. AnimatedSize owns the height.
                          child: TweenAnimationBuilder<double>(
                            key: ValueKey(_selecting),
                            tween: Tween<double>(begin: 0, end: 1),
                            duration: context.uiPerformance.motionDuration(
                              const Duration(milliseconds: 160),
                            ),
                            curve: Curves.easeOutCubic,
                            builder: (context, t, child) =>
                                Opacity(opacity: t, child: child),
                            child: _selecting
                                ? Text(
                                    'Select 2–9 photos in the order you want them to appear.',
                                    style: TextStyle(
                                      color: colors.primary,
                                      height: 1.5,
                                    ),
                                  )
                                : Row(
                                    children: [
                                      Expanded(
                                        child: AppButton.primary(
                                          label: 'Edit',
                                          icon: LucideIcons.slidersHorizontal,
                                          iconSize: 20,
                                          minHeight: 56,
                                          borderRadius: 16,
                                          onTap: _busy ? null : _import,
                                          style: const AppButtonStyle(
                                            textStyle: AppTextStyles.buttonSmall,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 12),
                                      Expanded(
                                        child: AppButton.secondary(
                                          label: 'Collage',
                                          icon: LucideIcons.panelsTopLeft,
                                          iconSize: 20,
                                          minHeight: 56,
                                          borderRadius: 16,
                                          onTap: _busy
                                              ? null
                                              : () => setState(
                                                  () => _selecting = true,
                                                ),
                                          style: AppButtonStyle(
                                            backgroundColor: Colors.transparent,
                                            foregroundColor: colors.primary,
                                            border: BorderSide(
                                              color: colors.secondary,
                                            ),
                                            textStyle: AppTextStyles.buttonSmall,
                                          ),
                                        ),
                                      ),
                                    ],
                                  ),
                          ),
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(20, 0, 12, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: AnimatedSwitcher(
                                duration: context.uiPerformance.motionDuration(
                                  const Duration(milliseconds: 160),
                                ),
                                switchInCurve: Curves.easeOutCubic,
                                switchOutCurve: Curves.easeInCubic,
                                child: Text(
                                  _selecting
                                      ? '${_selected.length} selected'
                                      : 'All photos',
                                  key: ValueKey(_selecting),
                                  style: TextStyle(
                                    color: colors.primary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ),
                            ),
                            AppButton.iconGhost(
                              icon: LucideIcons.plus,
                              tooltip: _selecting
                                  ? 'Choose from device'
                                  : 'Open photo picker',
                              size: 44,
                              iconSize: 20,
                              onTap: _busy ? null : _import,
                              style: AppButtonStyle(
                                foregroundColor: colors.primary,
                              ),
                            ),
                            AppButton.iconGhost(
                              icon: LucideIcons.refreshCw,
                              tooltip: 'Refresh photos',
                              size: 44,
                              iconSize: 18,
                              onTap: _busy
                                  ? null
                                  : () => ref.invalidate(deviceGalleryProvider),
                              style: AppButtonStyle(
                                foregroundColor: colors.primary,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (device?.limited ?? false)
                      SliverToBoxAdapter(
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 20),
                          child: AppButton.ghost(
                            label: 'Limited photo access · Manage photos',
                            onTap: _busy
                                ? null
                                : () async {
                                    await _runPlatformCall(
                                      () => PhotoManager.presentLimited(
                                        type: RequestType.image,
                                      ),
                                      'presentLimited',
                                    );
                                    if (mounted) {
                                      ref.invalidate(deviceGalleryProvider);
                                    }
                                  },
                            shrinkWrap: true,
                            minHeight: 44,
                            padding: const EdgeInsets.symmetric(horizontal: 4),
                            style: AppButtonStyle(
                              foregroundColor: colors.primary,
                              textStyle: AppTextStyles.buttonSmall,
                            ),
                          ),
                        ),
                      ),
                    if ((device?.albums ?? const []).isNotEmpty)
                      SliverToBoxAdapter(
                        child: SizedBox(
                          height: 44,
                          child: MediaQuery.withClampedTextScaling(
                            maxScaleFactor: 1.3,
                            child: FadingEdgeScrollView.fromScrollView(
                              gradientFractionOnStart: 0.15,
                              gradientFractionOnEnd: 0.15,
                              child: ListView.separated(
                                controller: _albumScroll,
                                scrollDirection: Axis.horizontal,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                ),
                                itemCount: device!.albums.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(width: 8),
                                itemBuilder: (context, index) {
                                  final album = device.albums[index];
                                  final selected =
                                      album.id == device.selectedAlbum?.id;
                                  return AppButton.secondary(
                                    label: album.name.isEmpty
                                        ? 'Album'
                                        : album.name,
                                    onTap: _busy
                                        ? null
                                        : () => _selectAlbum(album),
                                    minHeight: 36,
                                    shrinkWrap: true,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                      vertical: 4,
                                    ),
                                    style: AppButtonStyle(
                                      backgroundColor: selected
                                          ? colors.surfaceBright
                                          : colors.surface,
                                      border: BorderSide(color: colors.border),
                                    ),
                                  );
                                },
                              ),
                            ),
                          ),
                        ),
                      ),
                    if (images.isNotEmpty)
                      SliverLayoutBuilder(
                        builder: (context, constraints) => SliverPadding(
                          padding: const EdgeInsets.fromLTRB(2, 12, 2, 12),
                          sliver: SliverGrid.builder(
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount:
                                      (constraints.crossAxisExtent / 130)
                                          .floor()
                                          .clamp(3, 8),
                                  crossAxisSpacing: 2,
                                  mainAxisSpacing: 2,
                                ),
                            itemCount: images.length,
                            itemBuilder: (context, index) => _PhotoTile(
                              key: ValueKey(images[index].id),
                              photo: images[index],
                              index: index,
                              selection: _selecting
                                  ? _selected.keys.toList().indexOf(
                                          images[index].id,
                                        ) +
                                        1
                                  : null,
                              opening: _openingId == images[index].id,
                              onTap: _busy
                                  ? null
                                  : () => _selecting
                                        ? _toggle(images[index])
                                        : _open(images[index]),
                            ),
                          ),
                        ),
                      )
                    else
                      SliverFillRemaining(
                        hasScrollBody: false,
                        child: Padding(
                          padding: const EdgeInsets.all(32),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (gallery.isLoading)
                                  const CircularProgressIndicator(
                                    strokeWidth: 2,
                                  )
                                else ...[
                                  Icon(
                                    LucideIcons.image,
                                    size: 36,
                                    color: colors.secondary,
                                  ),
                                  const SizedBox(height: 16),
                                  Text(
                                    device?.allowed == false
                                        ? 'Your photos, with your permission'
                                        : gallery.hasError
                                        ? 'Could not load your photos'
                                        : 'Library is empty',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w500,
                                      color: colors.primary,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  Text(
                                    device?.allowed == false
                                        ? 'Allow photo access or choose individual photos to get started.'
                                        : 'Choose a photo to start creating.',
                                    textAlign: TextAlign.center,
                                    style: TextStyle(
                                      color: colors.primary,
                                      height: 1.5,
                                    ),
                                  ),
                                  const SizedBox(height: 16),
                                  if (device?.allowed == false)
                                    AppButton.ghost(
                                      label: 'Allow photo access',
                                      onTap: () => _runPlatformCall(
                                        PhotoManager.openSetting,
                                        'openSetting',
                                      ),
                                      shrinkWrap: true,
                                      minHeight: 44,
                                      style: AppButtonStyle(
                                        foregroundColor: colors.primary,
                                        textStyle: AppTextStyles.buttonSmall,
                                      ),
                                    ),
                                  AppButton.primary(
                                    label: 'Choose photos',
                                    minHeight: 48,
                                    borderRadius: 16,
                                    onTap: _busy ? null : _import,
                                    style: const AppButtonStyle(
                                      textStyle: AppTextStyles.buttonSmall,
                                    ),
                                  ),
                                  if (gallery.hasError)
                                    AppButton.ghost(
                                      label: 'Try again',
                                      onTap: () =>
                                          ref.invalidate(deviceGalleryProvider),
                                      shrinkWrap: true,
                                      minHeight: 44,
                                      style: AppButtonStyle(
                                        foregroundColor: colors.primary,
                                        textStyle: AppTextStyles.buttonSmall,
                                      ),
                                    ),
                                ],
                              ],
                            ),
                          ),
                        ),
                      ),
                    if (device?.loadingMore ?? false)
                      const SliverToBoxAdapter(
                        child: Center(
                          child: Padding(
                            padding: EdgeInsets.all(16),
                            child: CircularProgressIndicator(strokeWidth: 2),
                          ),
                        ),
                      ),
                    if (device?.pageFailed ?? false)
                      SliverToBoxAdapter(
                        child: AppButton.ghost(
                          label: 'Could not load more photos · Retry',
                          onTap: () => ref
                              .read(deviceGalleryProvider.notifier)
                              .loadMore(),
                          shrinkWrap: true,
                          minHeight: 44,
                          style: AppButtonStyle(
                            foregroundColor: colors.primary,
                            textStyle: AppTextStyles.buttonSmall,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              // Album switch: dim the outgoing grid while the first page loads,
              // then fade the new photos back in. The provider keeps the old
              // photos visible until the page lands, so this is what makes the
              // replacement read as a transition rather than a hard cut.
              Positioned.fill(
                child: IgnorePointer(
                  child: AnimatedOpacity(
                    opacity: _switchingAlbum ? 1 : 0,
                    duration: context.uiPerformance.motionDuration(
                      const Duration(milliseconds: 180),
                    ),
                    curve: Curves.easeOutCubic,
                    child: ColoredBox(
                      color: colors.background.withValues(alpha: 0.55),
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        bottomNavigationBar: AnimatedSize(
          duration: context.uiPerformance.motionDuration(
            const Duration(milliseconds: 220),
          ),
          curve: Curves.easeOutCubic,
          alignment: Alignment.bottomCenter,
          child: _selecting
              ? SafeArea(
                  top: false,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                    child: AppButton.primary(
                      minHeight: 52,
                      borderRadius: 16,
                      onTap: !_busy && _selected.length >= 2
                          ? _createCollage
                          : null,
                      style: const AppButtonStyle(
                        textStyle: AppTextStyles.buttonSmall,
                      ),
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(
                              _selected.length < 2
                                  ? 'Select at least 2 photos'
                                  : 'Create collage · ${_selected.length} photos',
                            ),
                    ),
                  ),
                )
              : const SizedBox(width: double.infinity),
        ),
      ),
    );
  }
}

class _PhotoTile extends StatefulWidget {
  const _PhotoTile({
    super.key,
    required this.photo,
    required this.index,
    required this.onTap,
    required this.selection,
    required this.opening,
  });
  final GalleryPhoto photo;
  final int index;
  final int? selection;
  final bool opening;
  final VoidCallback? onTap;
  @override
  State<_PhotoTile> createState() => _PhotoTileState();
}

class _PhotoTileState extends State<_PhotoTile> {
  late final _thumbnail = widget.photo.thumbnail();
  @override
  Widget build(BuildContext context) {
    final colors = context.themeColors;
    return FutureBuilder<Uint8List?>(
      future: _thumbnail,
      builder: (context, snapshot) {
        final bytes = snapshot.data;
        final Duration tileFade = context.uiPerformance.motionDuration(
          const Duration(milliseconds: 220),
        );
        final Widget placeholder = Center(
          child: Icon(
            snapshot.hasError ? LucideIcons.imageOff : LucideIcons.image,
            color: colors.secondary,
            size: 24,
          ),
        );
        final Widget media = SizedBox.expand(
          child: AnimatedSwitcher(
            duration: tileFade,
            switchInCurve: Curves.easeOutCubic,
            switchOutCurve: Curves.easeInCubic,
            // Expand the layers: the default loose Stack would let the image
            // shrink to its intrinsic size inside the tile.
            layoutBuilder: (current, previous) => Stack(
              fit: StackFit.expand,
              alignment: Alignment.center,
              children: [...previous, ?current],
            ),
            child: bytes == null
                ? KeyedSubtree(
                    key: const ValueKey('placeholder'),
                    child: placeholder,
                  )
                : PhotoHero(
                    key: const ValueKey('photo'),
                    id: widget.photo.id,
                    bytes: bytes,
                    child: Image.memory(
                      bytes,
                      fit: BoxFit.cover,
                      gaplessPlayback: true,
                      cacheWidth: 360,
                      errorBuilder: (_, _, _) => Center(
                        child: Icon(
                          LucideIcons.imageOff,
                          color: colors.secondary,
                          size: 24,
                        ),
                      ),
                    ),
                  ),
          ),
        );
        final int? selection = widget.selection;
        return Semantics(
          label: 'Photo ${widget.index + 1}',
          value: selection != null && selection > 0
              ? 'Position $selection'
              : null,
          button: true,
          selected: selection == null ? null : selection > 0,
          child: Material(
            color: colors.surface,
            clipBehavior: Clip.hardEdge,
            child: Stack(
              fit: StackFit.expand,
              children: [
                media,
                Material(
                  color: Colors.transparent,
                  child: InkWell(onTap: widget.onTap),
                ),
                // The badge is always built so entering selection mode can
                // scale/fade it in instead of popping a new widget into the
                // tile; the empty circle doubles as the unselected state.
                Positioned(
                  top: 8,
                  right: 8,
                  child: IgnorePointer(
                    child: ExcludeSemantics(
                      child: AnimatedScale(
                        scale: selection == null ? 0.8 : 1,
                        duration: context.uiPerformance.motionDuration(
                          const Duration(milliseconds: 140),
                        ),
                        curve: Curves.easeOutCubic,
                        child: AnimatedOpacity(
                          opacity: selection == null ? 0 : 1,
                          duration: context.uiPerformance.motionDuration(
                            const Duration(milliseconds: 140),
                          ),
                          curve: Curves.easeOutCubic,
                          child: AnimatedContainer(
                            duration: tileFade,
                            width: 28,
                            height: 28,
                            alignment: Alignment.center,
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              color: selection != null && selection > 0
                                  ? colors.primary
                                  : colors.background,
                              border: Border.all(
                                color: colors.primary,
                                width: 1.5,
                              ),
                            ),
                            child: selection != null && selection > 0
                                ? FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(
                                      '$selection',
                                      style: TextStyle(
                                        color: colors.primaryInverse,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  )
                                : null,
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
                if (widget.opening)
                  const Center(
                    child: SizedBox.square(
                      dimension: 24,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }
}
