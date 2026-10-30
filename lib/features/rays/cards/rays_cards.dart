import 'package:flutter/widgets.dart' show IconData;
import 'package:lens/features/editor/logic/editor_state.dart'
    show EditorState, EditorStateNotifier;
import 'package:lens/features/editor/logic/tool_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Rays parameter strip, in card order.
const List<SliderValueCard> kRaysCards = <SliderValueCard>[
  IntensityCard(),
  LengthCard(),
  WarmthCard(),
  DensityCard(),
  ModeCard(),
  AngleCard(),
  WidthCard(),
];

/// Shaft strength, 0..100 UI units.
class IntensityCard extends SliderValueCard {
  const IntensityCard();

  @override
  String get id => 'intensity';

  @override
  String get label => 'Intensity';

  @override
  IconData get icon => LucideIcons.sun;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.rays.intensity;

  @override
  String display(EditorState state) => value(state).round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setRaysIntensity(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.clearRays();
}

/// March length as a share of the frame diagonal, 0..100.
class LengthCard extends SliderValueCard {
  const LengthCard();

  /// Double-tap target: the parked default.
  static const double kDefault = 60;

  @override
  String get id => 'length';

  @override
  String get label => 'Length';

  @override
  IconData get icon => LucideIcons.sunrise;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.rays.length;

  @override
  String display(EditorState state) => value(state).round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setRaysLength(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setRaysLength(kDefault);
}

/// Shaft colour, 0 = neutral white, 100 = golden.
class WarmthCard extends SliderValueCard {
  const WarmthCard();

  /// Double-tap target: the parked default.
  static const double kDefault = 70;

  @override
  String get id => 'warmth';

  @override
  String get label => 'Warmth';

  @override
  IconData get icon => LucideIcons.thermometer;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.rays.warmth;

  @override
  String display(EditorState state) => value(state).round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setRaysWarmth(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setRaysWarmth(kDefault);
}

/// Streak frequency/sharpness, 0..100.
class DensityCard extends SliderValueCard {
  const DensityCard();

  /// Double-tap target: the parked default.
  static const double kDefault = 50;

  @override
  String get id => 'density';

  @override
  String get label => 'Density';

  @override
  IconData get icon => LucideIcons.layers;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.rays.density;

  @override
  String display(EditorState state) => value(state).round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setRaysDensity(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setRaysDensity(kDefault);
}

/// Ray kind: bright source or fog.
class ModeCard extends SliderValueCard {
  const ModeCard();

  @override
  String get id => 'mode';

  @override
  String get label => 'Type';

  @override
  IconData get icon => LucideIcons.sparkles;

  @override
  double get min => 0;

  @override
  double get max => 100;

  /// The kind is stored as 0/1; the strip shows it as 0/100.
  static const int kSource = 0;

  @override
  double value(EditorState state) => state.rays.mode * 100;

  @override
  String display(EditorState state) => state.rays.mode == 0 ? 'Source' : 'Fog';

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setRaysMode((value / 100).round());

  @override
  void reset(EditorStateNotifier notifier) => notifier.setRaysMode(0);
}

/// Ray direction in degrees (0..360).
class AngleCard extends SliderValueCard {
  const AngleCard();

  /// Double-tap target: the parked default (0 degrees).
  static const double kDefault = 0;

  @override
  String get id => 'angle';

  @override
  String get label => 'Direction';

  @override
  IconData get icon => LucideIcons.compass;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.rays.angle / 3.6;

  @override
  String display(EditorState state) => state.rays.angle.round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setRaysAngle(value * 3.6);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setRaysAngle(kDefault);
}

/// Ray angular spread, 0..100.
class WidthCard extends SliderValueCard {
  const WidthCard();

  /// Double-tap target: the parked default.
  static const double kDefault = 100;

  @override
  String get id => 'width';

  @override
  String get label => 'Width';

  @override
  IconData get icon => LucideIcons.maximize2;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.rays.width;

  @override
  String display(EditorState state) => value(state).round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setRaysWidth(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setRaysWidth(kDefault);
}
