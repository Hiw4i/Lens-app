import 'dart:async';
import 'dart:ui' show PlatformDispatcher;

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import 'app/router.dart';
import 'features/filters/lut_manager.dart';
import 'features/imaging/cache/preview_cache.dart';
import 'features/imaging/cache/structure_cache.dart';
import 'features/imaging/shaders/lens_controller.dart';
import 'shared/data/preferences/shared_preferences_provider.dart';
import 'shared/diagnostics/app_logger.dart';
import 'shared/haptics/haptics_provider.dart';
import 'shared/haptics/haptics_scope.dart';
import 'shared/motion/policy/ui_performance_policy.dart';
import 'shared/motion/policy/ui_performance_provider.dart';
import 'shared/motion/policy/ui_performance_scope.dart';
import 'shared/motion/tokens/app_durations.dart';
import 'shared/theme/app_tokens.dart';
import 'shared/theme/theme_colors.dart';
import 'shared/theme/theme_provider.dart';

final appNavigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  _installGlobalErrorHandlers();
  final container = ProviderContainer();
  // Prefs are load-bearing (theme, motion, haptics all read them); a
  // platform-channel failure here must degrade to a diagnosable screen,
  // not a permanent white screen with no diagnostics.
  if (!await _warmPreferences(container)) return;
  // The gallery must appear even if a GPU driver takes time to compile.
  // ShaderPreview keeps the photograph visible until the program is ready.
  WidgetsBinding.instance.addPostFrameCallback((_) {
    unawaited(LensShaderController.precache());
    // Fill the LUT cache off the critical path: the filter strip and the
    // first tap on a look then never wait for a 262k-texel atlas build.
    unawaited(LutManager.prewarm());
  });
  runApp(
    UncontrolledProviderScope(
      container: container,
      child: const _RootScopes(child: LensApp()),
    ),
  );
}

/// Routes framework and unhandled-async errors into [AppLogger] so the
/// silent-catch layers below (caches, platform bridges) are observable.
/// Framework errors are still presented via [FlutterError.presentError];
/// dispatch errors are reported as handled so a stray failure in a
/// fire-and-forget callback cannot take the isolate down.
void _installGlobalErrorHandlers() {
  FlutterError.onError = (FlutterErrorDetails details) {
    AppLogger.e(
      'Flutter framework error',
      context: 'flutter',
      error: details.exception,
      stackTrace: details.stack,
    );
    FlutterError.presentError(details);
  };
  PlatformDispatcher.instance.onError = (Object error, StackTrace stack) {
    AppLogger.e(
      'Unhandled platform dispatch error',
      context: 'platform',
      error: error,
      stackTrace: stack,
    );
    return true;
  };
}

/// Pre-warms the preferences cache before the app depends on it.
///
/// Returns false when preferences cannot be read at all (fatal: every
/// provider reading [sharedPreferencesProvider] would throw from build);
/// the failure screen takes over and the container is disposed.
Future<bool> _warmPreferences(ProviderContainer container) async {
  try {
    await container.read(sharedPreferencesProvider.future);
    return true;
  } catch (error, stackTrace) {
    AppLogger.e(
      'SharedPreferences failed to initialise',
      context: 'bootstrap',
      error: error,
      stackTrace: stackTrace,
    );
    container.dispose();
    runApp(_BootstrapFailureApp(error: error));
    return false;
  }
}

/// Last-resort screen when preferences cannot be loaded. Deliberately
/// self-contained (no providers, no theme system): it must render even
/// when everything else is broken.
class _BootstrapFailureApp extends StatelessWidget {
  const _BootstrapFailureApp({required this.error});

  final Object error;

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      debugShowCheckedModeBanner: false,
      home: Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'Lens could not start.\n\n'
              'Application settings failed to load. Restart the app to try '
              'again.\n\nDetails: $error',
              style: const TextStyle(
                fontFamily: 'Inter',
                fontSize: 14,
                height: 1.4,
                color: Colors.white,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

/// Wires Riverpod motion/haptics settings into inherited scopes.
///
/// Order: UncontrolledProviderScope > UiPerformanceScope > HapticsScope
/// > LensApp. Falls back to cinematic + haptics on while prefs load.
class _RootScopes extends ConsumerStatefulWidget {
  const _RootScopes({required this.child});

  final Widget child;

  @override
  ConsumerState<_RootScopes> createState() => _RootScopesState();
}

class _RootScopesState extends ConsumerState<_RootScopes>
    with WidgetsBindingObserver {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didHaveMemoryPressure() {
    // Drop the recomputable raster caches. The LUT atlas is deliberately
    // kept: it is bound into live fragment shaders, and clearing it would
    // break every on-screen preview until a full reload.
    PreviewCache.clear();
    StructureCache.clear();
  }

  @override
  Widget build(BuildContext context) {
    final profile = ref.watch(uiPerformanceProfileProvider);
    final speed = ref.watch(animationSpeedProvider);
    final hapticsOn = ref.watch(hapticsEnabledProvider);
    final policy = UiPerformancePolicy.resolve(
      profile,
      disableAnimations:
          PlatformDispatcher.instance.accessibilityFeatures.disableAnimations,
      motionScale: speed.scale,
    );
    return UiPerformanceScope(
      policy: policy,
      child: HapticsScope(enabled: hapticsOn, child: widget.child),
    );
  }
}

class LensApp extends ConsumerWidget {
  const LensApp({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final paletteIndex = ref.watch(paletteProvider);
    final brightnessSetting = ref.watch(themeBrightnessProvider);
    final policy = context.uiPerformance;

    ThemeData buildTheme(Brightness brightness) {
      final colors = resolveColors(paletteIndex, brightness);
      return ThemeData(
        useMaterial3: true,
        colorScheme: ColorScheme.fromSeed(
          seedColor: colors.accent,
          brightness: brightness,
        ),
        fontFamily: 'SpaceGrotesk',
        scaffoldBackgroundColor: colors.background,
        appBarTheme: AppBarTheme(foregroundColor: colors.primary),
        // Material's default M3 snackbar uses inverseSurface, which reads as
        // a pale block over the dark editor. Keep it on the app surface so it
        // belongs to the same visual system.
        snackBarTheme: SnackBarThemeData(
          backgroundColor: colors.surface,
          contentTextStyle: TextStyle(
            fontFamily: 'Inter',
            fontSize: 14,
            height: 1.3,
            color: colors.primary,
          ),
          actionTextColor: colors.accent,
          behavior: SnackBarBehavior.floating,
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(AppRadius.sm),
            side: BorderSide(color: colors.border),
          ),
        ),
      );
    }

    return MaterialApp(
      debugShowCheckedModeBanner: false,
      navigatorKey: appNavigatorKey,
      theme: buildTheme(Brightness.light),
      darkTheme: buildTheme(Brightness.dark),
      themeMode: brightnessSetting.toThemeMode,
      themeAnimationDuration: policy.colorDuration(AppDurations.medium),
      scrollBehavior: const MaterialScrollBehavior().copyWith(
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        overscroll: false,
        scrollbars: false,
      ),
      builder: (context, child) {
        final brightness = Theme.of(context).brightness;
        final colors = resolveColors(paletteIndex, brightness);
        return ThemeColors(
          colors: colors,
          duration: policy.colorDuration(AppDurations.medium),
          child: ScrollConfiguration(
            behavior: const MaterialScrollBehavior().copyWith(
              physics: const BouncingScrollPhysics(
                parent: AlwaysScrollableScrollPhysics(),
              ),
              overscroll: false,
              scrollbars: false,
            ),
            child: child!,
          ),
        );
      },
      home: const LensRouter(),
    );
  }
}
