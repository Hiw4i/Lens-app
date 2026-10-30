import 'package:flutter/material.dart';
import 'package:lens/features/library/library_screen.dart';

/// The gallery is home; editing and settings are reversible detail routes.
class LensRouter extends StatelessWidget {
  const LensRouter({super.key});

  static Future<T?> pushMaterial<T>(
    BuildContext context,
    Widget page, {
    String? name,
  }) => Navigator.of(context).push<T>(
    MaterialPageRoute<T>(
      builder: (_) => page,
      settings: RouteSettings(name: name),
    ),
  );

  static Future<T?> pushPage<T>(
    BuildContext context,
    Widget page, {
    String? name,
    Duration transitionDuration = const Duration(milliseconds: 300),
  }) async {
    final route = PageRouteBuilder<T>(
      settings: RouteSettings(name: name),
      transitionDuration: transitionDuration,
      reverseTransitionDuration: transitionDuration,
      pageBuilder: (_, _, _) => page,
      transitionsBuilder: (_, animation, _, child) =>
          FadeTransition(opacity: animation, child: child),
    );
    final result = await Navigator.of(context).push<T>(route);
    await route.completed;
    return result;
  }

  @override
  Widget build(BuildContext context) => const LibraryScreen();
}
