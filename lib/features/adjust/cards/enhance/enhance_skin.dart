/// Skin-tone detection, shared by the Enhance analysis and the apply stage.
///
/// The analysis needs it to keep faces OUT of the white-balance reference
/// (a warm face is the subject, not a warm lamp), and the apply stage
/// needs it to protect faces from the tone curve and the vibrance.
///
/// The mask is a cheap, well-known heuristic in display-referred RGB:
/// bright-enough red, present green, blue clearly below red (no sky or
/// grey) and red dominant over green.
library;

/// Smoothstep with the GLSL semantics: hermite interpolation of
/// `clamp((x - edge0) / (edge1 - edge0), 0, 1)`.
///
/// A degenerate range (`edge0 == edge1`) returns 0.0 — GLSL leaves it
/// undefined there, and the shader guards it explicitly.
double enhanceSmoothstep(double edge0, double edge1, double x) {
  if (edge0 == edge1) return 0.0;
  final double t = ((x - edge0) / (edge1 - edge0)).clamp(0.0, 1.0);
  return t * t * (3.0 - 2.0 * t);
}

/// Smooth skin probability in 0..1 (1 = confident skin).
///
/// Measured on the post-WB pixel (the detection sees neutral-anchored
/// colour): bright-enough red, present green, blue clearly below red (no
/// sky/grey), and red dominant over green.
double enhanceSkinMask(double r, double g, double b) {
  final double mR = enhanceSmoothstep(0.35, 0.5, r);
  final double mG = enhanceSmoothstep(0.20, 0.35, g);
  final double mBlue = 1.0 - enhanceSmoothstep(0.6 * r, 0.8 * r, b);
  final double mDom = enhanceSmoothstep(0.0, 0.08, r - g);
  return mR * mG * mBlue * mDom;
}
