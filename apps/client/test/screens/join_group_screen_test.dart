import 'dart:convert';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/screens/join/join_preview_scaffold.dart';
import 'package:echo_app/src/screens/join_group_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import '../helpers/mock_http_client.dart';
import '../helpers/mock_providers.dart';

const _kGroupId = 'group-abc-123';

GoRouter _buildRouter({String groupId = _kGroupId}) {
  return GoRouter(
    initialLocation: '/join/$groupId',
    routes: [
      GoRoute(
        path: '/join/:groupId',
        builder: (_, state) =>
            JoinGroupScreen(groupId: state.pathParameters['groupId']!),
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

/// Stubs a preview GET response on [mockClient] for the configured group id.
void _stubPreview(
  MockHttpClient mockClient, {
  required Map<String, dynamic> body,
  int statusCode = 200,
}) {
  when(
    () => mockClient.get(
      any(
        that: predicate<Uri>((u) => u.path == '/api/groups/$_kGroupId/preview'),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => http.Response(jsonEncode(body), statusCode));
}

/// Stubs an empty-body GET that returns [statusCode].
void _stubPreviewStatus(MockHttpClient mockClient, int statusCode) {
  when(
    () => mockClient.get(
      any(
        that: predicate<Uri>((u) => u.path == '/api/groups/$_kGroupId/preview'),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenAnswer((_) async => http.Response('', statusCode));
}

void _stubPreviewThrows(MockHttpClient mockClient, Object error) {
  when(
    () => mockClient.get(
      any(
        that: predicate<Uri>((u) => u.path == '/api/groups/$_kGroupId/preview'),
      ),
      headers: any(named: 'headers'),
    ),
  ).thenThrow(error);
}

void _stubJoin(
  MockHttpClient mockClient, {
  int statusCode = 200,
  Map<String, dynamic>? body,
}) {
  when(
    () => mockClient.post(
      any(that: predicate<Uri>((u) => u.path == '/api/groups/$_kGroupId/join')),
      headers: any(named: 'headers'),
      body: any(named: 'body'),
      encoding: any(named: 'encoding'),
    ),
  ).thenAnswer(
    (_) async => http.Response(jsonEncode(body ?? const {}), statusCode),
  );
}

Map<String, dynamic> _previewJson({
  String id = _kGroupId,
  String title = 'Echo Hackers',
  String? description = 'Folks who build messengers in their spare time.',
  String? iconUrl,
  int memberCount = 42,
  bool isMember = false,
  List<Map<String, dynamic>> members = const [],
}) => {
  'id': id,
  'title': title,
  'description': description,
  'icon_url': iconUrl,
  'member_count': memberCount,
  'is_member': isMember,
  'members': members,
};

void main() {
  setUpAll(registerHttpFallbackValues);

  group('JoinGroupScreen', () {
    testWidgets('shows the loading skeleton before the preview resolves', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      // Resolves on a delay so we can observe the loading frame before
      // setState replaces it with the preview card. Resolving (rather than
      // hanging forever) avoids leaving the authenticatedRequest 15s timeout
      // timer pending at the end of the test.
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer(
        (_) => Future<http.Response>.delayed(
          const Duration(seconds: 1),
          () => http.Response(jsonEncode(_previewJson()), 200),
        ),
      );

      await http.runWithClient(() async {
        await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
        // Single pump: post-frame callback fires, network request is in
        // flight, but no setState has happened yet -- so the skeleton is up.
        await tester.pump();

        expect(find.byType(SkeletonCircle), findsOneWidget);
        expect(find.byType(SkeletonRect), findsWidgets);
        // No Join Group button while loading.
        expect(find.text('Join Group'), findsNothing);

        // Drain the pending response so no timers leak past the test.
        await tester.pump(const Duration(seconds: 2));
      }, () => mockClient);
    });

    testWidgets('renders group name, member count and Join button on success', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      _stubPreview(
        mockClient,
        body: _previewJson(
          title: 'Echo Hackers',
          description: 'A small invite-only group.',
          memberCount: 7,
        ),
      );

      await http.runWithClient(() async {
        await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
        // Pump for: post-frame callback -> request -> setState -> rebuild.
        await tester.pump();
        await tester.pump();

        expect(find.text('Echo Hackers'), findsOneWidget);
        expect(find.text('A small invite-only group.'), findsOneWidget);
        expect(find.text('7 members'), findsOneWidget);
        expect(find.text('Join Group'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets('uses singular "member" copy when memberCount == 1', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      _stubPreview(
        mockClient,
        body: _previewJson(title: 'Solo Group', memberCount: 1),
      );

      await http.runWithClient(() async {
        await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
        await tester.pump();
        await tester.pump();

        expect(find.text('1 member'), findsOneWidget);
        expect(find.text('1 members'), findsNothing);
      }, () => mockClient);
    });

    testWidgets(
      'shows "Open Group" instead of "Join Group" when user is already a '
      'member',
      (tester) async {
        final mockClient = MockHttpClient();
        _stubPreview(
          mockClient,
          body: _previewJson(title: 'Already Joined', isMember: true),
        );

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          await tester.pump();
          await tester.pump();

          expect(find.text('Open Group'), findsOneWidget);
          expect(find.text('Join Group'), findsNothing);
        }, () => mockClient);
      },
    );

    testWidgets('renders the 404 invalid card when the group is not found', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      _stubPreviewStatus(mockClient, 404);

      await http.runWithClient(() async {
        await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
        await tester.pump();
        await tester.pump();

        expect(find.text('Group not found'), findsOneWidget);
        expect(find.textContaining('invite link is invalid'), findsOneWidget);
        // No Join Group button on the invalid card.
        expect(find.text('Join Group'), findsNothing);
      }, () => mockClient);
    });

    testWidgets(
      'shows a generic error chip on 500 but still renders the join button',
      (tester) async {
        final mockClient = MockHttpClient();
        _stubPreviewStatus(mockClient, 500);

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          await tester.pump();
          await tester.pump();

          // On non-404 errors, the screen falls back to the preview card
          // (preview is null, name reverts to the "Group Invite" placeholder)
          // and the error string is surfaced via the _ErrorChip.
          expect(find.text('Group Invite'), findsOneWidget);
          expect(
            find.text('Could not load group information.'),
            findsOneWidget,
          );
        }, () => mockClient);
      },
    );

    testWidgets('shows network-error copy when the preview request throws', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      _stubPreviewThrows(mockClient, Exception('socket down'));

      await http.runWithClient(() async {
        await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
        await tester.pump();
        await tester.pump();

        expect(find.text('Could not reach the server.'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets(
      'logged-out user sees "Log in to join" without firing a preview request',
      (tester) async {
        final mockClient = MockHttpClient();
        // Stub anyway so an accidental call would be observable.
        _stubPreview(mockClient, body: _previewJson());

        await http.runWithClient(() async {
          await tester.pumpWidget(
            _wrap(
              _buildRouter(),
              standardOverrides(authState: const AuthState()),
            ),
          );
          await tester.pump();
          await tester.pump();

          expect(find.text('Log in to join'), findsOneWidget);
        }, () => mockClient);

        verifyNever(
          () => mockClient.get(any(), headers: any(named: 'headers')),
        );
      },
    );

    testWidgets('"Log in to join" tap navigates to the /login route', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      _stubPreview(mockClient, body: _previewJson());

      await http.runWithClient(() async {
        await tester.pumpWidget(
          _wrap(
            _buildRouter(),
            standardOverrides(authState: const AuthState()),
          ),
        );
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Log in to join'));
        await tester.pumpAndSettle();

        expect(find.text('LOGIN_SCREEN'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets('"Cancel" tap on the invalid card returns to /home', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      _stubPreviewStatus(mockClient, 404);

      await http.runWithClient(() async {
        await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
        await tester.pump();
        await tester.pump();

        // Logged-in user on the invalid card sees a "Back to chats" button.
        await tester.tap(find.text('Back to chats'));
        await tester.pumpAndSettle();

        expect(find.text('HOME_SCREEN'), findsOneWidget);
      }, () => mockClient);
    });

    testWidgets(
      'tapping Join Group posts to /api/groups/:id/join and navigates home',
      (tester) async {
        final mockClient = MockHttpClient();
        _stubPreview(mockClient, body: _previewJson(title: 'Echo Hackers'));
        _stubJoin(mockClient, statusCode: 200);

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          await tester.pump();
          await tester.pump();

          expect(find.text('Join Group'), findsOneWidget);

          await tester.tap(find.text('Join Group'));
          // Pump frames for: button onTap -> async POST -> setState ->
          // context.go('/home').
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));
          // Don't pumpAndSettle -- the success toast schedules a 3s dismiss
          // timer that would never settle. Pump a few frames to flush the
          // GoRouter transition, then drain the toast timer below.
          await tester.pump(const Duration(milliseconds: 400));

          expect(find.text('HOME_SCREEN'), findsOneWidget);

          // Drain the toast dismiss-timer so no Timer leaks past teardown.
          await tester.pump(const Duration(seconds: 4));
        }, () => mockClient);

        verify(
          () => mockClient.post(
            any(
              that: predicate<Uri>(
                (u) => u.path == '/api/groups/$_kGroupId/join',
              ),
            ),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).called(1);
      },
    );

    testWidgets(
      'a failed join surfaces the server-provided error message in an error '
      'chip and keeps the user on the screen',
      (tester) async {
        final mockClient = MockHttpClient();
        _stubPreview(mockClient, body: _previewJson(title: 'Echo Hackers'));
        _stubJoin(
          mockClient,
          statusCode: 403,
          body: const {'error': 'Group is full'},
        );

        await http.runWithClient(() async {
          await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
          await tester.pump();
          await tester.pump();

          await tester.tap(find.text('Join Group'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 50));

          // Still on the join screen; error chip shows the server message.
          expect(find.text('Group is full'), findsOneWidget);
          expect(find.text('Echo Hackers'), findsOneWidget);
          expect(find.text('HOME_SCREEN'), findsNothing);
        }, () => mockClient);
      },
    );

    testWidgets('a thrown join error surfaces the generic network copy', (
      tester,
    ) async {
      final mockClient = MockHttpClient();
      _stubPreview(mockClient, body: _previewJson(title: 'Echo Hackers'));
      when(
        () => mockClient.post(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/groups/$_kGroupId/join',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(Exception('boom'));

      await http.runWithClient(() async {
        await tester.pumpWidget(_wrap(_buildRouter(), standardOverrides()));
        await tester.pump();
        await tester.pump();

        await tester.tap(find.text('Join Group'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 50));

        expect(find.text('Network error. Please try again.'), findsOneWidget);
        expect(find.text('HOME_SCREEN'), findsNothing);
      }, () => mockClient);
    });
  });
}
