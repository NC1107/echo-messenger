import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/settings/devices_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../../helpers/mock_providers.dart';

Future<void> _pump(WidgetTester tester) async {
  SharedPreferences.setMockInitialValues({});
  await tester.pumpWidget(
    ProviderScope(
      overrides: standardOverrides(),
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(body: DevicesSection()),
      ),
    ),
  );
  // First frame -> initState scheduled the post-frame _loadDevices().
  await tester.pump();
}

void main() {
  group('DevicesSection', () {
    testWidgets('renders the section header and description', (tester) async {
      await _pump(tester);

      expect(find.text('My Devices'), findsOneWidget);
      expect(
        find.text('Manage devices that have access to your account.'),
        findsOneWidget,
      );
    });

    testWidgets('shows a refresh icon button in the header', (tester) async {
      await _pump(tester);
      expect(find.byIcon(Icons.refresh), findsOneWidget);
    });

    testWidgets(
      'after the load returns 400 the section shows the error branch',
      (tester) async {
        await _pump(tester);
        // The TestWidgetsFlutterBinding stubs every HTTP request with a 400
        // response, so _loadDevices flips the section into the error branch
        // on the first frame after the post-frame callback fires.
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        // Either a Retry button OR the failure copy itself ("Failed to load
        // devices (400)") — depending on whether the binding chose to throw
        // (catch branch) or hand back the 400 (status-code branch). Both
        // are valid "load did not succeed" states.
        final hasRetry = find
            .widgetWithText(FilledButton, 'Retry')
            .evaluate()
            .isNotEmpty;
        final hasFailMsg = find
            .textContaining('Failed to load devices')
            .evaluate()
            .isNotEmpty;
        final hasNetErr = find
            .textContaining('Network error')
            .evaluate()
            .isNotEmpty;
        expect(hasRetry || hasFailMsg || hasNetErr, isTrue);
      },
    );
  });
}
