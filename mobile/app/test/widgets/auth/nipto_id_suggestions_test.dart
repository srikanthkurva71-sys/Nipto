import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:nipto/widgets/auth/nipto_id_suggestions.dart';

void main() {
  group('NiptoIdSuggestions', () {
    testWidgets('renders candidate IDs and selected state', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NiptoIdSuggestions(
              suggestions: const ['river_27', 'river_28'],
              selectedId: 'river_28',
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.text('Suggested Nipto IDs'), findsOneWidget);
      expect(find.text('@river_27'), findsOneWidget);
      expect(find.text('@river_28'), findsOneWidget);
      final selectedChip = tester.widget<ChoiceChip>(
        find.ancestor(of: find.text('@river_28'), matching: find.byType(ChoiceChip)),
      );
      expect(selectedChip.selected, isTrue);
    });

    testWidgets('calls onSelected with the tapped candidate', (tester) async {
      String? selected;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NiptoIdSuggestions(
              suggestions: const ['river_27', 'river_28'],
              onSelected: (id) => selected = id,
            ),
          ),
        ),
      );

      await tester.tap(find.text('@river_28'));
      expect(selected, 'river_28');
    });

    testWidgets('renders nothing when there are no suggestions', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: NiptoIdSuggestions(
              suggestions: const [],
              onSelected: (_) {},
            ),
          ),
        ),
      );

      expect(find.byType(NiptoIdSuggestions), findsOneWidget);
      expect(find.text('Suggested Nipto IDs'), findsNothing);
      expect(find.byType(ChoiceChip), findsNothing);
    });
  });
}
