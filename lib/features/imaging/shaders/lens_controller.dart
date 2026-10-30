import 'dart:ui';

import 'package:flutter/foundation.dart';

import 'package:lens/shared/diagnostics/app_logger.dart';

/// Asset key of the Lens identity filter. Single source of truth shared by
/// the warm-up in [LensShaderController.precache] and the preview painter.
const String kLensFilterAsset = 'shaders/lens_filter.frag';

FragmentProgram? _cachedProgram;
Future<FragmentProgram?>? _pendingLoad;

/// Warms the compiled Lens filter program. Never throws: a failure leaves
/// [LensShaderController.program] null and the UI falls back to CPU
/// rendering ([Image.memory] / `paintImage`).
Future<FragmentProgram?> precacheLensFilter() {
  final cached = _cachedProgram;
  if (cached != null) return Future.value(cached);
  final pending = _pendingLoad;
  if (pending != null) return pending;
  final load = _loadLensFilter();
  _pendingLoad = load;
  return load;
}

Future<FragmentProgram?> _loadLensFilter() async {
  try {
    final program = await FragmentProgram.fromAsset(kLensFilterAsset);
    _cachedProgram = program;
    LensShaderController.programVN.value = program;
    return program;
  } catch (error, stackTrace) {
    // One-time, invisible degradation to CPU rendering: worth exactly one
    // log line, because nothing else on screen explains the lost quality.
    AppLogger.w(
      'Lens shader failed to compile; previews degrade to CPU fallback',
      context: 'lens_controller',
      error: error,
      stackTrace: stackTrace,
    );
    return null;
  }
}

/// Owner of the compiled Lens filter [FragmentProgram].
///
/// Call [precache] once from `main()` before `runApp`. Every consumer reads
/// [program] and renders on CPU when it is null (shader missing, driver
/// refused to compile, first frame before warm-up finished).
class LensShaderController {
  const LensShaderController._();

  /// Compiles (or reuses) the Lens filter program. Never throws.
  static Future<void> precache() async {
    try {
      await precacheLensFilter();
    } catch (_) {
      // Fallback stays active: program remains null.
    }
  }

  /// Compiled program, or null when it failed / has not loaded yet.
  static FragmentProgram? get program => _cachedProgram;

  /// Notifies when the compiled program lands (stays null when compilation
  /// failed). Previews that started on the CPU fallback subscribe to this
  /// and rebuild into the GPU path automatically once warm-up finishes —
  /// `main()` precache included, which flows through the same setter.
  static final ValueNotifier<FragmentProgram?> programVN =
      ValueNotifier<FragmentProgram?>(null);
}
