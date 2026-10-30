import 'package:animations/animations.dart';
import 'package:flutter/material.dart';
import 'package:lens/shared/motion/policy/ui_performance_scope.dart';

/// Policy-gated open-container surface.
///
/// Cinematic/balanced motion uses [OpenContainer] with a fade transition;
/// performance profile or disabled animations fall back to [_openDirectly],
/// a zero-duration push with the same builders.
class AdaptiveOpenContainer<T extends Object?> extends StatefulWidget {
  const AdaptiveOpenContainer({
    super.key,
    required this.closedBuilder,
    required this.openBuilder,
    required this.closedColor,
    required this.openColor,
    this.middleColor,
    this.closedElevation = 0,
    this.openElevation = 0,
    this.closedShape = const RoundedRectangleBorder(),
    this.openShape = const RoundedRectangleBorder(),
    this.onClosed,
    this.tappable = true,
  });

  final CloseContainerBuilder closedBuilder;
  final OpenContainerBuilder<T> openBuilder;
  final Color closedColor;
  final Color openColor;
  final Color? middleColor;
  final double closedElevation;
  final double openElevation;
  final ShapeBorder closedShape;
  final ShapeBorder openShape;
  final ValueChanged<T?>? onClosed;
  final bool tappable;

  @override
  State<AdaptiveOpenContainer<T>> createState() =>
      _AdaptiveOpenContainerState<T>();
}

class _AdaptiveOpenContainerState<T extends Object?>
    extends State<AdaptiveOpenContainer<T>> {
  bool _opening = false;

  @override
  Widget build(BuildContext context) {
    final Widget container;
    if (!context.uiPerformance.openContainerEnabled) {
      container = widget.closedBuilder(context, _openDirectly);
    } else {
      container = OpenContainer<T>(
        transitionDuration: context.uiPerformance.openContainerDuration,
        transitionType: ContainerTransitionType.fade,
        closedColor: widget.closedColor,
        openColor: widget.openColor,
        middleColor: widget.middleColor,
        closedElevation: widget.closedElevation,
        openElevation: widget.openElevation,
        closedShape: widget.closedShape,
        openShape: widget.openShape,
        tappable: widget.tappable,
        onClosed: widget.onClosed,
        closedBuilder: widget.closedBuilder,
        openBuilder: widget.openBuilder,
      );
    }

    return MouseRegion(
      cursor: widget.tappable ? SystemMouseCursors.click : MouseCursor.defer,
      child: container,
    );
  }

  Future<void> _openDirectly() async {
    if (_opening || !mounted) return;
    _opening = true;
    try {
      final result = await Navigator.of(context).push<T>(
        PageRouteBuilder<T>(
          transitionDuration: Duration.zero,
          reverseTransitionDuration: Duration.zero,
          pageBuilder: (routeContext, _, _) => widget.openBuilder(
            routeContext,
            ({T? returnValue}) =>
                Navigator.of(routeContext).pop<T>(returnValue),
          ),
        ),
      );
      widget.onClosed?.call(result);
    } finally {
      _opening = false;
    }
  }
}
