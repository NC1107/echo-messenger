import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/reaction.dart';

void main() {
  late ChatNotifier notifier;

  setUp(() {
    notifier = ChatNotifier();
  });

  group('ChatNotifier', () {
    test('initial state has no messages', () {
      expect(notifier.state.messagesFor('any-peer'), isEmpty);
      expect(notifier.state.messagesByPeer, isEmpty);
      expect(notifier.state.messagesByConversation, isEmpty);
    });

    test('addMessage stores message retrievable by peer', () {
      final msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-1',
        fromUsername: 'peer',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );

      notifier.addMessage(msg);

      final messages = notifier.state.messagesFor('peer-1');
      expect(messages, hasLength(1));
      expect(messages.first.content, 'hello');
    });

    test('addMessage stores message retrievable by conversation', () {
      final msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-1',
        fromUsername: 'peer',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );

      notifier.addMessage(msg);

      final messages = notifier.state.messagesForConversation('conv-1');
      expect(messages, hasLength(1));
      expect(messages.first.content, 'hello');
    });

    test('addOptimistic adds message for peer', () {
      notifier.addOptimistic('peer-1', 'optimistic msg', 'my-user-id');

      final messages = notifier.state.messagesFor('peer-1');
      expect(messages, hasLength(1));
      expect(messages.first.content, 'optimistic msg');
      expect(messages.first.isMine, isTrue);
      expect(messages.first.id, startsWith('pending_'));
      expect(messages.first.status, MessageStatus.sending);
    });

    test('addOptimistic with conversationId stores in both maps', () {
      notifier.addOptimistic(
        'peer-1',
        'msg',
        'my-user-id',
        conversationId: 'conv-1',
      );

      expect(notifier.state.messagesFor('peer-1'), hasLength(1));
      expect(notifier.state.messagesForConversation('conv-1'), hasLength(1));
    });

    test('messages for different peers are isolated', () {
      final msg1 = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-a',
        fromUsername: 'A',
        conversationId: 'conv-1',
        content: 'from A',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );
      final msg2 = ChatMessage(
        id: 'msg-2',
        fromUserId: 'peer-b',
        fromUsername: 'B',
        conversationId: 'conv-2',
        content: 'from B',
        timestamp: '2026-03-31T12:01:00Z',
        isMine: false,
      );

      notifier.addMessage(msg1);
      notifier.addMessage(msg2);

      expect(notifier.state.messagesFor('peer-a'), hasLength(1));
      expect(notifier.state.messagesFor('peer-b'), hasLength(1));
      expect(notifier.state.messagesFor('peer-a').first.content, 'from A');
      expect(notifier.state.messagesFor('peer-b').first.content, 'from B');
    });

    test('deduplicates messages by id in conversation map', () {
      final msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-1',
        fromUsername: 'peer',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );

      notifier.addMessage(msg);
      notifier.addMessage(msg);

      final messages = notifier.state.messagesForConversation('conv-1');
      expect(messages, hasLength(1));
    });

    test('clear removes all messages', () {
      notifier.addOptimistic('peer-1', 'msg', 'my-id');
      expect(notifier.state.messagesFor('peer-1'), isNotEmpty);

      notifier.clear();

      expect(notifier.state.messagesFor('peer-1'), isEmpty);
      expect(notifier.state.messagesByPeer, isEmpty);
      expect(notifier.state.messagesByConversation, isEmpty);
    });

    test('addReaction adds reaction to correct message', () {
      final msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-1',
        fromUsername: 'peer',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
      );

      notifier.addMessage(msg);
      notifier.addReaction(
        'conv-1',
        const Reaction(
          messageId: 'msg-1',
          userId: 'user-2',
          username: 'bob',
          emoji: '👍',
        ),
      );

      final messages = notifier.state.messagesForConversation('conv-1');
      expect(messages.first.reactions, hasLength(1));
      expect(messages.first.reactions.first.emoji, '👍');
    });

    test('removeReaction removes reaction from correct message', () {
      final msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'peer-1',
        fromUsername: 'peer',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: false,
        reactions: const [
          Reaction(
            messageId: 'msg-1',
            userId: 'user-2',
            username: 'bob',
            emoji: '👍',
          ),
        ],
      );

      notifier.addMessage(msg);
      notifier.removeReaction('conv-1', 'msg-1', 'user-2', '👍');

      final messages = notifier.state.messagesForConversation('conv-1');
      expect(messages.first.reactions, isEmpty);
    });

    test('updateMessageStatus changes status', () {
      final msg = ChatMessage(
        id: 'msg-1',
        fromUserId: 'my-id',
        fromUsername: 'me',
        conversationId: 'conv-1',
        content: 'hello',
        timestamp: '2026-03-31T12:00:00Z',
        isMine: true,
        status: MessageStatus.sending,
      );

      notifier.addMessage(msg);
      notifier.updateMessageStatus(
        'conv-1',
        'msg-1',
        MessageStatus.delivered,
      );

      final messages = notifier.state.messagesForConversation('conv-1');
      expect(messages.first.status, MessageStatus.delivered);
    });

    test('isLoadingHistory defaults to false', () {
      expect(notifier.state.isLoadingHistory('conv-1'), isFalse);
    });

    test('conversationHasMore defaults to true', () {
      expect(notifier.state.conversationHasMore('conv-1'), isTrue);
    });
  });
}
