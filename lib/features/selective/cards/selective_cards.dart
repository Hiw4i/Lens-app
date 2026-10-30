import 'package:flutter/widgets.dart' show IconData;
import 'package:lens/features/editor/logic/editor_state.dart'
    show EditorState, EditorStateNotifier;
import 'package:lens/features/selective/cards/selective_card.dart';
import 'package:lucide_icons_flutter/lucide_icons.dart';

/// The Selective local-grade strip, in card order.
const List<SelectiveCard> kSelectiveCards = <SelectiveCard>[
  GradeExposureCard(),
  GradeContrastCard(),
  GradeSaturationCard(),
];

/// Local exposure inside the mask, -2..+2 stops (the state clamps to ±2 —
/// the range the grade and the shader actually apply).
class GradeExposureCard extends SelectiveCard {
  const GradeExposureCard();

  @override
  String get id => 'grade_exposure';

  @override
  String get label => 'Exposure';

  @override
  IconData get icon => LucideIcons.sun;

  @override
  double get min => -2;

  @override
  double get max => 2;

  @override
  double value(EditorState state) => state.selective.selExp;

  @override
  String display(EditorState state) {
    final double number = value(state);
    final String sign = number > 0 ? '+' : '';
    return '$sign${number.toStringAsFixed(2)}';
  }

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setSelectiveExp(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setSelectiveExp(0);
}

/// Local contrast inside the mask, -100..100.
class GradeContrastCard extends SelectiveCard {
  const GradeContrastCard();

  @override
  String get id => 'grade_contrast';

  @override
  String get label => 'Contrast';

  @override
  IconData get icon => LucideIcons.contrast;

  @override
  double get min => -100;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.selective.selCon;

  @override
  String display(EditorState state) {
    final double number = value(state);
    final String sign = number > 0 ? '+' : '';
    return '$sign${number.toStringAsFixed(0)}';
  }

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setSelectiveCon(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setSelectiveCon(0);
}

/// Local saturation inside the mask, -100..100.
class GradeSaturationCard extends SelectiveCard {
  const GradeSaturationCard();

  @override
  String get id => 'grade_saturation';

  @override
  String get label => 'Saturation';

  @override
  IconData get icon => LucideIcons.droplets;

  @override
  double get min => -100;

  @override
  double get max => 100;

  @override
  double value(EditorState state) => state.selective.selSat;

  @override
  String display(EditorState state) {
    final double number = value(state);
    final String sign = number > 0 ? '+' : '';
    return '$sign${number.toStringAsFixed(0)}';
  }

  @override
  void set(EditorStateNotifier notifier, double value) =>
      notifier.setSelectiveSat(value);

  @override
  void reset(EditorStateNotifier notifier) => notifier.setSelectiveSat(0);
}
