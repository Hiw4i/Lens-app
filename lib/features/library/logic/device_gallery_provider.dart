import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:lens/features/imaging/photo_source.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';
import 'package:photo_manager/photo_manager.dart';

/// Asset handles keep the library small: originals are read on selection only.
class GalleryPhoto {
  const GalleryPhoto({required this.id, this.asset, this.bytes});
  factory GalleryPhoto.imported(Uint8List bytes) =>
      GalleryPhoto(id: 'import-${identityHashCode(bytes)}', bytes: bytes);
  final String id;
  final AssetEntity? asset;
  final Uint8List? bytes;

  Future<Uint8List?> thumbnail() async =>
      bytes ??
      await asset?.thumbnailDataWithSize(const ThumbnailSize.square(360));

  Future<Uint8List> original() async {
    if (bytes != null) return editablePhotoBytes(bytes!);
    final file = await asset?.file;
    if (file == null) throw StateError('Photo is unavailable');
    return editablePhotoBytes(await file.readAsBytes());
  }
}

class DeviceGallery {
  const DeviceGallery({
    this.photos = const [],
    this.allowed = true,
    this.limited = false,
    this.hasMore = false,
    this.loadingMore = false,
    this.pageFailed = false,
    this.albums = const [],
    this.selectedAlbum,
  });
  final List<GalleryPhoto> photos;
  final bool allowed, limited, hasMore, loadingMore, pageFailed;
  final List<AssetPathEntity> albums;
  final AssetPathEntity? selectedAlbum;
}

final deviceGalleryProvider =
    AsyncNotifierProvider<DeviceGalleryNotifier, DeviceGallery>(
      DeviceGalleryNotifier.new,
    );

/// A permission snapshot and album belong to one immutable load session.
class GalleryAccess {
  const GalleryAccess({
    this.allowed = true,
    this.limited = false,
    this.album,
    this.albums = const [],
  });
  final bool allowed, limited;
  final AssetPathEntity? album;
  final List<AssetPathEntity> albums;
}

final photoGallerySourceProvider = Provider<PhotoGallerySource>(
  (ref) => PhotoGallerySource(),
);

class PhotoGallerySource {
  static const _permission = PermissionRequestOption(
    androidPermission: AndroidPermission(
      type: RequestType.image,
      mediaLocation: false,
    ),
  );

  Future<GalleryAccess> open() async {
    if (!Platform.isAndroid && !Platform.isIOS) return const GalleryAccess();
    final permission = await PhotoManager.requestPermissionExtend(
      requestOption: _permission,
    );
    if (!permission.hasAccess) return const GalleryAccess(allowed: false);
    final albums = await PhotoManager.getAssetPathList(
      hasAll: true,
      onlyAll: false,
      type: RequestType.image,
      filterOption: FilterOptionGroup(
        orders: [
          const OrderOption(type: OrderOptionType.createDate, asc: false),
        ],
      ),
    );
    return GalleryAccess(
      limited: permission == PermissionState.limited,
      album: albums.isEmpty ? null : albums.first,
      albums: albums,
    );
  }

  Future<List<GalleryPhoto>> page(
    GalleryAccess access,
    int page,
    int size,
  ) async {
    final assets =
        await access.album?.getAssetListPaged(page: page, size: size) ?? [];
    return [
      for (final asset in assets)
        GalleryPhoto(id: 'asset-${asset.id}', asset: asset),
    ];
  }
}

class DeviceGalleryNotifier extends AsyncNotifier<DeviceGallery> {
  GalleryAccess? _access;
  int _page = 0;
  static const _size = 60;
  List<AssetPathEntity> _albums = const [];

  @override
  Future<DeviceGallery> build() async {
    // Riverpod retains the notifier on invalidate but replaces its Ref. Capture
    // that exact Ref so old permission/page futures cannot mutate a new session.
    final operation = ref;
    _access = null;
    _page = 0;
    _albums = const [];
    final source = operation.watch(photoGallerySourceProvider);
    final access = await source.open();
    if (!operation.mounted) return const DeviceGallery();
    if (!access.allowed) {
      return DeviceGallery(allowed: false, albums: access.albums);
    }
    _albums = access.albums;
    final photos = await source.page(access, 0, _size);
    if (!operation.mounted) return const DeviceGallery();
    _access = access;
    return DeviceGallery(
      photos: photos,
      limited: access.limited,
      hasMore: photos.length == _size,
      albums: access.albums,
      selectedAlbum: access.album,
    );
  }

  Future<void> selectAlbum(AssetPathEntity album) async {
    final operation = ref;
    final current = state.asData?.value;
    final access = GalleryAccess(
      allowed: true,
      limited: _access?.limited ?? false,
      album: album,
      albums: _albums,
    );
    _access = access;
    _page = 0;
    state = AsyncData(
      DeviceGallery(
        photos: current?.photos ?? const [],
        limited: access.limited,
        hasMore: true,
        loadingMore: true,
        albums: _albums,
        selectedAlbum: album,
      ),
    );
    try {
      final source = operation.read(photoGallerySourceProvider);
      final photos = await source.page(access, 0, _size);
      if (!operation.mounted) return;
      state = AsyncData(
        DeviceGallery(
          photos: photos,
          limited: access.limited,
          hasMore: photos.length == _size,
          albums: _albums,
          selectedAlbum: album,
        ),
      );
    } catch (error, stackTrace) {
      // The UI shows a retry via `pageFailed`; the raw error is preserved
      // in the log so a persistent platform failure is diagnosable.
      AppLogger.e(
        'Album page failed',
        context: 'device_gallery',
        error: error,
        stackTrace: stackTrace,
      );
      if (!operation.mounted) return;
      state = AsyncData(
        DeviceGallery(
          photos: current?.photos ?? const [],
          limited: access.limited,
          hasMore: true,
          pageFailed: true,
          albums: _albums,
          selectedAlbum: album,
        ),
      );
    }
  }

  Future<void> loadMore() async {
    final operation = ref;
    final current = state.asData?.value;
    final access = _access;
    if (current == null ||
        !current.hasMore ||
        current.loadingMore ||
        access == null) {
      return;
    }
    final nextPage = _page + 1;
    final source = operation.read(photoGallerySourceProvider);
    state = AsyncData(
      DeviceGallery(
        photos: current.photos,
        limited: current.limited,
        hasMore: true,
        loadingMore: true,
        albums: current.albums,
        selectedAlbum: current.selectedAlbum,
      ),
    );
    try {
      final photos = await source.page(access, nextPage, _size);
      // A page started for the previous album must not land after a switch:
      // it would splice the old album's photos into the new one.
      if (!operation.mounted || !identical(_access, access)) return;
      _page = nextPage;
      final ids = current.photos.map((photo) => photo.id).toSet();
      state = AsyncData(
        DeviceGallery(
          photos: [
            ...current.photos,
            ...photos.where((photo) => !ids.contains(photo.id)),
          ],
          limited: current.limited,
          hasMore: photos.length == _size,
          albums: current.albums,
          selectedAlbum: current.selectedAlbum,
        ),
      );
    } catch (error, stackTrace) {
      AppLogger.e(
        'Gallery load-more failed',
        context: 'device_gallery',
        error: error,
        stackTrace: stackTrace,
      );
      if (!operation.mounted || !identical(_access, access)) return;
      state = AsyncData(
        DeviceGallery(
          photos: current.photos,
          limited: current.limited,
          hasMore: true,
          pageFailed: true,
          albums: current.albums,
          selectedAlbum: current.selectedAlbum,
        ),
      );
    }
  }
}
