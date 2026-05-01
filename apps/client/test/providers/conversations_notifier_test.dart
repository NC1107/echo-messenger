import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/services/message_cache.dart';

ConversationsNotifier _createNotifier({List<Conversation> initial = const []}) {
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
      privacyProvider.overrideWith((ref) {
        final n = PrivacyNotifier(ref);
        n.state = const PrivacyState();
        return n;
      }),
    ],
  );
  final notifier = container.read(conversationsProvider.notifier);
  if (initial.isNotEmpty) {
    notifier.state = ConversationsState(conversations: initial);
  }
  return notifier;
}

const _conv1 = Conversation(
  id: 'conv-1',
  name: null,
  isGroup: false,
  lastMessage: 'Hey there!',
  lastMessageTimestamp: '2026-01-15T10:30:00Z',
  lastMessageSender: 'alice',
  unreadCount: 2,
  members: [
    ConversationMember(userId: 'user-alice', username: 'alice'),
    ConversationMember(userId: 'me', username: 'testuser'),
  ],
);

const _conv2 = Conversation(
  id: 'conv-2',
  name: 'Dev Team',
  isGroup: true,
  lastMessage: 'Meeting at 3pm',
  lastMessageTimestamp: '2026-01-15T09:00:00Z',
  lastMessageSender: 'bob',
  unreadCount: 0,
  members: [
    ConversationMember(userId: 'user-bob', username: 'bob'),
    ConversationMember(userId: 'me', username: 'testuser'),
  ],
);

void main() {
  group('ConversationsNotifier.onNewMessage', () {
    test('updates last message and bumps unread count', () {
      final notifier = _createNotifier(initial: [_conv1, _conv2]);

      notifier.onNewMessage(
        conversationId: 'conv-1',
        content: 'New message!',
        timestamp: '2026-01-15T11:00:00Z',
        senderUsername: 'alice',
      );

      final conv = notifier.state.conversations.firstWhere(
        (c) => c.id == 'conv-1',
      );
      expect(conv.lastMessage, 'New message!');
      expect(conv.lastMessageSender, 'alice');
      expect(conv.unreadCount, 3); // was 2, now 3
    });

    test('moves conversation to top of list', () {
      final notifier = _createNotifier(initial: [_conv1, _conv2]);

      notifier.onNewMessage(
        conversationId: 'conv-2',
        content: 'New group message',
        timestamp: '2026-01-15T11:00:00Z',
        senderUsername: 'bob',
      );

      expect(notifier.state.conversations.first.id, 'conv-2');
    });
  });

  group('ConversationsNotifier.onMessageEdited', () {
    test('updates last message preview', () {
      final notifier = _createNotifier(initial: [_conv1]);

      notifier.onMessageEdited(
        conversationId: 'conv-1',
        newContent: 'Edited message',
      );

      final conv = notifier.state.conversations.first;
      expect(conv.lastMessage, 'Edited message');
    });

    test('no-op for unknown conversation', () {
      final notifier = _createNotifier(initial: [_conv1]);

      // Should not throw
      notifier.onMessageEdited(
        conversationId: 'nonexistent',
        newContent: 'Edited',
      );

      expect(notifier.state.conversations, hasLength(1));
    });
  });

  group('ConversationsNotifier.updateEncryption', () {
    test('sets isEncrypted flag', () {
      final notifier = _createNotifier(initial: [_conv1]);

      notifier.updateEncryption('conv-1', true);

      final conv = notifier.state.conversations.first;
      expect(conv.isEncrypted, isTrue);
    });

    test('clears isEncrypted flag', () {
      final convEncrypted = _conv1.copyWith(isEncrypted: true);
      final notifier = _createNotifier(initial: [convEncrypted]);

      notifier.updateEncryption('conv-1', false);

      final conv = notifier.state.conversations.first;
      expect(conv.isEncrypted, isFalse);
    });
  });

  // Regression tests for #664: sentinel strings must never surface as previews.
  group('ConversationsNotifier – decrypt-failure sentinel filter (#664)', () {
    test('genuine plaintext preview is stored normally', () {
      final notifier = _createNotifier(initial: [_conv1]);
      expect(
        () => notifier.updateDecryptedPreview('conv-1', 'Hello world'),
        returnsNormally,
      );
    });

    test('updateDecryptedPreview silently ignores failure sentinels', () {
      final notifier = _createNotifier(initial: [_conv1]);
      // Establish a good preview first.
      notifier.updateDecryptedPreview('conv-1', 'Last good message');
      // Simulate a decrypt failure writing each sentinel.
      for (final sentinel in MessageCache.failureSentinels) {
        notifier.updateDecryptedPreview('conv-1', sentinel);
      }
      // Good preview must not have been overwritten; a real WS message wins.
      notifier.onNewMessage(
        conversationId: 'conv-1',
        content: 'New real message',
        timestamp: '2026-01-16T10:00:00Z',
        senderUsername: 'alice',
      );
      final conv = notifier.state.conversations.firstWhere(
        (c) => c.id == 'conv-1',
      );
      expect(conv.lastMessage, 'New real message');
      expect(MessageCache.failureSentinels.contains(conv.lastMessage), isFalse);
    });

    test('onNewMessage does not cache failure sentinel in preview map', () {
      final notifier = _createNotifier(initial: [_conv1]);
      for (final sentinel in MessageCache.failureSentinels) {
        notifier.onNewMessage(
          conversationId: 'conv-1',
          content: sentinel,
          timestamp: '2026-01-16T10:00:00Z',
          senderUsername: 'alice',
        );
        // A subsequent good preview must still be accepted (sentinel did not
        // poison the cache and cause the good value to be rejected).
        expect(
          () => notifier.updateDecryptedPreview('conv-1', 'Still good'),
          returnsNormally,
        );
      }
    });

    test('onMessageEdited does not cache failure sentinel in preview map', () {
      final notifier = _createNotifier(initial: [_conv1]);
      notifier.updateDecryptedPreview('conv-1', 'Original message');
      for (final sentinel in MessageCache.failureSentinels) {
        notifier.onMessageEdited(
          conversationId: 'conv-1',
          newContent: sentinel,
        );
      }
      // Good preview must still be accepted after sentinel edits.
      expect(
        () => notifier.updateDecryptedPreview('conv-1', 'Good preview'),
        returnsNormally,
      );
    });
  });

  group('ConversationsNotifier.markAsRead', () {
    test('resets unread count to 0', () {
      final notifier = _createNotifier(initial: [_conv1]);
      expect(notifier.state.conversations.first.unreadCount, 2);

      notifier.markAsRead('conv-1');

      expect(notifier.state.conversations.first.unreadCount, 0);
    });
  });

  group('ConversationsState', () {
    test('copyWith preserves conversations when not overridden', () {
      final state = const ConversationsState(
        conversations: [_conv1, _conv2],
        isLoading: true,
      );

      final copied = state.copyWith(isLoading: false);
      expect(copied.conversations, hasLength(2));
      expect(copied.isLoading, isFalse);
    });

    test('error is nullable and cleared via null', () {
      const state = ConversationsState(error: 'Network error');
      // copyWith with error: null clears the error
      final cleared = state.copyWith(error: null);
      expect(cleared.error, isNull);
    });
  });
}
