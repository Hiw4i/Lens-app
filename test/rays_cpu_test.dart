import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;

import 'package:lens/features/imaging/export/export_service.dart';
import 'package:lens/features/imaging/pipeline/lens_cpu.dart';
import 'package:lens/features/imaging/pipeline/lens_pipeline.dart';

img.Image _solid(int size, int v) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

/// Black frame with a white disc (the synthetic "sun") at ([cx], [cy]).
img.Image _spot(int size, int cx, int cy, int r) {
  final image = img.Image(width: size, height: size, numChannels: 3);
  for (int y = 0; y < size; y++) {
    for (int x = 0; x < size; x++) {
      final double dx = (x - cx).toDouble();
      final double dy = (y - cy).toDouble();
      final int v = math.sqrt(dx * dx + dy * dy) <= r ? 255 : 0;
      image.setPixelRgb(x, y, v, v, v);
    }
  }
  return image;
}

img.Image _decoded(Uint8List jpg) => img.decodeImage(jpg)!;

num _redAt(img.Image image, int x, int y) => image.getPixel(x, y).r;

double _meanLuma(img.Image image) {
  double acc = 0;
  for (int y = 0; y < image.height; y++) {
    for (int x = 0; x < image.width; x++) {
      final img.Pixel p = image.getPixel(x, y);
      acc += 0.299 * p.r + 0.587 * p.g + 0.114 * p.b;
    }
  }
  return acc / (image.width * image.height);
}

