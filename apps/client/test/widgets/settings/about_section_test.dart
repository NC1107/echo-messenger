import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/update_provider.dart';
import 'package:echo_app/src/screens/settings/about_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../../helpers/mock_providers.dart';

Override chatOverride([ChatState state = const ChatState()]) {
  return chatProvider.overrideWith((ref) => _FakeChatNotifier(ref, state));
}

class _FakeChatNotifier extends ChatNotifier {
  _FakeChatNotifier(super.ref, ChatState initial) {
    state = initial;
  }
}

Override updateOverride([UpdateState state = const UpdateState()]) {
  return updateProvider.overrideWith((ref) => _FakeUpdateNotifier(state));
}

class _FakeUpdateNotifier extends UpdateNotifier {
  _FakeUpdateNotifier(UpdateState initial) {
    state = initial;
  }

  @override
  Future<void> check({bool force = false}) async {}
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  Widget buildSection() {
    return ProviderScope(
      overrides: [...standardOverrides(), chatOverride(), updateOverride()],
      child: MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: const Scaffold(body: AboutSection()),
      ),
    );
  }

  group('AboutSection', () {
    testWidgets('renders app name', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Echo Messenger'), findsOneWidget);
    });

    testWidgets('renders check for updates button', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Check for Updates'), findsOneWidget);
    });

    testWidgets('renders server info section', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      expect(find.text('Server'), findsOneWidget);
    });

    testWidgets('renders delete account button', (tester) async {
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();

      // Scroll down to delete account
      await tester.scrollUntilVisible(
        find.text('Delete Account'),
        200,
        scrollable: find.byType(Scrollable).first,
      );
      expect(find.text('Delete Account'), findsOneWidget);
    });
  });
}
