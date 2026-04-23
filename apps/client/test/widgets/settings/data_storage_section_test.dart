import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/screens/settings/data_storage_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../../helpers/mock_providers.dart';

void main() {
  Widget buildSection() {
    return ProviderScope(
      overrides: [...standardOverrides()],
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(body: DataStorageSection()),
      ),
    );
  }

  group('DataStorageSection', () {
    testWidgets('renders section title', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Data & Storage'), findsOneWidget);
    });

    testWidgets('renders message cache item', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Message Cache'), findsOneWidget);
    });

    testWidgets('renders clear button for cache', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Clear'), findsOneWidget);
    });

    testWidgets('renders export data item', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Export My Data'), findsOneWidget);
    });

    testWidgets('export shows copy account info button', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Copy Account Info'), findsOneWidget);
    });
  });
}
