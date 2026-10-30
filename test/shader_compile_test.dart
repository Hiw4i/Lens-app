import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';

/// Compiles the runtime-effect shader.
///
/// The `.frag` file is shipped as a plain asset: Flutter's build does NOT
/// compile it, so a SkSL error (a typo in the structure stage, a bad sampler
/// declaration, a wrong type) would only surface at runtime, on a device,
/// as a black preview. The test engine DOES run the shader compiler, so this
/// test turns a runtime crash into a CI failure.
void main() {
  test('the preview shader compiles', () async {
    final ui.FragmentProgram program = await ui.FragmentProgram.fromAsset(
      'shaders/lens_filter.frag',
    );
    expect(program, isNotNull);
  });
}
