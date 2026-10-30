import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:lens/features/imaging/cache/structure_cache.dart';
import 'package:lens/features/imaging/structure/structure_filter.dart';

/// A deterministic test picture: a horizontal gradient with a bright block,
/// so the guided filter has both a ramp and a hard edge to work on.
Uint8List _png(int width, int height, {int seed = 0}) {
  final image = img.Image(width: width, height: height, numChannels: 3);
  for (var y = 0; y < height; y++) {
    for (var x = 0; x < width; x++) {
      final int r = ((x * 255) ~/ math.max(1, width - 1) + seed) % 256;
      final int g = ((y * 255) ~/ math.max(1, height - 1) + seed * 2) % 256;
      final bool block = x >= width ~/ 4 && x < width ~/ 2;
      final int b = block ? 230 : 40;
      image.setPixelRgb(x, y, r, g, b);
    }
  }
  return Uint8List.fromList(img.encodePng(image));
}

/// The low-res grid size the cache must produce for a [width] x [height]
/// source: `ceil(w / s) * ceil(h / s)`.
(int, int) _grid(int width, int height) {
  final StructureGeometry geometry = structureGeometryFor(width, height);
  return (
    (width / geometry.subsample).ceil(),
    (height / geometry.subsample).ceil(),
  );
}

/// Mean of the packed 16-bit `b` plane.
double _meanB(Uint8List packed) {
  var sum = 0.0;
  var count = 0;
  for (var i = 0; i + 3 < packed.length; i += 4) {
    sum += ((packed[i + 1] << 8) | packed[i + 2]) / 65535.0;
    count++;
  }
  return sum / math.max(1, count);
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(StructureCache.clear);

  test('maps are produced for a decodable source', () async {
    final Uint8List png = _png(64, 64);
    final Uint8List? packed = await StructureCache.mapsFor(
      png,
      targetWidth: 64,
      targetHeight: 64,
    );
    expect(packed, isNotNull);
    final (int lw, int lh) = _grid(64, 64);
    expect(packed!.length, lw * lh * 4);
  });

  test('the packed maps decode to sane coefficients', () async {
    final Uint8List png = _png(64, 64);
    final Uint8List? packed = await StructureCache.mapsFor(
      png,
      targetWidth: 64,
      targetHeight: 64,
    );
    expect(packed, isNotNull);
    final Uint8List bytes = packed!;
    for (var i = 0; i + 3 < bytes.length; i += 4) {
      final double a = bytes[i] / 255.0;
      final double b =
          ((bytes[i + 1] << 8) | bytes[i + 2]) / 65535.0;
      expect(a, inInclusiveRange(0.0, 1.0));
      expect(b, inInclusiveRange(0.0, 1.0));
      expect(bytes[i + 3], 255);
    }
  });

  test('an undecodable source returns null', () async {
    final Uint8List garbage = Uint8List.fromList(
      List<int>.generate(12, (int i) => (i * 37 + 11) & 0xFF),
    );
    final Uint8List? packed = await StructureCache.mapsFor(
      garbage,
      targetWidth: 32,
      targetHeight: 32,
    );
    expect(packed, isNull);
  });

  test('the cache is keyed by content', () async {
    final Uint8List first = _png(64, 64);
    final Uint8List other = _png(64, 64, seed: 96);

    final Uint8List? a = await StructureCache.mapsFor(
      first,
      targetWidth: 64,
      targetHeight: 64,
    );
    final Uint8List? again = await StructureCache.mapsFor(
      first,
      targetWidth: 64,
      targetHeight: 64,
    );
    expect(a, isNotNull);
    expect(identical(a, again), isTrue);
    expect(StructureCache.length, 1);

    final Uint8List? b = await StructureCache.mapsFor(
      other,
      targetWidth: 64,
      targetHeight: 64,
    );
    expect(b, isNotNull);
    expect(identical(a, b), isFalse);
    expect(StructureCache.length, 2);
  });

  test('a square source is cropped to a centred square', () async {
    // 64x32, white only in the centred 32-pixel band: after the centre crop
    // the whole frame is white, so b is ~1 everywhere. A map of the WHOLE
    // frame (a stretched square decode — the mistake this guards against)
    // would average ~0.5.
    final image = img.Image(width: 64, height: 32, numChannels: 3);
    for (var y = 0; y < 32; y++) {
      for (var x = 0; x < 64; x++) {
        final int v = (x >= 16 && x < 48) ? 255 : 0;
        image.setPixelRgb(x, y, v, v, v);
      }
    }
    final Uint8List png = Uint8List.fromList(img.encodePng(image));
    final Uint8List? packed = await StructureCache.mapsFor(
      png,
      targetWidth: 32,
      targetHeight: 32,
      square: true,
    );
    expect(packed, isNotNull);
    // The centre crop keeps the requested 32-pixel short side.
    final (int lw, int lh) = _grid(32, 32);
    expect(lw, lh);
    expect(packed!.length, lw * lh * 4);
    expect(_meanB(packed), greaterThan(0.95));
  });

  test('a source smaller than the target keeps its own size', () async {
    final Uint8List png = _png(32, 32);
    final Uint8List? packed = await StructureCache.mapsFor(
      png,
      targetWidth: 256,
      targetHeight: 256,
    );
    expect(packed, isNotNull);
    // The engine does not upscale: the maps describe the 32x32 source, not
    // a 256x256 one — that is what keeps them aligned with the preview.
    final (int lw, int lh) = _grid(32, 32);
    expect(packed!.length, lw * lh * 4);
  });

  test('the neutral stub is a no-op', () async {
    final Uint8List stub = StructureCache.neutralStubBytes();
    expect(stub.length, 4);
    // R = a = 1.0, G:B = b = 0, A = 255.
    expect(stub[0], 255);
    expect(stub[1], 0);
    expect(stub[2], 0);
    expect(stub[3], 255);
    final ui.Image image = await _decode(stub);
    expect(image.width, 1);
    expect(image.height, 1);
    image.dispose();

    // And the decoded coefficients make the stage exactly neutral.
    final double a = stub[0] / 255.0;
    final double b = ((stub[1] << 8) | stub[2]) / 65535.0;
    expect(a, 1.0);
    expect(b, 0.0);
    expect(
      structureMultiplier(yraw: 0.37, q: a * 0.37 + b, amount: 1.0),
      1.0,
    );
    expect(
      structureMultiplier(yraw: 0.37, q: a * 0.37 + b, amount: -1.0),
      1.0,
    );
  });
}

/// Decodes the packed stub through the same entry point the preview uses.
Future<ui.Image> _decode(Uint8List rgba) {
  final completer = Completer<ui.Image>();
  ui.decodeImageFromPixels(
    rgba,
    1,
    1,
    ui.PixelFormat.rgba8888,
    completer.complete,
  );
  return completer.future;
}
