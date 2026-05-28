// Tests for [UserStatusMenuSheet]: the bottom-sheet that appears when the
// user taps their own avatar in the sidebar footer.
//
// Covers:
//   - renders 4 presence rows (Online / Idle / DND / Invisible)
//   - renders the custom-status row (input mode when no status is set)
//   - renders the custom-status row (clear mode when a status is set)
//   - tapping X clears the status via the auth notifier

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/user_status_menu.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Tracking notifier — records setStatusText calls without hitting the network
// ---------------------------------------------------------------------------

class _TrackingAuthNotifier extends AuthNotifier {
  _TrackingAuthNotifier(this._initial);

  final AuthState _initial;

  String? lastStatusText = 'sentinel'; // sentinel so we can detect no-call
  bool statusTextCalled = false;

  @override
  AuthState build() => _initial;

  @override
  Future<bool> tryAutoLogin() async => false;

  @override
  Future<void> logout({String? serverUrl}) async => state = const AuthState();

  @override
  Future<void> setPresenceStatus(String status) async {
    state = state.copyWith(presenceStatus: status);
  }

  @override
  Future<void> setStatusText(String? text) async {
    statusTextCalled = true;
    lastStatusText = text;
    state = state.copyWith(statusText: text);
  }
}

// ---------------------------------------------------------------------------
// Test scaffold
// ---------------------------------------------------------------------------

Widget _wrap(
  Widget child,
  AuthState authState, [
  _TrackingAuthNotifier? notifier,
]) {
  final overrides = <Override>[
    if (notifier != null)
      authProvider.overrideWith(() => notifier)
    else
      authOverride(authState),
    serverUrlOverride(),
  ];
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(body: child),
    ),
  );
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('UserStatusMenuSheet', () {
    testWidgets('renders four presence rows', (tester) async {
      await tester.pumpWidget(
        _wrap(const UserStatusMenuSheet(), loggedInAuthState),
      );
      await tester.pump();

      expect(find.text('Online'), findsOneWidget);
      expect(find.text('Idle'), findsOneWidget);
      expect(find.text('DND'), findsOneWidget);
      expect(find.text('Invisible'), findsOneWidget);
    });

    testWidgets('renders custom status input row when no status is set', (
      tester,
    ) async {
      await tester.pumpWidget(
        _wrap(
          const UserStatusMenuSheet(),
          loggedInAuthState, // statusText is null
        ),
      );
      await tester.pump();

      expect(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText == 'Set a custom status...'),
        ),
        findsOneWidget,
      );
    });

    testWidgets('renders clear row with X button when status is set', (
      tester,
    ) async {
      const authState = AuthState(
        isLoggedIn: true,
        userId: 'test-user-id',
        username: 'testuser',
        token: 'fake-jwt-token',
        refreshToken: 'fake-refresh-token',
        statusText: 'lunch',
      );

      await tester.pumpWidget(_wrap(const UserStatusMenuSheet(), authState));
      await tester.pump();

      expect(find.text('lunch'), findsOneWidget);
      expect(find.bySemanticsLabel('clear custom status'), findsOneWidget);
      // Input field should NOT be visible when a status is already set.
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is TextField &&
              (w.decoration?.hintText == 'Set a custom status...'),
        ),
        findsNothing,
      );
    });

    testWidgets('tapping X clears status via notifier', (tester) async {
      const authState = AuthState(
        isLoggedIn: true,
        userId: 'test-user-id',
        username: 'testuser',
        token: 'fake-jwt-token',
        refreshToken: 'fake-refresh-token',
        statusText: 'lunch',
      );
      final notifier = _TrackingAuthNotifier(authState);

      await tester.pumpWidget(
        _wrap(const UserStatusMenuSheet(), authState, notifier),
      );
      await tester.pump();

      expect(find.text('lunch'), findsOneWidget);

      await tester.tap(find.bySemanticsLabel('clear custom status'));
      await tester.pump();

      expect(notifier.statusTextCalled, isTrue);
      expect(notifier.lastStatusText, isNull);
    });
  });
}
