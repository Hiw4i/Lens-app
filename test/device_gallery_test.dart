import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/library/logic/device_gallery_provider.dart';

class DelayedGallery extends PhotoGallerySource {
  bool allowed = true;
  final pending = Completer<List<GalleryPhoto>>();
  @override
  Future<GalleryAccess> open() async => GalleryAccess(allowed: allowed);
  @override
  Future<List<GalleryPhoto>> page(
    GalleryAccess access,
    int page,
    int size,
  ) async {
    if (page > 0) return pending.future;
    return List.generate(60, (i) => GalleryPhoto(id: 'photo-$i'));
  }
}

void main() {
  test(
    'an old page cannot restore photos after access is revoked and refreshed',
    () async {
      final source = DelayedGallery();
      final container = ProviderContainer.test(
        overrides: [photoGallerySourceProvider.overrideWithValue(source)],
      );
      addTearDown(container.dispose);
      await container.read(deviceGalleryProvider.future);
      final load = container.read(deviceGalleryProvider.notifier).loadMore();
      source.allowed = false;
      container.invalidate(deviceGalleryProvider);
      expect(
        (await container.read(deviceGalleryProvider.future)).allowed,
        isFalse,
      );
      source.pending.complete([const GalleryPhoto(id: 'old-photo')]);
      await load;
      final gallery = container.read(deviceGalleryProvider).requireValue;
      expect(gallery.allowed, isFalse);
      expect(gallery.photos, isEmpty);
    },
  );
}