void main() {
  test('white-spot source gathers light along the march', () {
    // Synthetic Tyndall scene: white "sun" disc on black, source parked
    // at the disc center. Pixels whose march toward the source crosses
    // the disc must screen-brighten vs the rays-neutral grade.
    const int size = 64;
    const int cx = 32;
    const int cy = 13; // uv ~(0.5, 0.2): the default sun spot
    final Uint8List srcBytes = img.encodePng(_spot(size, cx, cy, 8));
    const rays = LensParams(
      rayOn: 1,
      rayX: 0.5,
      rayY: 0.2,
      rayIntensity: 1.0,
      rayLength: 0.6,
      rayWarmth: 0.7,
      rayDensity: 0.5,
    );
    final img.Image neutral = _decoded(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
    );
    final img.Image out = _decoded(applyLensGrade(srcBytes, rays.toUniforms()));
    // 8 compass points at radius 12 around the source: all outside the
    // disc (r8), all with a march crossing it — but at different polar
    // angles, i.e. different streak values. The streak field can dip near
    // zero at any single angle (fbm null), so the robust signal is the
    // MAX lift over angles, not one pinned pixel.
    const List<(int, int)> probes = <(int, int)>[
      (32, 1),
      (32, 25),
      (20, 13),
      (44, 13),
      (24, 5),
      (40, 5),
      (24, 21),
      (40, 21),
    ];
    double maxLift = 0;
    for (final (int x, int y) in probes) {
      final double lift = (_redAt(out, x, y) - _redAt(neutral, x, y))
          .toDouble();
      if (lift > maxLift) maxLift = lift;
    }
    // Sanity: neutral is ~black at every probe (the lift is rays-caused,
    // not JPEG ringing off the disc edge 4px+ away).
    for (final (int x, int y) in probes) {
      expect(_redAt(neutral, x, y), lessThanOrEqualTo(10));
    }
    expect(maxLift, greaterThan(8));
  });

  test('intensity 0 is byte-identical to neutral', () {
    final Uint8List srcBytes = img.encodePng(_solid(64, 128));
    final Uint8List neutral = applyLensGrade(
      srcBytes,
      const LensParams().toUniforms(),
    );
    // Everything armed except the strength: the stage must skip before
    // any low-res work (and applyRaysPixel early-outs anyway).
    const armed = LensParams(
      rayOn: 1,
      rayX: 0.5,
      rayY: 0.2,
      rayIntensity: 0.0,
      rayLength: 0.6,
      rayWarmth: 1.0,
      rayDensity: 1.0,
    );
    expect(applyLensGrade(srcBytes, armed.toUniforms()), equals(neutral));
  });

  test('gate off with garbage rays slots is byte-identical to neutral', () {
    final Uint8List srcBytes = img.encodePng(_solid(64, 128));
    final Uint8List neutral = applyLensGrade(
      srcBytes,
      const LensParams().toUniforms(),
    );
    final List<double> garbage = List<double>.of(
      const LensParams().toUniforms(),
    );
    // Keep [37] (rayOn) at 0, trash the rest — including unclamped
    // off-frame source coords and out-of-range strength/length/warmth/
    // density: off must stay off before any of it is read.
    garbage[38] = 5.0; // rayX (unclamped by design)
    garbage[39] = -3.0; // rayY (unclamped by design)
    garbage[40] = 99.0; // rayIntensity
    garbage[41] = -7.0; // rayLength
    garbage[42] = 42.0; // rayWarmth
    garbage[43] = -11.0; // rayDensity
    expect(applyLensGrade(srcBytes, garbage), equals(neutral));
  });

  test('length 0 degrades to a local point glow', () {
    // Solid mid-gray: the glow term is decay(dist/diag) * streak, so the
    // ring near the source must lift strongly while the far corner —
    // ~0.7 diagonals out, decay ~0.08 — barely moves.
    const int size = 96;
    final Uint8List srcBytes = img.encodePng(_solid(size, 128));
    const rays = LensParams(
      rayOn: 1,
      rayX: 0.5,
      rayY: 0.2,
      rayIntensity: 1.0,
      rayLength: 0.0,
      rayWarmth: 0.7,
      rayDensity: 0.5,
    );
    final img.Image neutral = _decoded(
      applyLensGrade(srcBytes, const LensParams().toUniforms()),
    );
    final img.Image out = _decoded(applyLensGrade(srcBytes, rays.toUniforms()));
    // 16 samples on the r=8 ring around the source projection (48, 19):
    // fixed decay (~0.9), angles sweep the streak field — the MEAN over
    // the ring is streak-robust, unlike any single pinned pixel.
    double ringLift = 0;
    for (int k = 0; k < 16; k++) {
      final double a = k * math.pi / 8;
      final int x = (48 + 8 * math.cos(a)).round().clamp(0, size - 1);
      final int y = (19 + 8 * math.sin(a)).round().clamp(0, size - 1);
      ringLift += (_redAt(out, x, y) - _redAt(neutral, x, y)).toDouble();
    }
    ringLift /= 16;
    expect(ringLift, greaterThan(15));
    // Far corner (0, 95): the glow must stay local.
    final double farLift = (_redAt(out, 0, 95) - _redAt(neutral, 0, 95))
        .toDouble();
    expect(farLift, lessThan(8));
  });

  test('legacy 37-slot vectors run rays-free like neutral 44', () {
    final Uint8List srcBytes = img.encodePng(_solid(64, 128));
    final Uint8List neutral = applyLensGrade(
      srcBytes,
      const LensParams().toUniforms(),
    );
    final List<double> legacy37 = const LensParams().toUniforms().sublist(
      0,
      37,
    );
    expect(legacy37.length, equals(37));
    expect(applyLensGrade(srcBytes, legacy37), equals(neutral));
    // A selective-armed 37-slot vector matches the same 44-slot vector
    // with a rays-neutral tail (the tail must be a no-op, not a shift).
    const sel = LensParams(selMode: 1, selStrength: 1.0, selExp: 1.0);
    final List<double> selFull = sel.toUniforms();
    expect(
      applyLensGrade(srcBytes, selFull.sublist(0, 37)),
      equals(applyLensGrade(srcBytes, selFull)),
    );
  });

  test('rays sit before the master mix (intensity 0 stays clean)', () {
    // Armed shafts with the master mix at 0 must equal the neutral
    // mix-0 grade byte-for-byte: rays fade with the rest of the grade.
    final Uint8List srcBytes = img.encodePng(_spot(64, 32, 13, 8));
    const rays = LensParams(
      rayOn: 1,
      rayX: 0.5,
      rayY: 0.2,
      rayIntensity: 1.0,
      rayLength: 0.6,
      intensity: 0.0,
    );
    expect(
      applyLensGrade(srcBytes, rays.toUniforms()),
      equals(
        applyLensGrade(srcBytes, const LensParams(intensity: 0.0).toUniforms()),
      ),
    );
  });

  test('ExportService.export carries armed rays end to end', () async {
    final Uint8List srcBytes = img.encodePng(_solid(64, 128));
    const rays = LensParams(
      rayOn: 1,
      rayX: 0.5,
      rayY: 0.5,
      rayIntensity: 1.0,
      rayLength: 0.6,
      rayWarmth: 0.7,
      rayDensity: 0.0,
    );
    final Uint8List neutralBytes = await ExportService.export(
      srcBytes: srcBytes,
      params: const LensParams(),
    );
    final Uint8List outBytes = await ExportService.export(
      srcBytes: srcBytes,
      params: rays,
    );
    final img.Image neutral = _decoded(neutralBytes);
    final img.Image out = _decoded(outBytes);
    expect(out.width, equals(64));
    expect(out.height, equals(64));
    // Full-frame mid-gray: every march tap sees light ~0.5, so the mean
    // must lift (and the isolate round-trip must not throw).
    expect(_meanLuma(out), greaterThan(_meanLuma(neutral) + 5));
  });
}
