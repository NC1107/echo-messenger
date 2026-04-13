import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/conversation.dart';

void main() {
  group('ConversationMember.fromJson', () {
    test('parses all fields', () {
      final member = ConversationMember.fromJson({
        'user_id': 'user-1',
        'username': 'alice',
        'role': 'owner',
        'avatar_url': 'https://example.com/avatar.png',
      });

      expect(member.userId, 'user-1');
      expect(member.username, 'alice');
      expect(member.role, 'owner');
      expect(member.avatarUrl, 'https://example.com/avatar.png');
    });

    test('parses member with null optional fields', () {
      final member = ConversationMember.fromJson({
        'user_id': 'user-2',
        'username': 'bob',
        'role': null,
        'avatar_url': null,
      });

      expect(member.role, isNull);
      expect(member.avatarUrl, isNull);
    });

    test('parses member with missing optional fields', () {
      final member = ConversationMember.fromJson({
        'user_id': 'user-3',
        'username': 'carol',
      });

      expect(member.userId, 'user-3');
      expect(member.username, 'carol');
      expect(member.role, isNull);
      expect(member.avatarUrl, isNull);
    });
  });

  group('ConversationMember equality', () {
    test('identical objects are equal', () {
      const m1 = ConversationMember(userId: 'u1', username: 'alice');
      const m2 = ConversationMember(userId: 'u1', username: 'alice');
      expect(m1, equals(m2));
    });

    test('different user_id means not equal', () {
      const m1 = ConversationMember(userId: 'u1', username: 'alice');
      const m2 = ConversationMember(userId: 'u2', username: 'alice');
      expect(m1, isNot(equals(m2)));
    });

    test('different role means not equal', () {
      const m1 = ConversationMember(userId: 'u1', username: 'alice', role: 'owner');
      const m2 = ConversationMember(userId: 'u1', username: 'alice', role: 'member');
      expect(m1, isNot(equals(m2)));
    });

    test('same object is equal to itself', () {
      const m = ConversationMember(userId: 'u1', username: 'alice');
      expect(m == m, isTrue);
    });
  });

  group('ConversationMember hashCode', () {
    test('equal objects have same hashCode', () {
      const m1 = ConversationMember(userId: 'u1', username: 'alice', role: 'owner');
      const m2 = ConversationMember(userId: 'u1', username: 'alice', role: 'owner');
      expect(m1.hashCode, equals(m2.hashCode));
    });
  });

  group('Conversation.displayName', () {
    test('returns group name for group conversations', () {
      const conv = Conversation(
        id: 'conv-1',
        isGroup: true,
        name: 'Engineering',
        members: [
          ConversationMember(userId: 'me', username: 'myself'),
          ConversationMember(userId: 'u2', username: 'other'),
        ],
      );
      expect(conv.displayName('me'), 'Engineering');
    });

    test('returns peer username for 1:1 conversations', () {
      const conv = Conversation(
        id: 'conv-2',
        isGroup: false,
        members: [
          ConversationMember(userId: 'me', username: 'myself'),
          ConversationMember(userId: 'peer', username: 'alice'),
        ],
      );
      expect(conv.displayName('me'), 'alice');
    });

    test('falls back to name when no peer found in DM', () {
      const conv = Conversation(
        id: 'conv-3',
        isGroup: false,
        name: 'Legacy Name',
        members: [
          ConversationMember(userId: 'me', username: 'myself'),
        ],
      );
      expect(conv.displayName('me'), 'Legacy Name');
    });

    test('falls back to Unknown when no name and no peer', () {
      const conv = Conversation(
        id: 'conv-4',
        isGroup: false,
        members: [],
      );
      expect(conv.displayName('me'), 'Unknown');
    });
  });

  group('Conversation.copyWith', () {
    const base = Conversation(
      id: 'conv-1',
      isGroup: false,
      name: 'Original',
      unreadCount: 3,
      isMuted: false,
    );

    test('updates only specified fields', () {
      final updated = base.copyWith(unreadCount: 0);
      expect(updated.id, base.id);
      expect(updated.name, base.name);
      expect(updated.unreadCount, 0);
      expect(updated.isMuted, base.isMuted);
    });

    test('can update name', () {
      final updated = base.copyWith(name: 'New Name');
      expect(updated.name, 'New Name');
      expect(updated.id, base.id);
    });

    test('can mute conversation', () {
      final updated = base.copyWith(isMuted: true);
      expect(updated.isMuted, isTrue);
    });

    test('can update members list', () {
      const newMembers = [
        ConversationMember(userId: 'u1', username: 'alice'),
      ];
      final updated = base.copyWith(members: newMembers);
      expect(updated.members, hasLength(1));
    });
  });

  group('Conversation equality', () {
    test('two conversations with same fields are equal', () {
      const c1 = Conversation(id: 'c1', isGroup: false, unreadCount: 2);
      const c2 = Conversation(id: 'c1', isGroup: false, unreadCount: 2);
      expect(c1, equals(c2));
    });

    test('different id means not equal', () {
      const c1 = Conversation(id: 'c1', isGroup: false);
      const c2 = Conversation(id: 'c2', isGroup: false);
      expect(c1, isNot(equals(c2)));
    });

    test('different unreadCount means not equal', () {
      const c1 = Conversation(id: 'c1', isGroup: false, unreadCount: 1);
      const c2 = Conversation(id: 'c1', isGroup: false, unreadCount: 2);
      expect(c1, isNot(equals(c2)));
    });
  });
}
