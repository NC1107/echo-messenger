import 'package:fake_async/fake_async.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

/// Create a [ProviderContainer] with overrides for auth + server URL so
/// [ChatNotifier] can be instantiated without hitting the network.
ProviderContainer _createContainer() {
  return ProviderContainer(
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
}

void main() {
  group('ChatNotifier send-timeout timer', () {
    test('pending message transitions to failed after 15s timeout', () {
      fakeAsync((async) {
        final container = _createContainer();
        final notifier = container.read(chatProvider.notifier);

        notifier.addOptimistic(
          'peer-1',
          'hello world',
          'me',
          conversationId: 'conv-1',
        );

        // Immediately after adding, should be in sending state.
        final beforeMsgs = container
            .read(chatProvider)
            .messagesForConversation('conv-1');
        expect(beforeMsgs, hasLength(1));
        expect(beforeMsgs.first.status, MessageStatus.sending);
        expect(beforeMsgs.first.id, startsWith('pending_'));

        // Advance just under the 15s threshold — still sending.
        async.elapse(const Duration(seconds: 14));
        final midMsgs = container
            .read(chatProvider)
            .messagesForConversation('conv-1');
        expect(midMsgs.first.status, MessageStatus.sending);

        // Advance past 15s — should be failed now.
        async.elapse(const Duration(seconds: 2));
        final afterMsgs = container
            .read(chatProvider)
            .messagesForConversation('conv-1');
        expect(afterMsgs, hasLength(1));
        expect(afterMsgs.first.status, MessageStatus.failed);
        // Original content preserved in failedContent for retry.
        expect(afterMsgs.first.failedContent, 'hello world');
        // User-facing content is the timeout message.
        expect(
          afterMsgs.first.content,
          contains('may not have been delivered'),
        );
      });
    });

    test('confirmSent cancels the 15s timer — message stays sent', () {
      fakeAsync((async) {
        final container = _createContainer();
        addTearDown(container.dispose);
        final notifier = container.read(chatProvider.notifier);

        notifier.addOptimistic(
          'peer-1',
          'confirmed message',
          'me',
          conversationId: 'conv-1',
        );

        // Confirm immediately (server echoed the message back).
        notifier.confirmSent('server-msg-1', 'conv-1', '2026-01-01T12:00:00Z');

        final confirmedMsgs = container
            .read(chatProvider)
            .messagesForConversation('conv-1');
        expect(confirmedMsgs, hasLength(1));
        expect(confirmedMsgs.first.id, 'server-msg-1');
        expect(confirmedMsgs.first.status, MessageStatus.sent);

        // Advance well past 15s — should NOT transition to failed.
        async.elapse(const Duration(seconds: 20));

        final afterMsgs = container
            .read(chatProvider)
            .messagesForConversation('conv-1');
        expect(afterMsgs, hasLength(1));
        expect(afterMsgs.first.status, MessageStatus.sent);
        expect(afterMsgs.first.id, 'server-msg-1');
      });
    });

    test('clearConversation cancels pending send timers', () {
      fakeAsync((async) {
        final container = _createContainer();
        final notifier = container.read(chatProvider.notifier);

        notifier.addOptimistic(
          'peer-1',
          'message 1',
          'me',
          conversationId: 'conv-1',
        );

        // Clear the conversation before the timer fires.
        notifier.clearConversation('conv-1');

        // Conversation should be empty.
        expect(
          container.read(chatProvider).messagesForConversation('conv-1'),
          isEmpty,
        );

        // Advance past 15s — should NOT crash or re-add a failed message.
        async.elapse(const Duration(seconds: 20));

        // Still empty — the timer was cancelled and didn't fire.
        expect(
          container.read(chatProvider).messagesForConversation('conv-1'),
          isEmpty,
        );

        container.dispose();
      });
    });

    test('confirmSent for one conversation does not affect another', () async {
      // This test does NOT use fakeAsync because addOptimistic generates
      // pending IDs from DateTime.now().millisecondsSinceEpoch which is
      // real wall-clock time (not controlled by fakeAsync). We need distinct
      // IDs across conversations, so we insert a small real delay.
      final container = _createContainer();
      addTearDown(container.dispose);
      final notifier = container.read(chatProvider.notifier);

      notifier.addOptimistic(
        'peer-1',
        'conv1 message',
        'me',
        conversationId: 'conv-1',
      );
      // 2ms real delay ensures a distinct pending ID.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      notifier.addOptimistic(
        'peer-2',
        'conv2 message',
        'me',
        conversationId: 'conv-2',
      );

      // Both conversations should have exactly one pending message.
      expect(
        container.read(chatProvider).messagesForConversation('conv-1'),
        hasLength(1),
      );
      expect(
        container.read(chatProvider).messagesForConversation('conv-2'),
        hasLength(1),
      );

      // Confirm conv-2's message.
      notifier.confirmSent('server-2', 'conv-2', '2026-01-01T12:00:00Z');

      // conv-2 should now be confirmed (sent).
      final conv2 = container
          .read(chatProvider)
          .messagesForConversation('conv-2');
      expect(conv2, hasLength(1));
      expect(conv2.first.id, 'server-2');
      expect(conv2.first.status, MessageStatus.sent);

      // conv-1 should still be pending (sending) — confirming conv-2 did
      // NOT cancel conv-1's timer or change conv-1's state.
      final conv1 = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(conv1, hasLength(1));
      expect(conv1.first.status, MessageStatus.sending);
      expect(conv1.first.id, startsWith('pending_'));
    });
  });
}
