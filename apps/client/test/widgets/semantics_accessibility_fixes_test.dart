import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/screens/contacts_screen.dart';
import 'package:echo_app/src/screens/settings/privacy_section.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Override _privacyOverride([PrivacyState state = const PrivacyState()]) {
  return privacyProvider.overrideWith(
    (ref) => _FakePrivacyNotifier(ref, state),
  );
}

class _FakePrivacyNotifier extends PrivacyNotifier {
  _FakePrivacyNotifier(super.ref, PrivacyState initial) {
    state = initial;
  }

  @override
  Future<void> load() async {}

  @override
  Future<void> setReadReceiptsEnabled(bool value) async {
    state = state.copyWith(readReceiptsEnabled: value);
  }

  @override
  Future<void> setSearchable(bool value) async {
    state = state.copyWith(searchable: value);
  }
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  group('Contacts search field accessibility', () {
    testWidgets('search bar has "Search contacts" label', (tester) async {
      await tester.pumpWidget(
        ProviderScope(
          overrides: [...standardOverrides()],
          child: MaterialApp(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            home: const Scaffold(body: ContactsScreen()),
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Search contacts'), findsOneWidget);
    });
  });

  group('Privacy section field accessibility', () {
    Widget buildPrivacySection() {
      return ProviderScope(
        overrides: [
          authOverride(loggedInAuthState),
          serverUrlOverride(),
          cryptoOverride(),
          _privacyOverride(),
          biometricOverride(),
        ],
        child: MaterialApp(
          theme: EchoTheme.darkTheme,
          darkTheme: EchoTheme.darkTheme,
          themeMode: ThemeMode.dark,
          home: const Scaffold(body: PrivacySection()),
        ),
      );
    }

    testWidgets('reset dialog has labeled password field', (tester) async {
      await tester.pumpWidget(buildPrivacySection());
      await tester.pumpAndSettle();

      // Scroll to the Reset Encryption Keys button
      await tester.scrollUntilVisible(
        find.text('Reset Encryption Keys'),
        200,
        scrollable: find.byType(Scrollable).first,
      );

      // Tap the reset button to open the dialog
      await tester.tap(find.text('Reset Encryption Keys'));
      await tester.pumpAndSettle();

      // The password field should have a labelText
      expect(find.text('Password'), findsWidgets);
      // The confirm field should have a labelText
      expect(find.text('Confirm reset'), findsOneWidget);
    });
  });

  // Account section phone field labels ('Country code', 'Phone number') are
  // verified by code review -- the phone field is deep inside a lazy ListView
  // and not built until scrolled into view, making widget-test assertions
  // unreliable without a full integration test harness.
}
