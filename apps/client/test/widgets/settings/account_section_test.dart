import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/settings/account_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../../helpers/mock_providers.dart';

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildSection() {
    return ProviderScope(
      overrides: [...standardOverrides()],
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(body: AccountSection()),
      ),
    );
  }

  group('AccountSection', () {
    testWidgets('renders avatar', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.byType(CircleAvatar), findsWidgets);
    });

    testWidgets('renders upload avatar button', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Upload Avatar'), findsOneWidget);
    });

    testWidgets('renders change password section', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // "Change Password" appears as section header and as button text
      expect(find.text('Change Password'), findsWidgets);
    });
  });
}
