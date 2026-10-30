import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lens/features/editor/logic/editor_state.dart';
import 'package:lens/features/editor/widgets/tool_rail.dart';
import 'package:lens/shared/theme/theme_colors.dart';

void main() {
  group('editor tool rail', () {
    test('crop is the first tool in the rail', () {
      expect(ToolRail.tools.first.$1, EditorTool.crop);
    });

    testWidgets('the crop chip sits at the start of the rail', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ThemeColors(
            colors: palettes.first.dark,
            duration: Duration.zero,
            child: Scaffold(
              body: ToolRail(selected: EditorTool.adjust, onSelect: (_) {}),
            ),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Crop'), findsOneWidget);
      expect(
        tester.getRect(find.text('Crop')).left,
        lessThan(tester.getRect(find.text('Filters')).left),
      );
    });
  });
}
