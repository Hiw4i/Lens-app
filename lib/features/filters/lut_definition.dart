import 'dart:math' as math;
import 'dart:typed_data';

/// Procedural 3D-LUT core of the Lens filter stage (Task 2.3).
///
/// Pure-Dart on purpose: this file imports `dart:*` only (no Flutter, no
/// Riverpod), so [LutTables.generateLut] and [LutTables.sampleLut] are safe
/// to run inside an isolate (CPU export path, Task 2.5).
///
/// Anti-Hypic rule: NO baked PNG LUT atlases in `assets/`. Every filter is
/// a closed-form grade function ([LutTables.gradePixel]); both consumers
/// sample the SAME function, only at different lattice densities:
/// * [LutTables.generateLut] — coarse N=16 lattice (16^3 = 4096 RGB points,
///   4096*3 floats = 49KB per filter) for CPU trilinear sampling.
/// * `LutManager.lutAtlasImage` (Flutter side) — fine N=64 lattice packed
///   into a 512x512 atlas (64^3 = 262144 texels) for the GPU sampler.
///
/// The fixed [LensFilterId] order (none first, then 8 looks) is the index
/// contract: `LensParams.filterId` stores `LensFilterId.index` (0..8).
enum LensFilterId { none, bw, cinematic, golden, noir, fade, vivid, warm, cool }

/// Procedural LUT tables + sampling. All static; instantiated never.
abstract final class LutTables {
  /// Coarse lattice dimension. N=16 is the quality/memory compromise:
  /// 4096 points * 3 floats * 4 bytes = 49KB per filter table.
  static const int size = 16;

  /// Number of lattice points per table ([size] Cubed).
  static const int count = size * size * size; // 4096

  /// Floats per table ([count] * 3).
  static const int floatsPerLut = count * 3; // 12288

  /// Generates the full 3D LUT for [id] in R-fastest order:
  /// `index = ((b * size + g) * size + r) * 3`.
  ///
  /// Lattice coordinates are texel centers: `r = ri / (size - 1)` etc.,
  /// so the corners (0,0,0) and (1,1,1) are exact. [LensFilterId.none]
  /// yields the identity table.
  static Float32List generateLut(LensFilterId id) {
    final Float32List out = Float32List(floatsPerLut);
    var i = 0;
    for (var b = 0; b < size; b++) {
      for (var g = 0; g < size; g++) {
        for (var r = 0; r < size; r++) {
          final (double rr, double gg, double bb) = gradePixel(
            id,
            r / (size - 1),
            g / (size - 1),
            b / (size - 1),
          );
          out[i++] = rr;
          out[i++] = gg;
          out[i++] = bb;
        }
      }
    }
    return out;
  }

  /// Trilinear sample of a [generateLut] table at normalized [r],[g],[b].
  ///
  /// CPU counterpart of the shader's `applyLut` (Task 2.5 wires it into
  /// export; until then this helper exists for tests/callers). Inputs are
  /// clamped to 0..1; lattice edges replicate (no wrap).
  static (double r, double g, double b) sampleLut(
    Float32List lut,
    double r,
    double g,
    double b,
  ) {
    final Float64List out = Float64List(3);
    sampleLutInto(lut, r, g, b, out);
    return (out[0], out[1], out[2]);
  }

  /// Allocation-free trilinear sample: writes R,G,B into [out]
  /// (length >= 3). The export hot loop calls this instead of [sampleLut]
  /// — same arithmetic in the same order, minus the ~15 heap records per
  /// pixel the record-returning chain allocated (~180M at a 12MP export).
  static void sampleLutInto(
    Float32List lut,
    double r,
    double g,
    double b,
    Float64List out,
  ) {
    assert(
      lut.length == floatsPerLut,
      'LUT must be LutTables.generateLut output '
      '($floatsPerLut floats), got ${lut.length}.',
    );
    final double x = _clamp01(r) * (size - 1);
    final double y = _clamp01(g) * (size - 1);
    final double z = _clamp01(b) * (size - 1);
    final int x0 = x.floor();
    final int y0 = y.floor();
    final int z0 = z.floor();
    final int x1 = math.min(x0 + 1, size - 1);
    final int y1 = math.min(y0 + 1, size - 1);
    final int z1 = math.min(z0 + 1, size - 1);
    final double fx = x - x0;
    final double fy = y - y0;
    final double fz = z - z0;

    // R, then G, then B axis — per channel, in the exact mix order of the
    // record-returning version: `a + (b - a) * t`, lerp along R, then G,
    // then B.
    for (int c = 0; c < 3; c++) {
      final double c000 = lut[((z0 * size + y0) * size + x0) * 3 + c];
      final double c100 = lut[((z0 * size + y0) * size + x1) * 3 + c];
      final double c010 = lut[((z0 * size + y1) * size + x0) * 3 + c];
      final double c110 = lut[((z0 * size + y1) * size + x1) * 3 + c];
      final double c001 = lut[((z1 * size + y0) * size + x0) * 3 + c];
      final double c101 = lut[((z1 * size + y0) * size + x1) * 3 + c];
      final double c011 = lut[((z1 * size + y1) * size + x0) * 3 + c];
      final double c111 = lut[((z1 * size + y1) * size + x1) * 3 + c];

      final double x00 = c000 + (c100 - c000) * fx;
      final double x10 = c010 + (c110 - c010) * fx;
      final double x01 = c001 + (c101 - c001) * fx;
      final double x11 = c011 + (c111 - c011) * fx;
      final double y0m = x00 + (x10 - x00) * fy;
      final double y1m = x01 + (x11 - x01) * fy;
      out[c] = y0m + (y1m - y0m) * fz;
    }
  }

