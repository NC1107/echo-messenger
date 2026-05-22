import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/message_search_overlay.dart';

import '../helpers/mock_providers.dart';

/// Build a server payload matching what /api/conversations/{id}/search returns.
String _payload(List<Map<String, dynamic>> messages) => jsonEncode(messages);

Map<String, dynamic> _msg({
  required String id,
  required String content,
  String username = 'alice',
  String? createdAt,
}) => {
  'message_id': id,
  'conversation_id': 'conv-1',
  'sender_id': 'user-alice',
  'sender_username': username,
  'content': content,
  'created_at': createdAt ?? '2026-01-15T10:30:00Z',
};

Widget _wrap({
  required ValueChanged<String> onMessageSelected,
  required VoidCallback onClose,
  String conversationId = 'conv-1',
}) {
  return ProviderScope(
    overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(
        body: MessageSearchOverlay(
          conversationId: conversationId,
          onMessageSelected: onMessageSelected,
          onClose: onClose,
        ),
      ),
    ),
  );
}

/// Drive the search debounce: the overlay waits 400ms after the last
/// keystroke before calling the server.
Future<void> _flushDebounce(WidgetTester tester) async {
  await tester.pump(const Duration(milliseconds: 450));
  // Let the MockClient future resolve and the setState fire.
  await tester.pump();
  await tester.pump();
}

