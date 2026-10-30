import 'package:lens/features/editor/logic/tool_card.dart';

/// Base for the Adjust parameter cards.
///
/// The Adjust carousel drives one shared slider over the cards, so every
/// card there follows the same rules: the slider snaps back to the neutral
/// point of a bipolar parameter, and a second tap on the selected card
/// clears it.
abstract class AdjustCard extends ToolCard {
  const AdjustCard();

  @override
  bool get snapToNeutral => min < 0 && max > 0;

  @override
  bool get resetOnSecondTap => true;
}

/// Formats an Adjust value the way the carousel shows it: a signed
/// integer, with two decimals for the exposure (its unit is stops).
String formatAdjustValue(double value, {int digits = 0}) =>
    '${value > 0 ? '+' : ''}${value.toStringAsFixed(digits)}';
