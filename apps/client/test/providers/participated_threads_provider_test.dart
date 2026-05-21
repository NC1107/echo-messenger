import 'dart:async';
import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:echo_app/src/models/participated_thread.dart';
import 'package:echo_app/src/providers/participated_threads_provider.dart';

class _StubHttpClient extends Mock implements http.Client {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uri());
  });

  group('ParticipatedThreads', () {
    test('parses a server response and populates unread badge count', () async {
      final stub = _StubHttpClient();
      final body = jsonEncode([
        {
          'parent_message_id': 'parent-1',
          'conversation_id': 'conv-a',
          'channel_id': null,
          'parent_preview': 'anyone seen the build?',
          'parent_sender_username': 'alice',
          'reply_count': 3,
          'unread_reply_count': 2,
          'last_reply_at': '2026-05-20T12:34:56Z',
          'last_reply_sender_username': 'bob',
        },
        {
          'parent_message_id': 'parent-2',
          'conversation_id': 'conv-b',
          'channel_id': 'chan-x',
          'parent_preview': 'thanks all',
          'parent_sender_username': 'carol',
          'reply_count': 1,
          'unread_reply_count': 0,
          'last_reply_at': '2026-05-19T08:00:00Z',
          'last_reply_sender_username': 'alice',
        },
      ]);
      when(
        () => stub.get(any()),
      ).thenAnswer((_) async => http.Response(body, 200));

      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(participatedThreadsProvider.notifier);
      notifier.debugHttpClientOverride = stub;

      await notifier.load();
      final state = container.read(participatedThreadsProvider);

      expect(state.threads, hasLength(2));
      expect(state.threads.first.parentMessageId, 'parent-1');
      expect(state.threads.first.replyCount, 3);
      expect(state.threads.first.unreadReplyCount, 2);
      expect(state.threads.first.lastReplyAt.toUtc().hour, 12);
      // Sidebar badge counts threads with unread > 0 — exactly one here.
      expect(state.unreadThreadCount, 1);
    });

    test('surfaces an error on non-200 and leaves prior state alone', () async {
      final stub = _StubHttpClient();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(participatedThreadsProvider.notifier);
      notifier.debugHttpClientOverride = stub;

      // Seed with a prior thread so we can confirm error doesn't wipe it.
      notifier.debugSetState(
        ParticipatedThreadsState(
          threads: [
            ParticipatedThread(
              parentMessageId: 'p',
              conversationId: 'c',
              replyCount: 1,
              unreadReplyCount: 0,
              lastReplyAt: DateTime.utc(2026, 5, 20),
            ),
          ],
        ),
      );

      when(
        () => stub.get(any()),
      ).thenAnswer((_) async => http.Response('boom', 500));
      await notifier.load();
      final state = container.read(participatedThreadsProvider);
      expect(state.error, isNotNull);
      expect(state.threads, hasLength(1));
      expect(state.threads.single.parentMessageId, 'p');
    });

    test('refresh swallows errors and keeps last good state', () async {
      final stub = _StubHttpClient();
      final container = ProviderContainer();
      addTearDown(container.dispose);
      final notifier = container.read(participatedThreadsProvider.notifier);
      notifier.debugHttpClientOverride = stub;

      notifier.debugSetState(
        ParticipatedThreadsState(
          threads: [
            ParticipatedThread(
              parentMessageId: 'p',
              conversationId: 'c',
              replyCount: 1,
              unreadReplyCount: 1,
              lastReplyAt: DateTime.utc(2026, 5, 20),
            ),
          ],
        ),
      );
      when(() => stub.get(any())).thenThrow(TimeoutException('slow'));
      await notifier.refresh();
      final state = container.read(participatedThreadsProvider);
      // Error is not surfaced (refresh is silent) and threads survive.
      expect(state.error, isNull);
      expect(state.threads, hasLength(1));
      expect(state.unreadThreadCount, 1);
    });
  });
}