  /// The single procedural grade function behind every filter.
  ///
  /// Inputs/outputs are display-referred 0..1 RGB. This exact function is
  /// evaluated per lattice point by [generateLut] (N=16) and per texel by
  /// `LutManager` (N=64 atlas), so CPU and GPU looks match by construction
  /// (modulo 8-bit atlas quantization + trilinear vs bilinear-between-
  /// slices interpolation).
  static (double r, double g, double b) gradePixel(
    LensFilterId id,
    double r,
    double g,
    double b,
  ) {
    switch (id) {
      case LensFilterId.none:
        return (r, g, b);
      case LensFilterId.bw:
        return _bw(r, g, b);
      case LensFilterId.cinematic:
        return _cinematic(r, g, b);
      case LensFilterId.golden:
        return _golden(r, g, b);
      case LensFilterId.noir:
        return _noir(r, g, b);
      case LensFilterId.fade:
        return _fade(r, g, b);
      case LensFilterId.vivid:
        return _vivid(r, g, b);
      case LensFilterId.warm:
        return _warm(r, g, b);
      case LensFilterId.cool:
        return _cool(r, g, b);
    }
  }

  // ------------------------------------------------------------------
  // Looks. Each documents its formula; all outputs are clamped to 0..1.
  // ------------------------------------------------------------------

  /// bw: rec.709 luma + S-curve contrast 1.15 + gentle black lift.
  /// `v = (l-0.5)*1.15+0.5; v += 0.02*(1-v)` — the lift raises shadows
  /// while pinning white, so blacks sit at ~0.02 instead of pure 0.
  static (double, double, double) _bw(double r, double g, double b) {
    final double l = _luma(r, g, b);
    double v = (l - 0.5) * 1.15 + 0.5;
    v += 0.02 * (1.0 - v);
    v = _clamp01(v);
    return (v, v, v);
  }

  /// cinematic (teal-orange):
  /// shadows (luma<0.5 ramp) shift to teal `r-=0.04*m, b+=0.08*m`;
  /// highlights (luma>0.5 ramp) shift to orange `r+=0.06*h, g+=0.02*h`;
  /// then saturation 1.1 (luma mix), then contrast 1.08 around 0.5.
  /// Masks are smoothstep ramps, so the split-toning has no hard seam.
  static (double, double, double) _cinematic(double r, double g, double b) {
    final double l = _luma(r, g, b);
    final double sh = 1.0 - _smoothstep(0.0, 0.5, l);
    r -= 0.04 * sh;
    b += 0.08 * sh;
    final double hi = _smoothstep(0.5, 1.0, l);
    r += 0.06 * hi;
    g += 0.02 * hi;
    (r, g, b) = _saturate(r, g, b, 1.1);
    r = _contrast(r, 1.08);
    g = _contrast(g, 1.08);
    b = _contrast(b, 1.08);
    return (_clamp01(r), _clamp01(g), _clamp01(b));
  }

  /// golden (warm autumn):
  /// foliage mask = green-dominance `clamp((g-max(r,b))*3)` gated by a
  /// mid-luma band `smoothstep(0.15,0.35,l)*(1-smoothstep(0.6,0.85,l))`
  /// (greens live in the mids, not in deep shadows or sky highlights);
  /// foliage gets `r+=0.10*fol` (amber shift) plus a local saturation
  /// boost to 1.25 blended by the same mask; everything gets a global
  /// gold tint `r+=0.05, g+=0.02`.
  static (double, double, double) _golden(double r, double g, double b) {
    final double l = _luma(r, g, b);
    final double greenDom = _clamp01((g - math.max(r, b)) * 3.0);
    final double mid =
        _smoothstep(0.15, 0.35, l) * (1.0 - _smoothstep(0.6, 0.85, l));
    final double fol = greenDom * mid;
    r += 0.10 * fol;
    r += 0.05;
    g += 0.02;
    final (double sr, double sg, double sb) = _saturate(r, g, b, 1.25);
    r += (sr - r) * fol;
    g += (sg - g) * fol;
    b += (sb - b) * fol;
    return (_clamp01(r), _clamp01(g), _clamp01(b));
  }

