import 'package:flutter/widgets.dart' show IconData;
import 'package:lens/features/editor/logic/editor_state.dart'
    show EditorState, EditorStateNotifier;
import 'package:lens/features/editor/logic/tool_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Blur parameter strip, in card order.
const List<SliderValueCard> kBlurCards = <SliderValueCard>[
  RadiusCard(),
  FeatherCard(),
];

/// Bokeh radius, 0..100 UI units.
class RadiusCard extends SliderValueCard {
  const RadiusCard();

  /// Double-tap target: the parked default of this parameter.
  static const double kDefault = 40;

  @override
  String get id => 'radius';

  @override
  String get label => 'Blur';

  @override
  IconData get icon => LucideIcons.aperture;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.blur.radius;

  @override
  String display(EditorState state) => value(state).round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setBlurRadius(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setBlurRadius(kDefault);
}

/// Mask edge softness, 0..100 UI units.
class FeatherCard extends SliderValueCard {
  const FeatherCard();

  /// Double-tap target: the parked default of this parameter.
  static const double kDefault = 50;

  @override
  String get id => 'feather';

  @override
  String get label => 'Feather';

  @override
  IconData get icon => LucideIcons.feather;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.blur.feather;

  @override
  String display(EditorState state) => value(state).round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setBlurFeather(value);

  @override
  void reset(EditorStateNotifier notifier) =>
      notifier.setBlurFeather(kDefault);
}
