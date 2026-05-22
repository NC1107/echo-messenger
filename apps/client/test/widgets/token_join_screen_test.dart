import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/token_join_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

import '../helpers/mock_http_client.dart';
import '../helpers/mock_providers.dart';

const _kToken = 'test-invite-token';
const _kConversationId = 'conv-abc-123';

GoRouter _buildRouter({String token = _kToken}) {
  return GoRouter(
    initialLocation: '/invite/t/$token',
    routes: [
      GoRoute(
        path: '/invite/t/:token',
        builder: (_, state) =>
            TokenJoinScreen(token: state.pathParameters['token']!),
      ),
      GoRoute(
        path: '/home',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('HOME_SCREEN'))),
      ),
      GoRoute(
        path: '/login',
        builder: (_, _) =>
            const Scaffold(body: Center(child: Text('LOGIN_SCREEN'))),
      ),
    ],
  );
}

Widget _wrap(GoRouter router, List<Override> overrides) {
  return ProviderScope(
    overrides: overrides,
    child: MaterialApp.router(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      routerConfig: router,
    ),
  );
}

/// Build the GET /api/invites/:token preview body in the shape the SERVER
/// actually returns — `{token, group: {id, title, ...}}`. Keeping this in
/// one place so tests assert against the real contract; if the server shape
/// ever changes the test stubs change with it.
Map<String, dynamic> _previewJson({
  String token = _kToken,
  String groupId = _kConversationId,
  String title = 'Echo Hackers',
  String? description = 'Build messengers in their spare time.',
  String? iconUrl,
  int memberCount = 42,
  bool isMember = false,
}) => {
  'token': token,
  'group': {
    'id': groupId,
    'title': title,
    'description': description,
    'icon_url': iconUrl,
    'member_count': memberCount,
    'is_member': isMember,
    'members': const <Map<String, dynamic>>[],
  },
};

