import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/participated_thread.dart';
import 'package:echo_app/src/providers/participated_threads_provider.dart';
import 'package:echo_app/src/theme/echo_theme.dart';
import 'package:echo_app/src/widgets/threads_sidebar_entry.dart';

ParticipatedThread _thread({required int unread}) => ParticipatedThread(
  parentMessageId: 'p$unread',
  conversationId: 'c$unread',
  parentPreview: 'preview',
  parentSenderUsername: 'alice',
  replyCount: 1,
  unreadReplyCount: unread,
  lastReplyAt: DateTime.utc(2026, 5, 20),
  lastReplySenderUsername: 'bob',
);

Widget _wrap(Widget child, {required ProviderContainer container}) {
  return UncontrolledProviderScope(
    container: container,
    child: MaterialApp(
      theme: EchoTheme.darkTheme,
      darkTheme: EchoTheme.darkTheme,
      themeMode: ThemeMode.dark,
      home: Scaffold(body: child),
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
  testWidgets('renders label and no badge when nothing is unread', (
    tester,
  ) async {
    final container = _containerWith(
      ParticipatedThreadsState(threads: [_thread(unread: 0)]),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _wrap(const ThreadsSidebarEntry(), container: container),
    );
    await tester.pump();
    expect(find.text('Threads'), findsOneWidget);
    expect(find.byKey(const ValueKey('threads-sidebar-badge')), findsNothing);
  });

  testWidgets('badge count matches number of threads with unread > 0', (
    tester,
  ) async {
    final container = _containerWith(
      ParticipatedThreadsState(
        threads: [
          _thread(unread: 2),
          _thread(unread: 0),
          _thread(unread: 5),
          _thread(unread: 1),
        ],
      ),
    );
    addTearDown(container.dispose);
    await tester.pumpWidget(
      _wrap(const ThreadsSidebarEntry(), container: container),
    );
    await tester.pump();
    expect(find.byKey(const ValueKey('threads-sidebar-badge')), findsOneWidget);
    // 3 of the 4 threads have unread > 0 — the badge counts threads,
    // not total replies (so 2 + 5 + 1 = 8 must NOT show up).
    expect(find.text('3'), findsOneWidget);
    expect(find.text('8'), findsNothing);
  });

  testWidgets('tap invokes the callback', (tester) async {
    final container = _containerWith(const ParticipatedThreadsState());
    addTearDown(container.dispose);
    var tapped = false;
    await tester.pumpWidget(
      _wrap(
        ThreadsSidebarEntry(onTap: () => tapped = true),
        container: container,
      ),
    );
    await tester.pump();
    await tester.tap(find.text('Threads'));
    expect(tapped, isTrue);
  });
}