  /// noir (hard B&W): luma + contrast 1.35 + crushed blacks.
  /// Crush = `v *= 0.5+0.5*smoothstep(0,0.15,l)`: deep shadows are halved
  /// toward black while tones above 0.15 pass untouched.
  static (double, double, double) _noir(double r, double g, double b) {
    final double l = _luma(r, g, b);
    double v = (l - 0.5) * 1.35 + 0.5;
    v *= 0.5 + 0.5 * _smoothstep(0.0, 0.15, l);
    v = _clamp01(v);
    return (v, v, v);
  }

  /// fade (matte film): lifted blacks `+0.08` fading out by luma 0.6,
  /// desaturation to 0.85, highlight pull `-0.05` above luma 0.6.
  /// Order: lift -> desat -> highlight pull, single luma measure.
  static (double, double, double) _fade(double r, double g, double b) {
    final double l = _luma(r, g, b);
    final double lift = 0.08 * (1.0 - _smoothstep(0.0, 0.6, l));
    r += lift;
    g += lift;
    b += lift;
    (r, g, b) = _saturate(r, g, b, 0.85);
    final double hi = _smoothstep(0.6, 1.0, l);
    r -= 0.05 * hi;
    g -= 0.05 * hi;
    b -= 0.05 * hi;
    return (_clamp01(r), _clamp01(g), _clamp01(b));
  }

  /// vivid: saturation 1.3 + contrast 1.12 + vibrance.
  /// Vibrance = extra saturation for already-muted colors:
  /// `s = 1.3 + 0.35*(1-sat0)`, where `sat0 = clamp((max-min)/max)`
  /// is the pixel's own saturation (0 = gray, 1 = pure). Grays get the
  /// full boost, pure hues only the base 1.3 — skin stays believable.
  static (double, double, double) _vivid(double r, double g, double b) {
    final double mx = math.max(r, math.max(g, b));
    final double mn = math.min(r, math.min(g, b));
    final double sat0 = mx > 1e-3 ? _clamp01((mx - mn) / mx) : 0.0;
    final double s = 1.3 + 0.35 * (1.0 - sat0);
    (r, g, b) = _saturate(r, g, b, s);
    r = _contrast(r, 1.12);
    g = _contrast(g, 1.12);
    b = _contrast(b, 1.12);
    return (_clamp01(r), _clamp01(g), _clamp01(b));
  }

  /// warm: +0.35 white-balance temp +0.1 tint, reusing the shader's WB
  /// vectors (`vec3(0.10,-0.02,-0.12)` temp / `vec3(0.04,-0.06,0.04)`
  /// tint): `0.35*(0.10,-0.02,-0.12) = (+0.035,-0.007,-0.042)` plus
  /// `0.1*(0.04,-0.06,0.04) = (+0.004,-0.006,+0.004)`.
  static (double, double, double) _warm(double r, double g, double b) {
    r += 0.035 + 0.004;
    g += -0.007 + -0.006;
    b += -0.042 + 0.004;
    return (_clamp01(r), _clamp01(g), _clamp01(b));
  }

  /// cool: exact inverse of [warm] (-0.35 temp, -0.1 tint).
  static (double, double, double) _cool(double r, double g, double b) {
    r += -0.035 + -0.004;
    g += 0.007 + 0.006;
    b += 0.042 + -0.004;
    return (_clamp01(r), _clamp01(g), _clamp01(b));
  }

  // ----------------------------- helpers -----------------------------

  static double _clamp01(double v) => v < 0.0 ? 0.0 : (v > 1.0 ? 1.0 : v);

  /// GLSL `smoothstep` semantics (hermite of the clamped segment).
  static double _smoothstep(double e0, double e1, double x) {
    final double t = ((x - e0) / (e1 - e0)).clamp(0.0, 1.0);
    return t * t * (3.0 - 2.0 * t);
  }

  /// Rec.709 luma, same weights as the shader/CPU grade.
  static double _luma(double r, double g, double b) =>
      0.299 * r + 0.587 * g + 0.114 * b;

  static double _contrast(double c, double k) => (c - 0.5) * k + 0.5;

  /// Saturation via luma mix (`s=1` identity), mirroring the shader.
  static (double, double, double) _saturate(
    double r,
    double g,
    double b,
    double s,
  ) {
    final double l = _luma(r, g, b);
    return (l + (r - l) * s, l + (g - l) * s, l + (b - l) * s);
  }
}
