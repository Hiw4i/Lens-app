import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:image/image.dart' as img;

/// Native cameras can produce HEIC/HEIF, which Flutter can display but the
/// CPU export codec cannot read. Normalize only these formats, at full size.
Future<Uint8List> editablePhotoBytes(Uint8List bytes) async {
  if (img.findDecoderForData(bytes) != null) return bytes;
  final codec = await ui.instantiateImageCodec(bytes);
  try {
    final frame = await codec.getNextFrame();
    try {
      final png = await frame.image.toByteData(format: ui.ImageByteFormat.png);
      if (png == null) {
        throw const FormatException('Could not read photo pixels');
      }
      return png.buffer.asUint8List();
    } finally {
      frame.image.dispose();
    }
  } finally {
    codec.dispose();
  }
}
