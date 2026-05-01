import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/services/message_cache.dart';

/// Creates a fresh [ChatNotifier] (empty state, no WS events) to simulate a
/// cold-start scenario where the user has not yet opened any chat panel.
ChatNotifier _createNotifier() {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) {
        final n = AuthNotifier(ref);
        n.state = const AuthState(
          isLoggedIn: true,
          userId: 'me',
          username: 'testuser',
          token: 'fake-token',
        );
        return n;
      }),
      serverUrlProvider.overrideWith((ref) {
        final n = ServerUrlNotifier();
        n.state = 'http://localhost:8080';
        return n;
      }),
    ],
  );
  return container.read(chatProvider.notifier);
}

void main() {
  late Directory tempDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    tempDir = await Directory.systemTemp.createTemp('chat_cold_start_test_');
    Hive.init(tempDir.path);
    await MessageCache.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await tempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() async {
    await MessageCache.clearAll();
    await MessageCache.initForUser('me', 'localhost');
  });

  group('ChatNotifier.hydrateStatusFromCache (#573)', () {
    test(
      'cold-start: read tick is shown for own last message with status=read',
      () async {
        const convId = 'conv-hydrate-1';
        const myUserId = 'me';

        // Seed Hive with a read own message as the most recent in the conv.
        final readMsg = const ChatMessage(
          id: 'msg-read',
          fromUserId: myUserId,
          fromUsername: 'testuser',
          conversationId: convId,
          content: 'Hey there',
          timestamp: '2026-01-01T12:00:00Z',
          isMine: true,
          status: MessageStatus.read,
        );
        await MessageCache.cacheMessages(convId, [readMsg]);

        // Cold-start: notifier has no in-memory state for this conversation.
        final notifier = _createNotifier();
        expect(
          notifier.state.messagesByConversation.containsKey(convId),
          isFalse,
          reason: 'pre-condition: conv not yet in memory',
        );

        // Run hydration (simulates what loadConversations triggers on login).
        await notifier.hydrateStatusFromCache([convId], myUserId);

        // The last (and only) message for this conv should now be in memory.
        final messages = notifier.state.messagesByConversation[convId];
        expect(messages, isNotNull, reason: 'conv should be hydrated');
        expect(messages, hasLength(1));

        final last = messages!.last;
        expect(last.id, 'msg-read');
        expect(last.isMine, isTrue);
        // Key assertion: status survived the Hive round-trip.
        expect(
          last.status,
          MessageStatus.read,
          reason: 'read tick must be preserved from Hive cache on cold start',
        );
      },
    );

    test('cold-start: delivered status is preserved from Hive cache', () async {
      const convId = 'conv-hydrate-2';
      const myUserId = 'me';

      final deliveredMsg = const ChatMessage(
        id: 'msg-delivered',
        fromUserId: myUserId,
        fromUsername: 'testuser',
        conversationId: convId,
        content: 'Delivered message',
        timestamp: '2026-01-01T11:00:00Z',
        isMine: true,
        status: MessageStatus.delivered,
      );
      await MessageCache.cacheMessages(convId, [deliveredMsg]);

      final notifier = _createNotifier();
      await notifier.hydrateStatusFromCache([convId], myUserId);

      final last = notifier.state.messagesByConversation[convId]?.lastOrNull;
      expect(last, isNotNull);
      expect(last!.status, MessageStatus.delivered);
    });

    test(
      'hydration skips conversations already in memory (chat panel open)',
      () async {
        const convId = 'conv-hydrate-3';
        const myUserId = 'me';

        // Seed Hive with a read message.
        final cachedMsg = const ChatMessage(
          id: 'msg-cached',
          fromUserId: myUserId,
          fromUsername: 'testuser',
          conversationId: convId,
          content: 'Cached',
          timestamp: '2026-01-01T09:00:00Z',
          isMine: true,
          status: MessageStatus.read,
        );
        await MessageCache.cacheMessages(convId, [cachedMsg]);

        // Simulate the chat panel being open: inject a live message with
        // a different (lower) status that should not be overwritten.
        final notifier = _createNotifier();
        final liveMsg = const ChatMessage(
          id: 'msg-live',
          fromUserId: myUserId,
          fromUsername: 'testuser',
          conversationId: convId,
          content: 'Live',
          timestamp: '2026-01-01T10:00:00Z',
          isMine: true,
          status: MessageStatus.sent,
        );
        notifier.addMessage(liveMsg);

        // Hydration should not touch this conv because it is already present.
        await notifier.hydrateStatusFromCache([convId], myUserId);

        final messages = notifier.state.messagesByConversation[convId]!;
        // Only the live message should be there -- cache was not merged.
        expect(messages.any((m) => m.id == 'msg-cached'), isFalse);
        expect(messages.any((m) => m.id == 'msg-live'), isTrue);
      },
    );

    test(
      'hydration ignores conversations whose last message is not mine',
      () async {
        const convId = 'conv-hydrate-4';
        const myUserId = 'me';

        // Seed with a peer message (not mine).
        final peerMsg = const ChatMessage(
          id: 'msg-peer',
          fromUserId: 'peer-1',
          fromUsername: 'alice',
          conversationId: convId,
          content: 'Hello',
          timestamp: '2026-01-01T10:00:00Z',
          isMine: false,
          status: MessageStatus.read,
        );
        await MessageCache.cacheMessages(convId, [peerMsg]);

        final notifier = _createNotifier();
        await notifier.hydrateStatusFromCache([convId], myUserId);

        // The tick is only shown for own messages; no state should be added.
        expect(
          notifier.state.messagesByConversation.containsKey(convId),
          isFalse,
          reason: 'peer-only convs should not be hydrated (no tick shown)',
        );
      },
    );
  });
}
