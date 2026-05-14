import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/global_search_overlay.dart';

/// Mock-response payload for /api/search: three messages, no contacts, no
/// groups. Keeps the test stable across categories without depending on the
/// real server.
String _searchPayload() => jsonEncode({
  'messages': [
    {
      'message_id': 'm1',
      'conversation_id': 'c1',
      'sender_username': 'alice',
      'content': 'hello world',
      'created_at': DateTime.now().toIso8601String(),
    },
    {
      'message_id': 'm2',
      'conversation_id': 'c2',
      'sender_username': 'bob',
      'content': 'hello there',
      'created_at': DateTime.now().toIso8601String(),
    },
    {
      'message_id': 'm3',
      'conversation_id': 'c3',
      'sender_username': 'carol',
      'content': 'hello again',
      'created_at': DateTime.now().toIso8601String(),
    },
  ],
  'contacts': const [],
  'groups': const [],
});

Widget _wrap({
  required void Function(String convId, String msgId) onResultTap,
  required void Function(String userId, String username) onContactTap,
}) {
  return ProviderScope(
    overrides: [
      authProvider.overrideWith((ref) {
        final n = AuthNotifier(ref);
        n.state = const AuthState(
          isLoggedIn: true,
          userId: 'me',
          username: 'me',
          token: 'fake-jwt',
          refreshToken: 'refresh',
        );
        return n;
      }),
      serverUrlProvider.overrideWith((ref) {
        final n = ServerUrlNotifier();
        n.state = 'http://localhost:8080';
        return n;
      }),
    ],
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: GlobalSearchOverlay(
          onResultTap: onResultTap,
          onContactTap: onContactTap,
        ),
      ),
    ),
  );
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues({});
  });

  testWidgets('arrow keys move selection and enter triggers tap (#403)', (
    tester,
  ) async {
    String? tappedConv;
    String? tappedMsg;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(
            onResultTap: (c, m) {
              tappedConv = c;
              tappedMsg = m;
            },
            onContactTap: (_, _) {},
          ),
        );

        // Type a 3-char query so the debounce fires.
        await tester.enterText(find.byType(TextField), 'hel');
        // Wait past the 400ms debounce + http mock response.
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump();

        // First message ("hello world") should be visible and selected.
        expect(find.textContaining('hello world'), findsOneWidget);

        // Arrow-down twice → third message.
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
        await tester.pump();

        // Arrow-up once → second message ("hello there", id m2 / conv c2).
        await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
        await tester.pump();

        // Enter activates m2.
        await tester.sendKeyEvent(LogicalKeyboardKey.enter);
        await tester.pump();

        expect(tappedConv, 'c2');
        expect(tappedMsg, 'm2');
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('/api/search')) {
          return http.Response(_searchPayload(), 200);
        }
        return http.Response('not found', 404);
      }),
    );
  });

  testWidgets('arrow-down clamps at the last result (#403)', (tester) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onResultTap: (_, _) {}, onContactTap: (_, _) {}),
        );

        await tester.enterText(find.byType(TextField), 'hel');
        await tester.pump(const Duration(milliseconds: 450));
        await tester.pump();

        // Press arrow-down many times — must not crash, must stay in range.
        for (var i = 0; i < 10; i++) {
          await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
          await tester.pump();
        }
        expect(tester.takeException(), isNull);
      },
      () => MockClient((request) async {
        return http.Response(_searchPayload(), 200);
      }),
    );
  });

  testWidgets('escape closes the overlay (#403)', (tester) async {
    await tester.pumpWidget(
      MaterialApp(
        theme: EchoTheme.darkTheme,
        darkTheme: EchoTheme.darkTheme,
        themeMode: ThemeMode.dark,
        home: Builder(
          builder: (context) {
            return Scaffold(
              body: Center(
                child: ElevatedButton(
                  onPressed: () {
                    showDialog<void>(
                      context: context,
                      builder: (_) => ProviderScope(
                        overrides: [
                          authProvider.overrideWith((ref) {
                            final n = AuthNotifier(ref);
                            n.state = const AuthState(
                              isLoggedIn: true,
                              userId: 'me',
                              username: 'me',
                              token: 'fake-jwt',
                              refreshToken: 'refresh',
                            );
                            return n;
                          }),
                          serverUrlProvider.overrideWith((ref) {
                            final n = ServerUrlNotifier();
                            n.state = 'http://localhost:8080';
                            return n;
                          }),
                        ],
                        child: GlobalSearchOverlay(
                          onResultTap: (_, _) {},
                          onContactTap: (_, _) {},
                        ),
                      ),
                    );
                  },
                  child: const Text('open'),
                ),
              ),
            );
          },
        ),
      ),
    );

    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.byType(GlobalSearchOverlay), findsOneWidget);

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();

    expect(find.byType(GlobalSearchOverlay), findsNothing);
  });
}