void main() {
  setUp(() {
    TestWidgetsFlutterBinding.ensureInitialized();
  });

  testWidgets('empty initial state renders text field but no results or '
      'empty-state copy', (tester) async {
    await tester.pumpWidget(_wrap(onMessageSelected: (_) {}, onClose: () {}));
    await tester.pump();

    expect(find.byType(TextField), findsOneWidget);
    expect(find.text('No results found'), findsNothing);
    expect(find.byType(ListView), findsNothing);
  });

  testWidgets('typed query fetches results from the server', (tester) async {
    String? capturedQuery;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'hello');
        await _flushDebounce(tester);

        expect(find.textContaining('hello world'), findsOneWidget);
        expect(find.textContaining('hello there'), findsOneWidget);
      },
      () => MockClient((request) async {
        if (request.url.path.endsWith('/api/conversations/conv-1/search')) {
          capturedQuery = request.url.queryParameters['q'];
          return http.Response(
            _payload([
              _msg(id: 'm1', content: 'hello world'),
              _msg(id: 'm2', content: 'hello there', username: 'bob'),
            ]),
            200,
          );
        }
        return http.Response('not found', 404);
      }),
    );

    expect(capturedQuery, 'hello');
  });

  testWidgets('whitespace-only query does NOT hit the server', (tester) async {
    var requestCount = 0;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), '   ');
        await _flushDebounce(tester);

        expect(find.text('No results found'), findsNothing);
      },
      () => MockClient((request) async {
        requestCount++;
        return http.Response(_payload(const []), 200);
      }),
    );

    expect(requestCount, 0);
  });

  testWidgets('empty result set shows "No results found"', (tester) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'nope');
        await _flushDebounce(tester);

        expect(find.text('No results found'), findsOneWidget);
      },
      () =>
          MockClient((request) async => http.Response(_payload(const []), 200)),
    );
  });

  testWidgets('server error shows the empty-state copy, not a crash', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'boom');
        await _flushDebounce(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('No results found'), findsOneWidget);
      },
      () => MockClient((request) async => http.Response('internal error', 500)),
    );
  });

  testWidgets('network exception is swallowed and shows empty state', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'crash');
        await _flushDebounce(tester);

        expect(tester.takeException(), isNull);
        expect(find.text('No results found'), findsOneWidget);
      },
      () => MockClient((request) {
        throw Exception('network down');
      }),
    );
  });

  testWidgets('tapping a result row fires onMessageSelected with the id', (
    tester,
  ) async {
    String? selectedId;

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (id) => selectedId = id, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'pick');
        await _flushDebounce(tester);

        await tester.tap(find.textContaining('second result'));
        await tester.pump();
      },
      () => MockClient((request) async {
        return http.Response(
          _payload([
            _msg(id: 'm-first', content: 'first result'),
            _msg(id: 'm-second', content: 'second result', username: 'bob'),
          ]),
          200,
        );
      }),
    );

    expect(selectedId, 'm-second');
  });

  testWidgets('Escape key fires onClose', (tester) async {
    var closeCount = 0;
    await tester.pumpWidget(
      _wrap(onMessageSelected: (_) {}, onClose: () => closeCount++),
    );

    // Give the KeyboardListener's FocusNode time to claim focus.
    await tester.pump();
    final focusNode = tester
        .widgetList<KeyboardListener>(find.byType(KeyboardListener))
        .first
        .focusNode;
    focusNode.requestFocus();
    await tester.pump();

    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pump();

    expect(closeCount, 1);
  });

  testWidgets('close button (X icon) fires onClose', (tester) async {
    var closeCount = 0;
    await tester.pumpWidget(
      _wrap(onMessageSelected: (_) {}, onClose: () => closeCount++),
    );
    await tester.pump();

    await tester.tap(find.byTooltip('Close search'));
    await tester.pump();

    expect(closeCount, 1);
  });

  testWidgets('clear (X) button only appears once a query has results', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        // Before any query: only the close button (tooltip "Close search").
        expect(find.byIcon(Icons.clear), findsNothing);

        await tester.enterText(find.byType(TextField), 'hello');
        await _flushDebounce(tester);

        // After the search resolves, the clear icon appears.
        expect(find.byIcon(Icons.clear), findsOneWidget);
      },
      () => MockClient((request) async {
        return http.Response(
          _payload([_msg(id: 'm1', content: 'hello world')]),
          200,
        );
      }),
    );
  });

  testWidgets('clear button wipes results and the empty-state copy', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'hello');
        await _flushDebounce(tester);
        expect(find.textContaining('hello world'), findsOneWidget);

        await tester.tap(find.byIcon(Icons.clear));
        await tester.pump();

        expect(find.textContaining('hello world'), findsNothing);
        expect(find.text('No results found'), findsNothing);
      },
      () => MockClient((request) async {
        return http.Response(
          _payload([_msg(id: 'm1', content: 'hello world')]),
          200,
        );
      }),
    );
  });

  testWidgets('debounce coalesces rapid keystrokes into a single request', (
    tester,
  ) async {
    var requestCount = 0;
    final queries = <String>[];

    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        // Three keystrokes within the 400ms window.
        await tester.enterText(find.byType(TextField), 'h');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(find.byType(TextField), 'he');
        await tester.pump(const Duration(milliseconds: 100));
        await tester.enterText(find.byType(TextField), 'hel');
        await _flushDebounce(tester);
      },
      () => MockClient((request) async {
        requestCount++;
        queries.add(request.url.queryParameters['q'] ?? '');
        return http.Response(_payload(const []), 200);
      }),
    );

    expect(requestCount, 1);
    expect(queries.single, 'hel');
  });

  testWidgets('results are sorted by fuzzy score (closer match wins)', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'cat');
        await _flushDebounce(tester);

        // Both messages match in some way; the exact-substring "cat" should
        // out-rank the scattered "c...a...t" match in "concatenate".
        final exactFinder = find.textContaining('cat sat');
        final scatteredFinder = find.textContaining('concatenate');
        expect(exactFinder, findsOneWidget);
        expect(scatteredFinder, findsOneWidget);

        final exactY = tester.getTopLeft(exactFinder).dy;
        final scatteredY = tester.getTopLeft(scatteredFinder).dy;
        expect(
          exactY,
          lessThan(scatteredY),
          reason: 'Exact substring match should sort above scattered match',
        );
      },
      () => MockClient((request) async {
        // Server is unsorted — overlay re-sorts client-side by fuzzy score.
        return http.Response(
          _payload([
            _msg(id: 'm-scatter', content: 'concatenate later'),
            _msg(id: 'm-exact', content: 'cat sat on a mat'),
          ]),
          200,
        );
      }),
    );
  });

  testWidgets(
    'long message content is truncated to 80 characters with ellipsis',
    (tester) async {
      final longContent = 'x' * 200; // way past the 80-char cap
      await http.runWithClient(
        () async {
          await tester.pumpWidget(
            _wrap(onMessageSelected: (_) {}, onClose: () {}),
          );

          await tester.enterText(find.byType(TextField), 'xxx');
          await _flushDebounce(tester);

          // The visible row should NOT contain the full 200-char string.
          expect(find.text(longContent), findsNothing);
          // It SHOULD contain the truncated form ending with '...'.
          expect(find.textContaining('...'), findsWidgets);
        },
        () => MockClient((request) async {
          return http.Response(
            _payload([_msg(id: 'm-long', content: longContent)]),
            200,
          );
        }),
      );
    },
  );

  testWidgets('sender username is rendered alongside the content preview', (
    tester,
  ) async {
    await http.runWithClient(
      () async {
        await tester.pumpWidget(
          _wrap(onMessageSelected: (_) {}, onClose: () {}),
        );

        await tester.enterText(find.byType(TextField), 'ping');
        await _flushDebounce(tester);

        expect(find.text('zelda'), findsOneWidget);
        expect(find.textContaining('ping!'), findsOneWidget);
      },
      () => MockClient((request) async {
        return http.Response(
          _payload([_msg(id: 'm1', content: 'ping!', username: 'zelda')]),
          200,
        );
      }),
    );
  });
}
