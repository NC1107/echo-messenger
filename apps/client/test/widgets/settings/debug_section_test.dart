import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/settings/debug_section.dart';
import 'package:echo_app/src/services/debug_log_service.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

void main() {
  setUp(() {
    DebugLogService.instance.clear();
  });

  Widget buildSection() {
    return MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const Scaffold(body: DebugSection()),
    );
  }

  group('DebugSection', () {
    testWidgets('renders title', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Debug Logs'), findsOneWidget);
    });

    testWidgets('renders copy and clear buttons', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Copy All'), findsOneWidget);
      expect(find.text('Clear Logs'), findsOneWidget);
    });

    testWidgets('shows entry count', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.textContaining('0 entries'), findsOneWidget);
    });

    testWidgets('shows empty state when no logs', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('No debug logs yet.'), findsOneWidget);
    });

    testWidgets('displays log entries', (tester) async {
      DebugLogService.instance.log(LogLevel.info, 'TestSrc', 'Test message');
      DebugLogService.instance.log(LogLevel.error, 'Crypto', 'Key failure');

      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.textContaining('2 entries'), findsOneWidget);
      expect(find.text('TestSrc'), findsOneWidget);
      expect(find.text('Crypto'), findsOneWidget);
    });

    testWidgets('clear button empties logs', (tester) async {
      DebugLogService.instance.log(LogLevel.info, 'Test', 'data');

      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.textContaining('1 entries'), findsOneWidget);

      await tester.tap(find.text('Clear Logs'));
      await tester.pumpAndSettle();

      expect(find.textContaining('0 entries'), findsOneWidget);
    });
  });
}
