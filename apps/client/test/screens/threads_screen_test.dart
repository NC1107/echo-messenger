import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/participated_thread.dart';
import 'package:echo_app/src/providers/participated_threads_provider.dart';
import 'package:echo_app/src/screens/threads_screen.dart';
import 'package:echo_app/src/theme/echo_theme.dart';

ParticipatedThread _thread({
  required String id,
  int replies = 1,
  int unread = 0,
  String? preview = 'sample preview',
}) {
  return ParticipatedThread(
    parentMessageId: id,
    conversationId: 'conv-$id',
    parentPreview: preview,
    parentSenderUsername: 'alice',
    replyCount: replies,
    unreadReplyCount: unread,
    lastReplyAt: DateTime.utc(2026, 5, 20, 12, 0),
    lastReplySenderUsername: 'bob',
  );
}

Widget _wrap(Widget child, {required ProviderContainer container}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: child,
    ),
  );
}

ProviderContainer _containerWith(ParticipatedThreadsState seed) {
  final container = ProviderContainer();
  final notifier = container.read(participatedThreadsProvider.notifier);
  notifier.debugSuppressAutoLoad = true;
  notifier.debugSetState(seed);
  return container;
}

void main() {
  testWidgets('renders empty state when no threads', (tester) async {
    final container = _containerWith(const ParticipatedThreadsState());
    addTearDown(container.dispose);
    await tester.pumpWidget(_wrap(const ThreadsScreen(), container: container));
    await tester.pump();
    expect(find.text('Threads'), findsOneWidget); // app bar title
    expect(find.text('No threads yet'), findsOneWidget);
  });

  testWidgets(
    'renders one card per thread and shows unread dot when unread > 0',
    (tester) async {
      final container = _containerWith(
        ParticipatedThreadsState(
          threads: [
            _thread(id: 'a', replies: 3, unread: 2),
            _thread(id: 'b', replies: 1, unread: 0),
          ],
        ),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _wrap(const ThreadsScreen(), container: container),
      );
      await tester.pump();
      // Each card shows its reply count text.
      expect(find.text('3 replies'), findsOneWidget);
      expect(find.text('1 reply'), findsOneWidget);
      // Exactly one unread dot in the tree (only the first card has
      // unread > 0).
      expect(find.byKey(const ValueKey('thread-unread-dot')), findsOneWidget);
    },
  );

  testWidgets(
    'falls back to [Encrypted] when parent preview looks like ciphertext',
    (tester) async {
      // looksEncrypted requires >=20 chars of base64 — produce a long
      // base64-ish string to trip it deterministically.
      const ciphertext =
          'ZmFrZWNpcGhlcnRleHRibG9iZm9ydGVzdGluZ2VuY3J5cHRpb25pY29uZmFsbGJhY2s=';
      final container = _containerWith(
        ParticipatedThreadsState(
          threads: [
            _thread(id: 'enc', preview: ciphertext, replies: 1, unread: 1),
          ],
        ),
      );
      addTearDown(container.dispose);
      await tester.pumpWidget(
        _wrap(const ThreadsScreen(), container: container),
      );
      await tester.pump();
      expect(find.text('[Encrypted]'), findsOneWidget);
      // The raw ciphertext should NOT be rendered anywhere.
      expect(find.text(ciphertext), findsNothing);
    },
  );

  testWidgets('tapping a thread card invokes onOpenThread', (tester) async {
    final container = _containerWith(
      ParticipatedThreadsState(
        threads: [_thread(id: 'tap-me', replies: 2, unread: 1)],
      ),
    );
    addTearDown(container.dispose);
    String? gotConv;
    String? gotParent;
    await tester.pumpWidget(
      _wrap(
        ThreadsScreen(
          onOpenThread: (conv, parent) {
            gotConv = conv;
            gotParent = parent;
          },
        ),
        container: container,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('2 replies'));
    await tester.pump();
    expect(gotConv, 'conv-tap-me');
    expect(gotParent, 'tap-me');
  });
}