void _stubPreview(
  MockHttpClient mockClient, {
  required Map<String, dynamic> body,
  int statusCode = 200,
}) {
  when(
    () => mockClient.get(
      any(that: predicate<Uri>((u) => u.path == '/api/invites/$_kToken')),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => http.Response(jsonEncode(body), statusCode));
}

void _stubAccept(
  MockHttpClient mockClient, {
  int statusCode = 200,
  Map<String, dynamic>? body,
}) {
  when(
    () => mockClient.post(
      any(
        that: predicate<Uri>((u) => u.path == '/api/invites/$_kToken/accept'),
      ),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
      encoding: any(named: 'encoding'),
    ),
  ).thenAnswer(
    (_) async => http.Response(jsonEncode(body ?? const {}), statusCode),
  );
}

void main() {
  setUpAll(registerHttpFallbackValues);

  group('TokenJoinScreen', () {
    testWidgets('shows loading skeleton initially', (tester) async {
      final router = _buildRouter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [...standardOverrides()],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );

      expect(find.byType(TokenJoinScreen), findsOneWidget);
    });

    testWidgets('renders error card for logged-out user without token lookup', (
      tester,
    ) async {
      final router = _buildRouter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [
            ...standardOverrides(authState: const AuthState()), // logged out
          ],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      expect(find.text('Log in to join'), findsOneWidget);
    });

    testWidgets('navigates to login on "Log in to join" tap', (tester) async {
      final router = _buildRouter();

      await tester.pumpWidget(
        ProviderScope(
          overrides: [...standardOverrides(authState: const AuthState())],
          child: MaterialApp.router(
            theme: EchoTheme.darkTheme,
            darkTheme: EchoTheme.darkTheme,
            themeMode: ThemeMode.dark,
            routerConfig: router,
          ),
        ),
      );

      await tester.pump();
      await tester.pump();

      await tester.tap(find.text('Log in to join'));
      await tester.pumpAndSettle();

      expect(find.text('LOGIN_SCREEN'), findsOneWidget);
    });

    // -------------------------------------------------------------------
    // Happy path: preview parsing exercises the nested `group:` object.
    // Regression guard for the bug where the client read top-level keys
    // (`name`, `description`, `member_count`) and rendered "Unknown Group"
    // + 0 members + no description for every real invite.
    // -------------------------------------------------------------------
    testWidgets(
      'preview renders group title, description, and member count from the '
      'nested `group` object',
      (tester) async {
        final mockClient = MockHttpClient();
        _stubPreview(
          mockClient,
          body: _previewJson(
            title: 'Echo Hackers',
            description: 'Folks who build messengers.',
            memberCount: 17,
          ),
        );

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          // initState post-frame callback + preview resolve.
          await tester.pump();
          await tester.pump();

          expect(find.text('Echo Hackers'), findsOneWidget);
          expect(find.text('Folks who build messengers.'), findsOneWidget);
          // The preview scaffold renders "17 members" (plural).
          expect(find.textContaining('17 members'), findsOneWidget);
          // "Unknown Group" never appears once the nested parse works.
          expect(find.text('Unknown Group'), findsNothing);
        }, () => mockClient);
      },
    );

    testWidgets(
      'preview falls back to "Unknown Group" when `group` is absent',
      (tester) async {
        final mockClient = MockHttpClient();
        // Malformed server response with no `group` key — defensive fallback
        // should still render the screen instead of crashing.
        _stubPreview(mockClient, body: const {'token': _kToken});

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          await tester.pump();
          await tester.pump();

          expect(find.text('Unknown Group'), findsOneWidget);
        }, () => mockClient);
      },
    );

    // -------------------------------------------------------------------
    // Happy path: accept response detects `status: "already_member"`.
    // Regression guard for the bug where the client read a non-existent
    // `already_member: bool` field and always toasted "Joined!" even when
    // the user was already a member.
    // -------------------------------------------------------------------
    testWidgets(
      'accept response with status=already_member toasts the right copy',
      (tester) async {
        // Preview says non-member so the Join button is rendered. The race
        // we're testing: user taps Join, but a concurrent path has already
        // added them — server returns 200 with status=already_member.
        final mockClient = MockHttpClient();
        _stubPreview(
          mockClient,
          body: _previewJson(title: 'Echo Hackers', isMember: false),
        );
        _stubAccept(
          mockClient,
          statusCode: 200,
          body: const {
            'status': 'already_member',
            'conversation_id': _kConversationId,
          },
        );

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          await tester.pump();
          await tester.pump();

          await tester.tap(find.text('Join Group'));
          // Drive past the toast's 3-second auto-dismiss timer so it doesn't
          // leak past teardown. The toast text is still findable while
          // visible — assert before draining.
          await tester.pump();
          await tester.pump();

          // The bug used to show "Joined Echo Hackers successfully!" because
          // the client read a non-existent `already_member: bool` field. With
          // the fix it correctly reads `status == "already_member"` and
          // surfaces the alternate copy.
          expect(
            find.textContaining('already a member of Echo Hackers'),
            findsOneWidget,
          );

          // Drain the toast's 3s auto-dismiss + 2.5s animation timers.
          await tester.pump(const Duration(seconds: 4));
        }, () => mockClient);
      },
    );

    testWidgets(
      'accept response with status=joined toasts joined-successfully',
      (tester) async {
        final mockClient = MockHttpClient();
        _stubPreview(
          mockClient,
          body: _previewJson(title: 'Echo Hackers', isMember: false),
        );
        _stubAccept(
          mockClient,
          statusCode: 200,
          body: const {'status': 'joined', 'conversation_id': _kConversationId},
        );

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          await tester.pump();
          await tester.pump();

          await tester.tap(find.text('Join Group'));
          await tester.pump();
          await tester.pump();

          expect(
            find.textContaining('Joined Echo Hackers successfully'),
            findsOneWidget,
          );

          await tester.pump(const Duration(seconds: 4));
        }, () => mockClient);
      },
    );
  });
}
