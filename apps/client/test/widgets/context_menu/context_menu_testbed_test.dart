import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/context_menu/context_menu_testbed.dart';

Future<void> _pump(WidgetTester tester) async {
  await tester.pumpWidget(
    ProviderScope(
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const ContextMenuTestbed(),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

void main() {
  group('ContextMenuTestbed', () {
    testWidgets('renders the screen scaffold with the three demo cards', (
      tester,
    ) async {
      await _pump(tester);
      expect(find.text('Context menu testbed'), findsOneWidget);
      // Card labels.
      expect(find.text('message'), findsOneWidget);
      expect(find.text('conversation'), findsOneWidget);
      expect(find.text('member'), findsOneWidget);
      // Card previews.
      expect(find.text('hey, are you free at 3?'), findsOneWidget);
      expect(find.text('# general'), findsOneWidget);
      expect(find.text('@npc'), findsOneWidget);
    });

    testWidgets('long-pressing the message card opens its context menu', (
      tester,
    ) async {
      await _pump(tester);
      // Long-press the message preview row -> opens the context menu.
      await tester.longPress(find.text('hey, are you free at 3?'));
      await tester.pumpAndSettle();

      // A handful of message-target rows from the demo model should appear.
      expect(find.text('Reply'), findsOneWidget);
      expect(find.text('Delete Message'), findsOneWidget);
    });
  });
}
