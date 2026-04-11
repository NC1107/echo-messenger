import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/screens/settings/privacy_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../../helpers/mock_providers.dart';

Override privacyOverride([PrivacyState state = const PrivacyState()]) {
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

void main() {
  Widget buildSection({PrivacyState privacyState = const PrivacyState()}) {
    return ProviderScope(
      overrides: [
        authOverride(loggedInAuthState),
        serverUrlOverride(),
        cryptoOverride(),
        privacyOverride(privacyState),
      ],
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(body: PrivacySection()),
      ),
    );
  }

  group('PrivacySection', () {
    testWidgets('renders messaging privacy section', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Messaging Privacy'), findsOneWidget);
    });

    testWidgets('renders read receipts toggle', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Send Read Receipts'), findsOneWidget);
    });

    testWidgets('renders contact info visibility section', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Contact Info Visibility'), findsOneWidget);
    });

    testWidgets('renders email/phone visibility toggles', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Show Email on Profile'), findsOneWidget);
      expect(find.text('Show Phone on Profile'), findsOneWidget);
    });

    testWidgets('renders discoverable toggles', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Discoverable by Email'), findsOneWidget);
      expect(find.text('Discoverable by Phone'), findsOneWidget);
    });

    testWidgets('renders search and encryption sections via scroll', (
      tester,
    ) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // Scroll down to reveal encryption section
      await tester.scrollUntilVisible(
        find.text('Encryption'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Encryption'), findsOneWidget);

      await tester.scrollUntilVisible(
        find.text('Reset Encryption Keys'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Reset Encryption Keys'), findsOneWidget);
    });
  });
}
