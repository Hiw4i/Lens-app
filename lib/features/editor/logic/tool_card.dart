import 'package:flutter/widgets.dart' show IconData;
import 'package:lens/features/editor/logic/editor_state.dart'
    show EditorState, EditorStateNotifier;

/// One adjustable parameter of a tool: a card in the parameter strip and
/// the value shown on the shared slider above it.
///
/// Every implementation lives in its tool's feature folder
/// (`features/<tool>/cards/<tool>_cards.dart`), next to the ordered strip
/// list. The cards are pure configuration; the shared [ToolParamPanel]
/// renders the strip and the slider from these fields alone — it never
/// special-cases a tool, and the list only ever names the cards. A card
/// that grows real UI or behaviour graduates into its own file; it stops
/// being a one-line-of-config record long before that matters.
///
/// An abstract CLASS (not an interface) on purpose: the presentation
/// defaults below are inherited by every card that extends it.
abstract class ToolCard {
  const ToolCard();

  /// Stable id. Used for the card keys and by the tests.
  String get id;

  /// Card label: the strip shows it under the icon/value.
  String get label;

  /// Icon shown when the card carries no value.
  IconData get icon;

  /// Lower bound of [value] in UI units. The shared slider maps
  /// `min..max` onto its own 0..100 space.
  double get min;

  /// Upper bound of [value] in UI units.
  double get max;

  /// The current value.
  double value(EditorState state);

  /// The value as shown on the card (and on the slider when it shows one).
  String display(EditorState state);

  /// Writes the value. The notifier turns it into exactly one undoable
  /// step, so the card never touches the history itself.
  void set(EditorStateNotifier notifier, double value);

  /// The double-tap / reset target.
  void reset(EditorStateNotifier notifier);

  /// The slider shows the parameter label (otherwise the card carries it).
  bool get showSliderLabel => false;

  /// The slider shows the value readout (otherwise the card carries it).
  bool get showSliderValue => false;

  /// The card shows its value even when it is zero.
  bool get alwaysShowValue => false;

  /// Tapping the already-selected card resets the parameter to zero.
  bool get resetOnSecondTap => false;

  /// The slider locks onto the neutral point of a bipolar parameter.
  bool get snapToNeutral => false;
}

/// Presentation preset for cards whose value rides BOTH on the card and on
/// the slider (the user reads the percentage while dragging) and whose
/// selected card is not cleared by a second tap. Blur and Rays use it.
abstract class SliderValueCard extends ToolCard {
  const SliderValueCard();

  @override
  bool get showSliderLabel => true;

  @override
  bool get showSliderValue => true;

  @override
  bool get alwaysShowValue => true;
}
