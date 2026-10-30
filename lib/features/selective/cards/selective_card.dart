import 'package:lens/features/editor/logic/tool_card.dart';

/// Base for the Selective local-grade cards.
///
/// The grade strip hides the slider's label and readout (the card carries
/// both), and a second tap on the selected card clears it.
abstract class SelectiveCard extends ToolCard {
  const SelectiveCard();

  @override
  bool get resetOnSecondTap => true;
}