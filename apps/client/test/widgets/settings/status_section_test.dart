import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/settings/status_section.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Fake notifier that captures setStatusText calls without hitting the network.
// ---------------------------------------------------------------------------

class _FakeAuthWithStatus extends AuthNotifier {
  _FakeAuthWithStatus(this._initial);
  final AuthState _initial;

  String? lastSetText;
  bool shouldThrow = false;

  @override
  AuthState build() => _initial;

  @override
  Future<bool> tryAutoLogin() async => false;

  @override
  Future<void> logout({String? serverUrl}) async => state = const AuthState();

  @override
  Future<void> setStatusText(String? text) async {
    if (shouldThrow) throw Exception('network error');
    lastSetText = text?.trim().isEmpty == true ? null : text?.trim();
    state = state.copyWith(statusText: lastSetText);
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

Widget _buildSection(AuthState initialState, {_FakeAuthWithStatus? notifier}) {
  final fake = notifier ?? _FakeAuthWithStatus(initialState);
  return ProviderScope(
    overrides: [
      ...standardOverrides(authState: initialState),
      authProvider.overrideWith(() => fake),
    ],
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: const Scaffold(body: StatusSection()),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  setUp(() => SharedPreferences.setMockInitialValues({}));

  group('StatusSection', () {
    testWidgets('renders section header and hint text', (tester) async {
      await tester.pumpWidget(
        _buildSection(const AuthState(isLoggedIn: true, token: 'tok')),
      );
      await tester.pumpAndSettle();

      expect(find.text('Status'), findsOneWidget);
      expect(
        find.text('Your status appears next to your name in conversations.'),
        findsOneWidget,
      );
    });

    testWidgets('renders text field with placeholder', (tester) async {
      await tester.pumpWidget(
        _buildSection(const AuthState(isLoggedIn: true, token: 'tok')),
      );
      await tester.pumpAndSettle();

      expect(find.text("What's on your mind?"), findsOneWidget);
    });

    testWidgets('pre-fills field with existing statusText', (tester) async {
      await tester.pumpWidget(
        _buildSection(
          const AuthState(
            isLoggedIn: true,
            token: 'tok',
            statusText: 'Working from home',
          ),
        ),
      );
      await tester.pumpAndSettle();

      expect(find.text('Working from home'), findsOneWidget);
    });

    testWidgets('Save button disabled when text unchanged', (tester) async {
      await tester.pumpWidget(
        _buildSection(
          const AuthState(isLoggedIn: true, token: 'tok', statusText: 'Hello'),
        ),
      );
      await tester.pumpAndSettle();

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveBtn.onPressed, isNull);
    });

    testWidgets('Save button enabled after editing text', (tester) async {
      await tester.pumpWidget(
        _buildSection(const AuthState(isLoggedIn: true, token: 'tok')),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), 'New status');
      await tester.pump();

      final saveBtn = tester.widget<FilledButton>(
        find.widgetWithText(FilledButton, 'Save'),
      );
      expect(saveBtn.onPressed, isNotNull);
    });

    testWidgets('tapping Save calls setStatusText with trimmed text', (
      tester,
    ) async {
      final fakeNotifier = _FakeAuthWithStatus(
        const AuthState(isLoggedIn: true, token: 'tok'),
      );

      await tester.pumpWidget(
        _buildSection(
          const AuthState(isLoggedIn: true, token: 'tok'),
          notifier: fakeNotifier,
        ),
      );
      await tester.pumpAndSettle();

      await tester.enterText(find.byType(TextField), '  hello  ');
      await tester.pump();

      await tester.tap(find.widgetWithText(FilledButton, 'Save'));
      // One frame to start the async call, then advance past the ToastService
      // dismiss timers (the toast auto-hides after ~3 s + a 2.5 s fade timer)
      // so the pending-timer invariant is satisfied when the widget tree tears
      // down at the end of the test.
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));

      expect(fakeNotifier.lastSetText, 'hello');
    });

    testWidgets('tapping Clear calls setStatusText with null', (tester) async {
      final fakeNotifier = _FakeAuthWithStatus(
        const AuthState(isLoggedIn: true, token: 'tok', statusText: 'hi'),
      );

      await tester.pumpWidget(
        _buildSection(
          const AuthState(isLoggedIn: true, token: 'tok', statusText: 'hi'),
          notifier: fakeNotifier,
        ),
      );
      await tester.pumpAndSettle();

      await tester.tap(find.widgetWithText(OutlinedButton, 'Clear'));
      // Same timer-drain strategy as the Save test above.
      await tester.pump();
      await tester.pump(const Duration(seconds: 6));

      expect(fakeNotifier.lastSetText, isNull);
    });

    testWidgets('shows character counter', (tester) async {
      await tester.pumpWidget(
        _buildSection(const AuthState(isLoggedIn: true, token: 'tok')),
      );
      await tester.pumpAndSettle();

      // Counter starts at 0 / 80
      expect(find.text('0 / 80'), findsOneWidget);

      await tester.enterText(find.byType(TextField), 'abc');
      await tester.pump();

      expect(find.text('3 / 80'), findsOneWidget);
    });

    testWidgets('renders Save and Clear buttons', (tester) async {
      await tester.pumpWidget(
        _buildSection(const AuthState(isLoggedIn: true, token: 'tok')),
      );
      await tester.pumpAndSettle();

      expect(find.widgetWithText(FilledButton, 'Save'), findsOneWidget);
      expect(find.widgetWithText(OutlinedButton, 'Clear'), findsOneWidget);
    });
  });
}
