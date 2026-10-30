import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/imaging/export/save_service.dart';

/// Unit-level coverage for Task 3.4 save/share.
///
/// Real `Gal` / `SharePlus` / `path_provider` calls need a device
/// (MediaStore / Photos / share sheet / temp dir), so they are NOT mocked
/// here — see the manual device checklist in the Task 3.4 report. These
/// tests pin the pure surface: [SaveException], [sanitizeFileName],
/// [defaultFileName], [buildShareTempPath].
void main() {
  group('SaveException', () {
    test('denied factory marks retryable gallery denial', () {
      final e = SaveException.denied();
      expect(e.denied, isTrue);
      expect(e.message, contains('Gallery access denied'));
      expect(e.cause, isNull);
      expect(e.toString(), contains('Gallery access denied'));
    });

    test('failed factory is non-denied with a generic message', () {
      final e = SaveException.failed();
      expect(e.denied, isFalse);
      expect(e.message, isNotEmpty);
      expect(e.toString(), startsWith('SaveException: '));
    });

    test('failed keeps the cause for diagnostics', () {
      final cause = StateError('disk full');
      final e = SaveException.failed(cause);
      expect(e.denied, isFalse);
      expect(e.cause, same(cause));
      expect(e.toString(), contains('disk full'));
    });
  });

  group('sanitizeFileName', () {
    test('spaces become underscores, .jpg extension stripped', () {
      expect(sanitizeFileName('my photo.jpg'), 'my_photo');
    });

    test('cyrillic is kept (MediaStore/APFS accept UTF-8)', () {
      expect(sanitizeFileName('Моё фото.jpeg'), 'Моё_фото');
      expect(sanitizeFileName('отпуск 2026.PNG'), 'отпуск_2026');
    });

    test('filesystem-unsafe characters are dropped', () {
      expect(sanitizeFileName('a/b\\c:d*e?f"g<h>i|j'), 'abcdefghij');
    });

    test('empty / blank / dot-only input falls back to lens-photo', () {
      expect(sanitizeFileName(''), 'lens-photo');
      expect(sanitizeFileName('   '), 'lens-photo');
      expect(sanitizeFileName('...'), 'lens-photo');
      expect(sanitizeFileName('.jpg'), 'lens-photo');
    });

    test('plain stems pass through, long names capped at 64', () {
      expect(sanitizeFileName('lens-123'), 'lens-123');
      final long = sanitizeFileName('${'a' * 100}.jpg');
      expect(long, 'a' * 64);
    });
  });

  group('defaultFileName', () {
    test('is deterministic with a fixed clock and already safe', () {
      final name = defaultFileName(DateTime.fromMillisecondsSinceEpoch(0));
      expect(name, 'lens-0');
      expect(sanitizeFileName(name), name);
    });
  });

  group('buildShareTempPath', () {
    test('joins temp dir + stem with .jpg', () {
      expect(buildShareTempPath('/tmp/abc', 'lens-1'), '/tmp/abc/lens-1.jpg');
    });

    test('tolerates a trailing separator', () {
      expect(buildShareTempPath('/tmp/abc/', 'lens-1'), '/tmp/abc/lens-1.jpg');
    });
  });
}
