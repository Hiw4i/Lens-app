import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/imaging/export/export_service.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';
import 'package:lens/features/selective/mask_raster.dart';

/// Solid gray helper: flat regions survive the JPEG q95 round-trip with
/// only a few LSBs of drift, so "unchanged" pixels assert with a tight
/// tolerance while graded pixels (selExp +2 clips 128 to 255) differ by
/// ~100+.
img.Image _solid(int size, int v) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

img.Image _decoded(Uint8List jpg) => img.decodeImage(jpg)!;

num _redAt(img.Image image, int x, int y) => image.getPixel(x, y).r;

void main() {
  const int size = 64;
  late Uint8List srcBytes;
  late Uint8List neutralBytes;
  late img.Image neutralImg;

  setUp(() {
    srcBytes = img.encodePng(_solid(size, 128));
    neutralBytes = applyLensGrade(srcBytes, const LensParams().toUniforms());
    neutralImg = _decoded(neutralBytes);
  });

  test('radial selective brightens the center but not the corner', () {
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(
        selMode: 1,
        selCx: 0.5,
        selCy: 0.5,
        selRadius: 0.15,
        selFeather: 0.0,
        selStrength: 1.0,
        selExp: 2.0,
      ).toUniforms(),
    );
    final img.Image graded = _decoded(out);
    // Center is fully inside the hard disc (w = 1): 128 * 4 clips to 255.
    expect(
      _redAt(graded, 32, 32) - _redAt(neutralImg, 32, 32),
      greaterThan(40),
    );
    // Corner is far outside (w = 0): identical math, JPEG noise only.
    expect(
      (_redAt(graded, 0, 0) - _redAt(neutralImg, 0, 0)).abs(),
      lessThanOrEqualTo(8),
    );
  });

  test('invert flips which end of the image is graded', () {
    List<double> uniforms({required int invert}) =>
        const LensParams(selMode: 1)
            .copyWith(
              selCx: 0.5,
              selCy: 0.5,
              selRadius: 0.25,
              selFeather: 0.0,
              selInvert: invert,
              selStrength: 1.0,
              selExp: 1.5,
            )
            .toUniforms();
    final img.Image normal = _decoded(
      applyLensGrade(srcBytes, uniforms(invert: 0)),
    );
    final img.Image inv = _decoded(
      applyLensGrade(srcBytes, uniforms(invert: 1)),
    );
    // Inverted: center untouched, corner graded ...
    expect(
      (_redAt(inv, 32, 32) - _redAt(neutralImg, 32, 32)).abs(),
      lessThanOrEqualTo(8),
    );
    expect(_redAt(inv, 0, 0) - _redAt(neutralImg, 0, 0), greaterThan(40));
    // ... and symmetric: inverted-corner grade == normal-center grade
    // (both are full-weight selK = 1 mixes of the same local grade).
    expect(
      (_redAt(inv, 0, 0) - _redAt(normal, 32, 32)).abs(),
      lessThanOrEqualTo(12),
    );
  });

  test('strength 0 is byte-identical to neutral', () {
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(
        selMode: 1,
        selStrength: 0.0,
        selExp: 2.0,
        selCon: 1.0,
        selSat: 1.0,
      ).toUniforms(),
    );
    expect(out, equals(neutralBytes));
  });

  test('mode 0 with garbage selective slots is byte-identical to neutral', () {
    final List<double> garbage = List<double>.of(
      const LensParams().toUniforms(),
    );
    // Keep [19] (mode) at 0, trash everything else in the selective block —
    // including a parked invert = 1 and full strength: off must stay off.
    garbage[20] = -2.0; // selCx
    garbage[21] = 5.0; // selCy
    garbage[22] = -3.0; // selRadius
    garbage[23] = 99.0; // selFeather
    garbage[24] = 720.0; // selAngle
    garbage[25] = -2.0; // selWidth
    garbage[26] = -5.0; // selAspect
    garbage[27] = 1.0; // selInvert (valid range, parked while off)
    garbage[28] = 1.0; // selStrength
    garbage[29] = 3.0; // selExp
    garbage[30] = 5.0; // selCon
    garbage[31] = -5.0; // selSat
    expect(applyLensGrade(srcBytes, garbage), equals(neutralBytes));
  });

  test('brush raster grades only inside the dab', () {
    const strokes = [
      // Single hard dab at the center: only nearby texels carry weight.
      // ignore: avoid_redundant_argument_values (documents the kernel edge)
      BrushStroke(points: [(0.5, 0.5)], radius: 0.08, feather: 0.0),
    ];
    final Float32List mask = rasterizeBrushMask(strokes, size);
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(selMode: 3, selStrength: 1.0, selExp: 2.0).toUniforms(),
      0,
      (mask: mask, size: size),
    );
    final img.Image graded = _decoded(out);
    expect(
      _redAt(graded, 32, 32) - _redAt(neutralImg, 32, 32),
      greaterThan(40),
    );
    expect(
      (_redAt(graded, 0, 0) - _redAt(neutralImg, 0, 0)).abs(),
      lessThanOrEqualTo(8),
    );
  });

  test('legacy 19-slot vectors still run selective-free', () {
    final List<double> full = const LensParams(exposure: 1.0).toUniforms();
    expect(full.length, equals(56));
    final List<double> legacy19 = full.sublist(0, 19);
    // Same enhance/exposure payload, no selective block: identical ops,
    // identical JPEG bytes to the selective-neutral 44-slot form.
    expect(
      applyLensGrade(srcBytes, legacy19),
      equals(applyLensGrade(srcBytes, full)),
    );
  });

  test('brush mode without a raster is neutral (not the white stub)', () {
    // Documents the deliberate CPU/shader divergence: the preview frag
    // samples a 1x1 white stub (full-frame grade) when no raster is bound,
    // while the CPU treats a missing raster as "nothing painted".
    final Uint8List out = applyLensGrade(
      srcBytes,
      const LensParams(selMode: 3, selStrength: 1.0, selExp: 2.0).toUniforms(),
    );
    expect(out, equals(neutralBytes));
  });

  test('brush stroke codec round-trips for the isolate boundary', () {
    const strokes = [
      BrushStroke(points: [(0.1, 0.2), (0.3, 0.4)], radius: 0.1),
      BrushStroke(points: [(0.9, 0.9)], radius: 0.05, feather: 0.0),
    ];
    final List<double> flat = encodeBrushStrokes(strokes);
    // A handful of doubles cross the boundary — not the 256KB raster.
    expect(flat.length, lessThan(20));
    expect(decodeBrushStrokes(flat), equals(strokes));
    expect(decodeBrushStrokes(const []), isEmpty);
    expect(decodeBrushStrokes(encodeBrushStrokes(const [])), isEmpty);
  });

  test('ExportService.export rasterizes brush strokes in-isolate', () async {
    const strokes = [
      BrushStroke(points: [(0.5, 0.5)], radius: 0.08, feather: 0.0),
    ];
    final Uint8List out = await ExportService.export(
      srcBytes: srcBytes,
      params: const LensParams(selMode: 3, selStrength: 1.0, selExp: 2.0),
      brushStrokesFlat: encodeBrushStrokes(strokes),
    );
    final img.Image graded = _decoded(out);
    expect(
      _redAt(graded, 32, 32) - _redAt(neutralImg, 32, 32),
      greaterThan(40),
    );
    expect(
      (_redAt(graded, 0, 0) - _redAt(neutralImg, 0, 0)).abs(),
      lessThanOrEqualTo(8),
    );
  });
}
