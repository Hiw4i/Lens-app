import 'dart:typed_data';

import 'package:flutter/material.dart';

/// A single predecoded raster travels from the grid crop to the photo bounds.
class PhotoHero extends StatelessWidget {
  const PhotoHero({
    super.key,
    required this.id,
    required this.bytes,
    required this.child,
  });
  final String id;
  final Uint8List bytes;
  final Widget child;

  @override
  Widget build(BuildContext context) => Hero(
    tag: id,
    createRectTween: (begin, end) => RectTween(begin: begin, end: end),
    curve: Curves.easeInOutCubicEmphasized,
    reverseCurve: Curves.easeInOutCubicEmphasized,
    flightShuttleBuilder: (_, animation, direction, from, to) {
      final context = direction == HeroFlightDirection.push ? to : from;
      final content = (context.widget as Hero).child as _HeroContent;
      final raster = Image.memory(
        content.bytes,
        fit: BoxFit.cover,
        gaplessPlayback: true,
      );
      if (direction == HeroFlightDirection.push) return ClipRect(child: raster);
      final thumbnail = ((to.widget as Hero).child as _HeroContent).bytes;
      // Resolve back into the original gallery thumbnail only at the end,
      // rather than flashing the original at the start of a graded return.
      return ClipRect(
        child: Stack(
          fit: StackFit.expand,
          children: [
            raster,
            FadeTransition(
              opacity: animation.drive(
                Tween<double>(
                  begin: 1,
                  end: 0,
                ).chain(CurveTween(curve: const Interval(0, .35))),
              ),
              child: Image.memory(
                thumbnail,
                fit: BoxFit.cover,
                gaplessPlayback: true,
              ),
            ),
          ],
        ),
      );
    },
    child: _HeroContent(bytes: bytes, child: child),
  );
}

class _HeroContent extends StatelessWidget {
  const _HeroContent({required this.bytes, required this.child});
  final Uint8List bytes;
  final Widget child;
  @override
  Widget build(BuildContext context) => child;
}
