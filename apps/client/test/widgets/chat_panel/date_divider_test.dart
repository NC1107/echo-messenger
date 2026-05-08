import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/theme_provider.dart' show UIDensity;
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/chat_panel/date_divider.dart';

Widget _wrap(Widget child) {
  return ProviderScope(
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(body: child),
    ),
  );
}

Future<void> _pumpAt(WidgetTester tester, UIDensity density) async {
  await tester.pumpWidget(
    _wrap(
      DateDivider(
        // Pick a date that always renders the long label ("May 8, 2025"),
        // so the test isn't sensitive to "Today"/"Yesterday" timing.
        timestamp: '2025-05-08T10:00:00Z',
        density: density,
      ),
    ),
  );
  await tester.pump();
}

void main() {
  group('DateDivider density', () {
    testWidgets('cozy renders 12pt label', (tester) async {
      await _pumpAt(tester, UIDensity.cozy);
      final label = tester.widget<Text>(find.byType(Text));
      expect(label.style?.fontSize, 12);
    });

    testWidgets('normal renders 11pt label', (tester) async {
      await _pumpAt(tester, UIDensity.normal);
      final label = tester.widget<Text>(find.byType(Text));
      expect(label.style?.fontSize, 11);
    });

    testWidgets('compact renders 11pt label (today\'s)', (tester) async {
      await _pumpAt(tester, UIDensity.compact);
      final label = tester.widget<Text>(find.byType(Text));
      expect(label.style?.fontSize, 11);
    });

    testWidgets('renders SizedBox.shrink for malformed timestamp', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(const DateDivider(timestamp: 'not-a-date')),
      );
      await tester.pump();
      expect(find.byType(Text), findsNothing);
    });
  });
}
