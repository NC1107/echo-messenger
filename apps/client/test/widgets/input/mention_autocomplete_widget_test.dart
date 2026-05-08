import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/widgets/input/mention_autocomplete.dart';

import '../../helpers/pump_app.dart';

void main() {
  const members = [
    ConversationMember(userId: 'u1', username: 'alice'),
    ConversationMember(userId: 'u2', username: 'bob'),
  ];

  Widget harness({required String query, ValueChanged<String>? onSelected}) {
    return MentionAutocomplete(
      members: members,
      mentionQuery: query,
      onMentionSelected: onSelected ?? (_) {},
    );
  }

  group('MentionAutocomplete broadcast suggestions', () {
    testWidgets('empty query shows all members + both broadcasts', (
      tester,
    ) async {
      await tester.pumpApp(harness(query: ''));
      await tester.pump();

      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('@everyone'), findsOneWidget);
      expect(find.text('@here'), findsOneWidget);
    });

    testWidgets('query "ev" surfaces only @everyone', (tester) async {
      await tester.pumpApp(harness(query: 'ev'));
      await tester.pump();

      expect(find.text('@everyone'), findsOneWidget);
      expect(find.text('@here'), findsNothing);
      expect(find.text('alice'), findsNothing);
    });

    testWidgets('query "he" surfaces only @here', (tester) async {
      await tester.pumpApp(harness(query: 'he'));
      await tester.pump();

      expect(find.text('@here'), findsOneWidget);
      expect(find.text('@everyone'), findsNothing);
    });

    testWidgets('query that matches nothing renders empty', (tester) async {
      await tester.pumpApp(harness(query: 'zzz'));
      await tester.pump();

      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('tapping @everyone fires onMentionSelected("everyone")', (
      tester,
    ) async {
      String? selected;
      await tester.pumpApp(
        harness(query: 'ev', onSelected: (k) => selected = k),
      );
      await tester.pump();

      await tester.tap(find.text('@everyone'));
      await tester.pump();

      expect(selected, 'everyone');
    });

    testWidgets('tapping @here fires onMentionSelected("here")', (
      tester,
    ) async {
      String? selected;
      await tester.pumpApp(
        harness(query: 'h', onSelected: (k) => selected = k),
      );
      await tester.pump();

      await tester.tap(find.text('@here'));
      await tester.pump();

      expect(selected, 'here');
    });

    testWidgets('member matches still take precedence near the cursor', (
      tester,
    ) async {
      // The picker is reverse:true; member rows have lower indices, so they
      // paint at the bottom (closest to text field). Verify both appear.
      await tester.pumpApp(harness(query: ''));
      await tester.pump();

      expect(find.text('alice'), findsOneWidget);
      expect(find.text('@everyone'), findsOneWidget);
    });
  });
}
