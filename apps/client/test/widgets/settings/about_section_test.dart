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
  return chatProvider.overrideWith(() => _FakeChatNotifier(state));
}

class _FakeChatNotifier extends Chat {
  _FakeChatNotifier(this._initial);

  final ChatState _initial;

  @override
  ChatState build() => _initial;
}

Override updateOverride([UpdateState initial = const UpdateState()]) {
  return updateProvider.overrideWith(() => _FakeUpdate(initial));
}

class _FakeUpdate extends Update {
  _FakeUpdate(this._initial);
  final UpdateState _initial;

  @override
  UpdateState build() => _initial;

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

    testWidgets('does not render delete account button (moved to Privacy)', (
      tester,
    ) async {
      // Delete Account moved to the Privacy → Danger Zone on 2026-05-27.
      // About is now informational only.
      await tester.pumpWidget(buildSection());
      await tester.pumpAndSettle();
      expect(find.text('Delete Account'), findsNothing);
    });
  });
}
