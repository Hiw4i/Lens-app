import 'dart:developer' as developer;

import 'package:flutter/foundation.dart';

/// Severity of a log record, mapped onto the `dart:developer` levels
/// (FINE=500 … SEVERE=1000) so DevTools filters work out of the box.
enum AppLogLevel {
  debug(500, 'DEBUG'),
  info(800, 'INFO'),
  warning(900, 'WARN'),
  error(1000, 'ERROR');

  const AppLogLevel(this.severity, this.label);

  final int severity;
  final String label;
}

/// The single logging facade for the app.
///
/// Design rules:
/// * Every log call is safe to make from anywhere, including error paths:
///   [AppLogger] itself never throws and never allocates lazily-bound
///   futures.
/// * Records go through `dart:developer` [developer.log], which is
///   visible in DevTools and near-zero-cost in profile/release; in debug
///   builds a console line is printed as well so `flutter run` shows the
///   failure inline.
/// * Never log per-frame or per-gesture: hot paths stay silent even at
///   [AppLogLevel.debug]. Cache misses, platform-call failures and
///   degraded-fallback decisions are the intended payload.
abstract final class AppLogger {
  static const String _rootTag = 'lens';

  static void d(String message, {String? context, Object? error, StackTrace? stackTrace}) =>
      _log(AppLogLevel.debug, message, context, error, stackTrace);

  static void i(String message, {String? context, Object? error, StackTrace? stackTrace}) =>
      _log(AppLogLevel.info, message, context, error, stackTrace);

  static void w(String message, {String? context, Object? error, StackTrace? stackTrace}) =>
      _log(AppLogLevel.warning, message, context, error, stackTrace);

  static void e(String message, {String? context, Object? error, StackTrace? stackTrace}) =>
      _log(AppLogLevel.error, message, context, error, stackTrace);

  static void _log(
    AppLogLevel level,
    String message,
    String? context,
    Object? error,
    StackTrace? stackTrace,
  ) {
    final String name = context == null || context.isEmpty
        ? _rootTag
        : '$_rootTag.$context';
    developer.log(
      message,
      name: name,
      level: level.severity,
      error: error,
      stackTrace: stackTrace,
    );
    if (kDebugMode) {
      final buffer = StringBuffer('[$name] ${level.label}: $message');
      if (error != null) buffer.write(' — $error');
      debugPrint(buffer.toString());
      if (stackTrace != null) debugPrint(stackTrace.toString());
    }
  }
}
