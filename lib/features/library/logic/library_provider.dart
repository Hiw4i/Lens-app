import 'dart:typed_data';

import 'package:flutter_riverpod/flutter_riverpod.dart';

/// In-memory image library. Persistence and real gallery integration
/// (photo_manager) land later; this shell only holds imported bytes.
final libraryImagesProvider =
    NotifierProvider<LibraryImagesNotifier, List<Uint8List>>(
      LibraryImagesNotifier.new,
    );

class LibraryImagesNotifier extends Notifier<List<Uint8List>> {
  @override
  List<Uint8List> build() => const [];

  void addImage(Uint8List bytes) {
    // Empty reads (cancelled picker, failed file) must never enter the
    // grid: Image.memory would throw on them at layout time.
    if (bytes.isEmpty) return;
    state = [...state, bytes];
  }

  void clear() {
    if (state.isNotEmpty) state = const [];
  }
}
