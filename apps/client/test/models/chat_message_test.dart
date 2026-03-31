import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/chat_message.dart';

void main() {
  group('ChatMessage.fromServerJson', () {
    test('own message sets isMine=true', () {
      final json = {
        'message_id': 'msg-1',
        'from_user_id': 'user-abc',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
        'content': 'hello',
        'timestamp': '2026-03-31T12:00:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-abc');

      expect(msg.isMine, isTrue);
    });

    test('peer message sets isMine=false', () {
      final json = {
        'message_id': 'msg-2',
        'from_user_id': 'user-xyz',
        'from_username': 'bob',
        'conversation_id': 'conv-1',
        'content': 'hey there',
        'timestamp': '2026-03-31T12:01:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-abc');

      expect(msg.isMine, isFalse);
    });

    test('all fields parsed correctly', () {
      final json = {
        'message_id': 'msg-42',
        'from_user_id': 'user-sender',
        'from_username': 'sender_name',
        'conversation_id': 'conv-99',
        'content': 'full field test',
        'timestamp': '2026-03-31T15:30:00Z',
      };

      final msg = ChatMessage.fromServerJson(json, 'user-me');

      expect(msg.id, 'msg-42');
      expect(msg.fromUserId, 'user-sender');
      expect(msg.fromUsername, 'sender_name');
      expect(msg.conversationId, 'conv-99');
      expect(msg.content, 'full field test');
      expect(msg.timestamp, '2026-03-31T15:30:00Z');
      expect(msg.isMine, isFalse);
    });
  });
}
