import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

/// Create a real ChatNotifier backed by a ProviderContainer.
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

const _msg1 = ChatMessage(
  id: 'msg-1',
  fromUserId: 'user-1',
  fromUsername: 'alice',
  conversationId: 'conv-1',
  content: 'Hello',
  timestamp: '2026-01-01T10:00:00Z',
  isMine: false,
);

const _msg2 = ChatMessage(
  id: 'msg-2',
  fromUserId: 'me',
  fromUsername: 'testuser',
  conversationId: 'conv-1',
  content: 'Hi there',
  timestamp: '2026-01-01T10:01:00Z',
  isMine: true,
);

void main() {
  group('ChatNotifier.addMessage', () {
    test('adds a message to state', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      expect(notifier.state.messagesForConversation('conv-1'), hasLength(1));
      expect(
        notifier.state.messagesForConversation('conv-1').first.content,
        'Hello',
      );
    });

    test('deduplicates messages by ID', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);
      notifier.addMessage(_msg1);

      expect(notifier.state.messagesForConversation('conv-1'), hasLength(1));
    });

    test('adds multiple messages to same conversation', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);
      notifier.addMessage(_msg2);

      expect(notifier.state.messagesForConversation('conv-1'), hasLength(2));
    });

    test('adds messages to different conversations', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      const msg3 = ChatMessage(
        id: 'msg-3',
        fromUserId: 'user-2',
        fromUsername: 'bob',
        conversationId: 'conv-2',
        content: 'Hey',
        timestamp: '2026-01-01T10:02:00Z',
        isMine: false,
      );
      notifier.addMessage(msg3);

      expect(notifier.state.messagesForConversation('conv-1'), hasLength(1));
      expect(notifier.state.messagesForConversation('conv-2'), hasLength(1));
    });
  });

  group('ChatNotifier.addSystemEvent', () {
    test('adds a system event message', () {
      final notifier = _createNotifier();
      notifier.addSystemEvent('conv-1', 'alice reset encryption keys');

      final msgs = notifier.state.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.isSystemEvent, isTrue);
      expect(msgs.first.content, 'alice reset encryption keys');
      expect(msgs.first.fromUserId, ChatMessage.systemUserId);
    });

    test('deduplicates consecutive identical system events', () {
      final notifier = _createNotifier();
      notifier.addSystemEvent('conv-1', 'alice joined the group');
      notifier.addSystemEvent('conv-1', 'alice joined the group');

      expect(notifier.state.messagesForConversation('conv-1'), hasLength(1));
    });

    test('allows different system events', () async {
      final notifier = _createNotifier();
      notifier.addSystemEvent('conv-1', 'alice joined');
      // Small delay to ensure different millisecond IDs.
      await Future<void>.delayed(const Duration(milliseconds: 2));
      notifier.addSystemEvent('conv-1', 'bob joined');

      expect(notifier.state.messagesForConversation('conv-1'), hasLength(2));
    });
  });

  group('ChatNotifier.setReplyTo / clearReplyTo', () {
    test('setReplyTo sets the reply message', () {
      final notifier = _createNotifier();
      notifier.setReplyTo(_msg1);

      expect(notifier.state.replyToMessage, isNotNull);
      expect(notifier.state.replyToMessage!.id, 'msg-1');
    });

    test('clearReplyTo clears the reply', () {
      final notifier = _createNotifier();
      notifier.setReplyTo(_msg1);
      notifier.clearReplyTo();

      expect(notifier.state.replyToMessage, isNull);
    });
  });

  group('ChatNotifier.addOptimistic', () {
    test('adds a pending message', () {
      final notifier = _createNotifier();
      notifier.addOptimistic(
        'user-1',
        'Sending this',
        'me',
        conversationId: 'conv-1',
      );

      final msgs = notifier.state.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.id, startsWith('pending_'));
      expect(msgs.first.status, MessageStatus.sending);
      expect(msgs.first.isMine, isTrue);
      expect(msgs.first.content, 'Sending this');
    });

    test('preserves reply metadata', () {
      final notifier = _createNotifier();
      notifier.addOptimistic(
        'user-1',
        'Reply text',
        'me',
        conversationId: 'conv-1',
        replyToId: 'msg-0',
        replyToContent: 'Original',
        replyToUsername: 'alice',
      );

      final msg = notifier.state.messagesForConversation('conv-1').first;
      expect(msg.replyToId, 'msg-0');
      expect(msg.replyToContent, 'Original');
      expect(msg.replyToUsername, 'alice');
    });
  });

  group('ChatNotifier.confirmSent', () {
    test('replaces pending message with server ID', () {
      final notifier = _createNotifier();
      notifier.addOptimistic('user-1', 'Hello', 'me', conversationId: 'conv-1');

      final pendingId = notifier.state
          .messagesForConversation('conv-1')
          .first
          .id;
      expect(pendingId, startsWith('pending_'));

      notifier.confirmSent('server-msg-123', 'conv-1', '2026-01-01T12:00:00Z');

      final msgs = notifier.state.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.id, 'server-msg-123');
      expect(msgs.first.status, MessageStatus.sent);
    });

    test('preserves content of confirmed message', () {
      final notifier = _createNotifier();
      notifier.addOptimistic(
        'user-1',
        '[img:/api/media/abc-123]',
        'me',
        conversationId: 'conv-1',
      );

      notifier.confirmSent('server-msg-1', 'conv-1', '2026-01-01T12:00:00Z');

      final msgs = notifier.state.messagesForConversation('conv-1');
      expect(msgs.first.content, '[img:/api/media/abc-123]');
      expect(msgs.first.id, 'server-msg-1');
    });

    test(
      'FIFO: confirms oldest pending first when multiple pending exist',
      () async {
        final notifier = _createNotifier();
        // Simulate attachment + caption sent in rapid succession.
        notifier.addOptimistic(
          'user-1',
          '[img:/api/media/photo.png]',
          'me',
          conversationId: 'conv-1',
        );
        // Small delay so timestamps differ.
        await Future<void>.delayed(const Duration(milliseconds: 2));
        notifier.addOptimistic(
          'user-1',
          'Check out this photo!',
          'me',
          conversationId: 'conv-1',
        );

        final before = notifier.state.messagesForConversation('conv-1');
        expect(before, hasLength(2));
        expect(before[0].content, '[img:/api/media/photo.png]');
        expect(before[1].content, 'Check out this photo!');

        // Server confirms attachment first (FIFO order).
        notifier.confirmSent('server-attach', 'conv-1', '2026-01-01T12:00:00Z');

        final mid = notifier.state.messagesForConversation('conv-1');
        // Attachment should be confirmed, caption still pending.
        expect(
          mid.where((m) => m.id == 'server-attach').first.content,
          '[img:/api/media/photo.png]',
        );
        expect(
          mid.where((m) => m.id.startsWith('pending_')).first.content,
          'Check out this photo!',
        );

        // Server confirms caption second.
        notifier.confirmSent(
          'server-caption',
          'conv-1',
          '2026-01-01T12:00:01Z',
        );

        final after = notifier.state.messagesForConversation('conv-1');
        expect(after, hasLength(2));
        expect(
          after.where((m) => m.id == 'server-attach').first.content,
          '[img:/api/media/photo.png]',
        );
        expect(
          after.where((m) => m.id == 'server-caption').first.content,
          'Check out this photo!',
        );
      },
    );
  });

  group('ChatNotifier.updateMessageStatus', () {
    test('updates status of an existing message', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      notifier.updateMessageStatus('conv-1', 'msg-1', MessageStatus.delivered);

      final msg = notifier.state.messagesForConversation('conv-1').first;
      expect(msg.status, MessageStatus.delivered);
    });

    test('no-op for unknown message', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      // Should not throw
      notifier.updateMessageStatus(
        'conv-1',
        'nonexistent',
        MessageStatus.delivered,
      );

      expect(notifier.state.messagesForConversation('conv-1'), hasLength(1));
    });
  });

  group('ChatNotifier.deleteMessage', () {
    test('removes a message from the conversation', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);
      notifier.addMessage(_msg2);

      notifier.deleteMessage('conv-1', 'msg-1');

      final msgs = notifier.state.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.id, 'msg-2');
    });
  });

  group('ChatNotifier.editMessage', () {
    test('updates message content', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      notifier.editMessage(
        'conv-1',
        'msg-1',
        'Edited content',
        editedAt: '2026-01-01T11:00:00Z',
      );

      final msg = notifier.state.messagesForConversation('conv-1').first;
      expect(msg.content, 'Edited content');
      expect(msg.editedAt, '2026-01-01T11:00:00Z');
    });
  });

  group('ChatNotifier.addReaction / removeReaction', () {
    test('adds a reaction to a message', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      final reaction = const Reaction(
        messageId: 'msg-1',
        userId: 'user-2',
        username: 'bob',
        emoji: '👍',
      );
      notifier.addReaction('conv-1', reaction);

      final msg = notifier.state.messagesForConversation('conv-1').first;
      expect(msg.reactions, hasLength(1));
      expect(msg.reactions.first.emoji, '👍');
    });

    test('removes a reaction from a message', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      final reaction = const Reaction(
        messageId: 'msg-1',
        userId: 'user-2',
        username: 'bob',
        emoji: '👍',
      );
      notifier.addReaction('conv-1', reaction);
      notifier.removeReaction('conv-1', 'msg-1', 'user-2', '👍');

      final msg = notifier.state.messagesForConversation('conv-1').first;
      expect(msg.reactions, isEmpty);
    });
  });

  group('ChatNotifier.updateMessagePin', () {
    test('pins a message', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      final now = DateTime.now();
      notifier.updateMessagePin('conv-1', 'msg-1', 'user-2', now);

      final msg = notifier.state.messagesForConversation('conv-1').first;
      expect(msg.pinnedById, 'user-2');
      expect(msg.pinnedAt, isNotNull);
    });

    test('unpins a message', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);

      notifier.updateMessagePin('conv-1', 'msg-1', 'user-2', DateTime.now());
      notifier.updateMessagePin('conv-1', 'msg-1', null, null);

      final msg = notifier.state.messagesForConversation('conv-1').first;
      expect(msg.pinnedById, isNull);
      expect(msg.pinnedAt, isNull);
    });
  });

  group('ChatNotifier.markConversationRead', () {
    test('marks own sent messages as read', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1); // not mine -> unchanged
      notifier.addMessage(_msg2); // isMine + sent -> should become read

      notifier.markConversationRead('conv-1');

      final msgs = notifier.state.messagesForConversation('conv-1');
      // msg1 is not mine, stays at sent
      expect(msgs.first.status, MessageStatus.sent);
      // msg2 is mine and was sent, becomes read
      expect(msgs.last.status, MessageStatus.read);
    });
  });

  group('ChatNotifier.clear', () {
    test('removes all messages', () {
      final notifier = _createNotifier();
      notifier.addMessage(_msg1);
      notifier.addMessage(_msg2);

      notifier.clear();

      expect(notifier.state.messagesForConversation('conv-1'), isEmpty);
    });
  });
}
