import 'dart:io';
import 'dart:typed_data';

import 'package:gal/gal.dart';
import 'package:lens/shared/diagnostics/app_logger.dart';
import 'package:path_provider/path_provider.dart';
import 'package:share_plus/share_plus.dart';

/// Error thrown by [SaveService.saveJpeg] / [SaveService.shareJpeg].
///
/// Always thrown (never returns null/bool): callers show [message] in a
/// SnackBar. [denied] marks the gallery-permission case, where the UI
/// additionally offers a retry button (system dialog may re-appear).
class SaveException implements Exception {
  const SaveException(this.message, {this.denied = false, this.cause});

  /// Gallery/system permission denied — user can retry after granting access.
  factory SaveException.denied() => const SaveException(
    'Gallery access denied. Allow access in Settings, then try again.',
    denied: true,
  );

  /// Any other failure (full storage, I/O error, share-sheet unavailable).
  factory SaveException.failed([Object? cause]) => SaveException(
    'Could not save the photo. Please try again.',
    cause: cause,
  );

  final String message;
  final bool denied;
  final Object? cause;

  @override
  String toString() =>
      'SaveException: $message${cause == null ? '' : ' ($cause)'}';
}

/// Sanitizes a user-supplied file stem into a gallery/temp-safe base name
/// (WITHOUT extension — `Gal.putImageBytes` appends it itself).
///
/// Rules: trim; strip a trailing image extension (`.jpg`/`.jpeg`/`.png`);
/// whitespace runs → single `_`; drop filesystem-unsafe characters
/// (`\/:*?"<>|` + control chars); keep everything else — including Cyrillic
/// and other Unicode letters (MediaStore and APFS both accept UTF-8, so
/// transliteration would only destroy information); cap at 64 chars;
/// fall back to `'lens-photo'` when nothing safe remains.
String sanitizeFileName(String raw) {
  var stem = raw.trim();
  stem = stem.replaceFirst(RegExp(r'\.(jpe?g|png)$', caseSensitive: false), '');
  stem = stem.replaceAll(RegExp(r'\s+'), '_');
  stem = stem.replaceAll(RegExp(r'[\\/:*?"<>|\x00-\x1F]'), '');
  // Remove leading/trailing dots/underscores left over from stripping.
  stem = stem.replaceAll(RegExp(r'^[._]+|[._]+$'), '');
  if (stem.length > 64) stem = stem.substring(0, 64);
  if (stem.isEmpty) return 'lens-photo';
  return stem;
}

/// Default export stem: `lens-<epoch-ms>`, unique per render.
String defaultFileName([DateTime? now]) =>
    'lens-${(now ?? DateTime.now()).millisecondsSinceEpoch}';

/// Builds the temp-file path used for sharing (pure: no I/O, unit-testable).
///
/// [tempDir] is the `getTemporaryDirectory()` path; [stem] is a
/// [sanitizeFileName]-clean base name. Always ends with `.jpg`.
String buildShareTempPath(String tempDir, String stem) {
  final dir = tempDir.endsWith('/') || tempDir.endsWith(r'\')
      ? tempDir.substring(0, tempDir.length - 1)
      : tempDir;
  return '$dir/$stem.jpg';
}

/// Saves rendered JPEG bytes to the gallery and opens the system share sheet.
///
/// Platform calls (`Gal`, `SharePlus`, `path_provider`) are intentionally
/// NOT unit-mocked: they need a real device (MediaStore / Photos /
/// `UIActivityViewController`). Unit tests cover [SaveException],
/// [sanitizeFileName], [defaultFileName] and [buildShareTempPath];
/// save/share themselves require the manual device checklist in the
/// Task 3.4 report.
abstract final class SaveService {
  /// Writes [bytes] to the gallery via `Gal.putImageBytes`.
  ///
  /// Throws [SaveException.denied] when the OS gallery permission is denied,
  /// [SaveException.failed] otherwise (including empty input).
  static Future<void> saveJpeg(Uint8List bytes, {String? name}) async {
    if (bytes.isEmpty) {
      throw SaveException.failed('empty image data');
    }
    final stem = sanitizeFileName(name ?? defaultFileName());
    try {
      await Gal.putImageBytes(bytes, name: stem);
    } on GalException catch (e) {
      if (e.type == GalExceptionType.accessDenied) {
        throw SaveException.denied();
      }
      AppLogger.e(
        'Gallery write failed',
        context: 'save_service',
        error: e,
      );
      throw SaveException.failed(e);
    } catch (e, s) {
      AppLogger.e('Gallery write failed', context: 'save_service', error: e, stackTrace: s);
      throw SaveException.failed(e);
    }
  }

  /// Writes [bytes] to a temp `.jpg` and opens the system share sheet.
  ///
  /// Returns the platform [ShareResult] (`dismissed` when the user closes
  /// the sheet without sharing — not an error). Throws [SaveException.failed]
  /// when the temp write or the share sheet itself fails.
  static Future<ShareResult> shareJpeg(Uint8List bytes, {String? name}) async {
    if (bytes.isEmpty) {
      throw SaveException.failed('empty image data');
    }
    final stem = sanitizeFileName(name ?? defaultFileName());
    try {
      final dir = await getTemporaryDirectory();
      final path = buildShareTempPath(dir.path, stem);
      await File(path).writeAsBytes(bytes, flush: true);
      final result = await SharePlus.instance.share(
        ShareParams(
          files: [XFile(path, mimeType: 'image/jpeg', name: '$stem.jpg')],
        ),
      );
      return result;
    } catch (e) {
      if (e is SaveException) rethrow;
      throw SaveException.failed(e);
    }
  }
}
