import 'package:flutter/widgets.dart' show IconData;
import 'package:lens/features/adjust/cards/adjust_card.dart';
import 'package:lens/features/editor/logic/editor_state.dart'
    show EditorState, EditorStateNotifier;
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Adjust carousel, in strip order.
///
/// The auto-grade (Enhance) leads — it is the one card that does
/// everything at once — and the manual parameters follow in the order the
/// pipeline applies them. All nine cards are pure configuration (id,
/// label, icon, range, value/display/set/reset); a card that needs its own
/// UI or behaviour graduates from this file into its own — the strip list
/// only ever names the cards.
const List<AdjustCard> kAdjustCards = <AdjustCard>[
  EnhanceCard(),
  ExposureCard(),
  StructureCard(),
  ContrastCard(),
  SaturationCard(),
  TemperatureCard(),
  TintCard(),
  ShadowsCard(),
  HighlightsCard(),
];

/// The Enhance card: the one-tap auto-grade.
///
/// Unlike the other cards its value lives on the editor state itself (the
/// master mix of the Enhance stage), not on [AdjustParams].
class EnhanceCard extends AdjustCard {
  const EnhanceCard();

  @override
  String get id => 'enhance';

  @override
  String get label => 'Enhance';

  @override
  IconData get icon => LucideIcons.sparkles;

  @override
  double get min => 0;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.enhanceStrength;

  @override
  String display(EditorState state) => state.enhanceStrength.round().toString();

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setEnhanceStrength(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.clearEnhance();
}

/// Exposure in stops, -3..+3.
class ExposureCard extends AdjustCard {
  const ExposureCard();

  @override
  String get id => 'exposure';

  @override
  String get label => 'Exposure';

  @override
  IconData get icon => LucideIcons.sun;

  @override
  double get min => -3;

  @override
  double get max => 3;

  @override
  double value(EditorState state) => state.adjust.exposure;

  @override
  String display(EditorState state) =>
      formatAdjustValue(value(state), digits: 2);

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setExposure(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setExposure(0);
}

/// Local contrast (clarity), -100..100; negative softens the texture.
class StructureCard extends AdjustCard {
  const StructureCard();

  @override
  String get id => 'structure';

  @override
  String get label => 'Structure';

  @override
  IconData get icon => LucideIcons.layers;

  @override
  double get min => -100;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.adjust.structure;

  @override
  String display(EditorState state) => formatAdjustValue(value(state));

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setStructure(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setStructure(0);
}

/// Global contrast, -100..100.
class ContrastCard extends AdjustCard {
  const ContrastCard();

  @override
  String get id => 'contrast';

  @override
  String get label => 'Contrast';

  @override
  IconData get icon => LucideIcons.contrast;

  @override
  double get min => -100;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.adjust.contrast;

  @override
  String display(EditorState state) => formatAdjustValue(value(state));

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setContrast(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setContrast(0);
}

/// Global saturation, -100..100.
class SaturationCard extends AdjustCard {
  const SaturationCard();

  @override
  String get id => 'saturation';

  @override
  String get label => 'Saturation';

  @override
  IconData get icon => LucideIcons.droplets;

  @override
  double get min => -100;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.adjust.saturation;

  @override
  String display(EditorState state) => formatAdjustValue(value(state));

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setSaturation(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setSaturation(0);
}

/// Colour temperature, -100..100.
class TemperatureCard extends AdjustCard {
  const TemperatureCard();

  @override
  String get id => 'temperature';

  @override
  String get label => 'Temp';

  @override
  IconData get icon => LucideIcons.thermometer;

  @override
  double get min => -100;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.adjust.temp;

  @override
  String display(EditorState state) => formatAdjustValue(value(state));

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setTemp(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setTemp(0);
}

/// Green/magenta tint, -80..80.
class TintCard extends AdjustCard {
  const TintCard();

  @override
  String get id => 'tint';

  @override
  String get label => 'Tint';

  @override
  IconData get icon => LucideIcons.palette;

  @override
  double get min => -80;

  @override
  double get max => 80;

  @override
  double value(EditorState state) => state.adjust.tint;

  @override
  String display(EditorState state) => formatAdjustValue(value(state));

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setTint(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setTint(0);
}

/// Shadow detail, -80..80.
class ShadowsCard extends AdjustCard {
  const ShadowsCard();

  @override
  String get id => 'shadows';

  @override
  String get label => 'Shadows';

  @override
  IconData get icon => LucideIcons.moon;

  @override
  double get min => -80;

  @override
  double get max => 80;

  @override
  double value(EditorState state) => state.adjust.shadows;

  @override
  String display(EditorState state) => formatAdjustValue(value(state));

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setShadows(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setShadows(0);
}

/// Highlight detail, -80..80.
class HighlightsCard extends AdjustCard {
  const HighlightsCard();

  @override
  String get id => 'highlights';

  @override
  String get label => 'Highlights';

  @override
  IconData get icon => LucideIcons.sunrise;

  @override
  double get min => -80;

  @override
  double get max => 80;

  @override
  double value(EditorState state) => state.adjust.highlights;

  @override
  String display(EditorState state) => formatAdjustValue(value(state));

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setHighlights(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setHighlights(0);
}
