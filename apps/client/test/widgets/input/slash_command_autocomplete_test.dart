import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/input/slash_command_autocomplete.dart';

import '../../helpers/pump_app.dart';

void main() {
  Widget harness({
    required String inputText,
    bool userIsGroupAdmin = false,
    void Function(String)? onSelect,
  }) {
    return SlashCommandAutocomplete(
      inputText: inputText,
      userIsGroupAdmin: userIsGroupAdmin,
      onSelect: onSelect ?? (_) {},
    );
  }

  group('SlashCommandAutocomplete visibility', () {
    testWidgets('shows picker when input starts with /', (tester) async {
      await tester.pumpApp(harness(inputText: '/'));
      await tester.pump();

      // At least one command row should be visible.
      expect(find.byType(InkWell), findsWidgets);
    });

    testWidgets('hides picker when input does not start with /', (
      tester,
    ) async {
      await tester.pumpApp(harness(inputText: 'hello world'));
      await tester.pump();

      expect(find.byType(InkWell), findsNothing);
    });

    testWidgets('hides picker when input contains a space after the command', (
      tester,
    ) async {
      // The user has finished typing the command name and is now entering args.
      await tester.pumpApp(harness(inputText: '/poll '));
      await tester.pump();

      expect(find.byType(InkWell), findsNothing);
    });
  });

  group('SlashCommandAutocomplete filtering', () {
    testWidgets('filters commands by typed prefix (case-insensitive)', (
      tester,
    ) async {
      await tester.pumpApp(harness(inputText: '/po'));
      await tester.pump();

      // '/poll' matches the '/po' prefix.
      expect(find.text('/poll'), findsOneWidget);

      // '/shrug' does not start with 'po'.
      expect(find.text('/shrug'), findsNothing);
    });

    testWidgets('prefix match is case-insensitive', (tester) async {
      await tester.pumpApp(harness(inputText: '/SH'));
      await tester.pump();

      expect(find.text('/shrug'), findsOneWidget);
    });

    testWidgets('no-match query renders nothing', (tester) async {
      await tester.pumpApp(harness(inputText: '/zzz'));
      await tester.pump();

      expect(find.byType(InkWell), findsNothing);
    });
  });

  group('SlashCommandAutocomplete admin gating', () {
    testWidgets('admin commands hidden when userIsGroupAdmin is false', (
      tester,
    ) async {
      await tester.pumpApp(harness(inputText: '/', userIsGroupAdmin: false));
      await tester.pump();

      expect(find.text('/name'), findsNothing);
      expect(find.text('/kick'), findsNothing);
      expect(find.text('/description'), findsNothing);
    });

    testWidgets('admin commands shown when userIsGroupAdmin is true', (
      tester,
    ) async {
      await tester.pumpApp(harness(inputText: '/', userIsGroupAdmin: true));
      await tester.pump();

      expect(find.text('/name'), findsOneWidget);
      expect(find.text('/kick'), findsOneWidget);
      expect(find.text('/description'), findsOneWidget);
    });
  });

  group('SlashCommandAutocomplete onSelect callback', () {
    testWidgets('tapping a row calls onSelect with the command template', (
      tester,
    ) async {
      String? selected;
      await tester.pumpApp(
        harness(inputText: '/sh', onSelect: (template) => selected = template),
      );
      await tester.pump();

      // '/shrug ' is the template for /shrug.
      await tester.tap(find.text('/shrug'));
      await tester.pump();

      expect(selected, '/shrug ');
    });

    testWidgets('onSelect fires exactly once per tap (haptic path)', (
      tester,
    ) async {
      // Confirms the HapticFeedback wrapper does not break the callback or
      // cause it to fire more than once.
      var callCount = 0;
      await tester.pumpApp(
        harness(inputText: '/sh', onSelect: (_) => callCount++),
      );
      await tester.pump();

      await tester.tap(find.text('/shrug'));
      await tester.pump();

      expect(callCount, equals(1));
    });
  });
}
