import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/channel.dart';

void main() {
  group('GroupChannel.fromJson', () {
    test('text channel parsed correctly', () {
      final json = {
        'id': 'chan-1',
        'conversation_id': 'conv-abc',
        'name': 'general',
        'kind': 'text',
        'topic': 'Welcome!',
        'position': 0,
        'category': 'Text Channels',
        'created_at': '2026-01-01T00:00:00Z',
      };

      final channel = GroupChannel.fromJson(json);

      expect(channel.id, 'chan-1');
      expect(channel.conversationId, 'conv-abc');
      expect(channel.name, 'general');
      expect(channel.kind, 'text');
      expect(channel.topic, 'Welcome!');
      expect(channel.position, 0);
      expect(channel.category, 'Text Channels');
      expect(channel.isText, isTrue);
      expect(channel.isVoice, isFalse);
    });

    test('voice channel parsed correctly', () {
      final json = {
        'id': 'chan-2',
        'conversation_id': 'conv-xyz',
        'name': 'lounge',
        'kind': 'voice',
        'topic': null,
        'position': 1,
        'category': 'Voice Channels',
        'created_at': '2026-01-02T00:00:00Z',
      };

      final channel = GroupChannel.fromJson(json);

      expect(channel.kind, 'voice');
      expect(channel.isVoice, isTrue);
      expect(channel.isText, isFalse);
      expect(channel.topic, isNull);
    });

    test('defaults kind to text when missing', () {
      final json = {
        'id': 'chan-3',
        'conversation_id': 'conv-def',
        'name': 'default-kind',
        'position': 0,
        'created_at': '2026-01-03T00:00:00Z',
      };

      final channel = GroupChannel.fromJson(json);

      expect(channel.kind, 'text');
      expect(channel.isText, isTrue);
    });

    test('defaults category based on kind when missing', () {
      final textJson = {
        'id': 'chan-4',
        'conversation_id': 'conv-1',
        'name': 'text-no-cat',
        'kind': 'text',
        'position': 0,
        'created_at': '2026-01-01T00:00:00Z',
      };
      final voiceJson = {
        'id': 'chan-5',
        'conversation_id': 'conv-1',
        'name': 'voice-no-cat',
        'kind': 'voice',
        'position': 0,
        'created_at': '2026-01-01T00:00:00Z',
      };

      expect(GroupChannel.fromJson(textJson).category, 'Text Channels');
      expect(GroupChannel.fromJson(voiceJson).category, 'Voice Channels');
    });

    test('defaults position to 0 when missing', () {
      final json = {
        'id': 'chan-6',
        'conversation_id': 'conv-1',
        'name': 'no-position',
        'kind': 'text',
        'created_at': '2026-01-01T00:00:00Z',
      };

      final channel = GroupChannel.fromJson(json);

      expect(channel.position, 0);
    });

    test('handles null id and conversationId gracefully', () {
      final json = {
        'id': null,
        'conversation_id': null,
        'name': 'null-ids',
        'kind': 'text',
        'position': 0,
        'created_at': '2026-01-01T00:00:00Z',
      };

      final channel = GroupChannel.fromJson(json);

      expect(channel.id, '');
      expect(channel.conversationId, '');
    });
  });

  group('VoiceSessionMember.fromJson', () {
    test('all fields parsed correctly', () {
      final json = {
        'channel_id': 'chan-99',
        'user_id': 'user-1',
        'username': 'alice',
        'avatar_url': 'https://example.com/avatar.png',
        'is_muted': true,
        'is_deafened': false,
        'push_to_talk': true,
        'joined_at': '2026-03-01T10:00:00Z',
        'updated_at': '2026-03-01T10:05:00Z',
      };

      final member = VoiceSessionMember.fromJson(json);

      expect(member.channelId, 'chan-99');
      expect(member.userId, 'user-1');
      expect(member.username, 'alice');
      expect(member.avatarUrl, 'https://example.com/avatar.png');
      expect(member.isMuted, isTrue);
      expect(member.isDeafened, isFalse);
      expect(member.pushToTalk, isTrue);
      expect(member.joinedAt, '2026-03-01T10:00:00Z');
      expect(member.updatedAt, '2026-03-01T10:05:00Z');
    });

    test('null avatarUrl remains null', () {
      final json = {
        'channel_id': 'chan-1',
        'user_id': 'user-2',
        'username': 'bob',
        'avatar_url': null,
        'is_muted': false,
        'is_deafened': false,
        'push_to_talk': false,
        'joined_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:01:00Z',
      };

      final member = VoiceSessionMember.fromJson(json);

      expect(member.avatarUrl, isNull);
    });

    test('boolean fields default to false when missing', () {
      final json = {
        'channel_id': 'chan-2',
        'user_id': 'user-3',
        'username': 'carol',
        'joined_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:01:00Z',
      };

      final member = VoiceSessionMember.fromJson(json);

      expect(member.isMuted, isFalse);
      expect(member.isDeafened, isFalse);
      expect(member.pushToTalk, isFalse);
    });

    test('handles null user_id and channel_id gracefully', () {
      final json = {
        'channel_id': null,
        'user_id': null,
        'username': 'dave',
        'is_muted': false,
        'is_deafened': false,
        'push_to_talk': false,
        'joined_at': '2026-01-01T00:00:00Z',
        'updated_at': '2026-01-01T00:01:00Z',
      };

      final member = VoiceSessionMember.fromJson(json);

      expect(member.channelId, '');
      expect(member.userId, '');
    });
  });
}
