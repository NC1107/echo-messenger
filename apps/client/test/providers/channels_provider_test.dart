import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/channel.dart';
import 'package:echo_app/src/providers/channels_provider.dart';

void main() {
  group('ChannelsState', () {
    test('default state is empty', () {
      const state = ChannelsState();
      expect(state.channelsByConversation, isEmpty);
      expect(state.voiceSessionsByChannel, isEmpty);
      expect(state.loadingConversations, isEmpty);
      expect(state.error, isNull);
    });

    test('channelsFor returns empty list for unknown conversation', () {
      const state = ChannelsState();
      expect(state.channelsFor('unknown'), isEmpty);
    });

    test('channelsFor returns channels for known conversation', () {
      final channels = [
        const GroupChannel(
          id: 'ch-1',
          conversationId: 'conv-1',
          name: 'general',
          kind: 'text',
          position: 0,
          createdAt: '2026-01-01',
        ),
      ];
      final state = ChannelsState(channelsByConversation: {'conv-1': channels});
      expect(state.channelsFor('conv-1'), hasLength(1));
      expect(state.channelsFor('conv-1').first.name, 'general');
    });

    test('voiceSessionsFor returns empty list for unknown channel', () {
      const state = ChannelsState();
      expect(state.voiceSessionsFor('unknown'), isEmpty);
    });

    test('isLoadingConversation returns correct status', () {
      const state = ChannelsState(loadingConversations: {'conv-1'});
      expect(state.isLoadingConversation('conv-1'), isTrue);
      expect(state.isLoadingConversation('conv-2'), isFalse);
    });

    test('copyWith preserves unchanged fields', () {
      final state = const ChannelsState(
        channelsByConversation: {
          'conv-1': [
            GroupChannel(
              id: 'ch-1',
              conversationId: 'conv-1',
              name: 'general',
              kind: 'text',
              position: 0,
              createdAt: '2026-01-01',
            ),
          ],
        },
        loadingConversations: {'conv-2'},
      );

      final copied = state.copyWith(error: 'test error');
      expect(copied.channelsByConversation, hasLength(1));
      expect(copied.loadingConversations, contains('conv-2'));
      expect(copied.error, 'test error');
    });
  });

  group('GroupChannel', () {
    test('fromJson parses text channel', () {
      final channel = GroupChannel.fromJson({
        'id': 'ch-1',
        'conversation_id': 'conv-1',
        'name': 'general',
        'kind': 'text',
        'topic': 'General discussion',
        'position': 0,
        'created_at': '2026-01-01T00:00:00Z',
      });

      expect(channel.id, 'ch-1');
      expect(channel.conversationId, 'conv-1');
      expect(channel.name, 'general');
      expect(channel.kind, 'text');
      expect(channel.topic, 'General discussion');
      expect(channel.position, 0);
      expect(channel.isText, isTrue);
      expect(channel.isVoice, isFalse);
      expect(channel.category, 'Text Channels');
    });

    test('fromJson parses voice channel', () {
      final channel = GroupChannel.fromJson({
        'id': 'ch-2',
        'conversation_id': 'conv-1',
        'name': 'Lounge',
        'kind': 'voice',
        'position': 1,
        'created_at': '2026-01-01T00:00:00Z',
      });

      expect(channel.isVoice, isTrue);
      expect(channel.isText, isFalse);
      expect(channel.category, 'Voice Channels');
    });

    test('fromJson handles missing fields gracefully', () {
      final channel = GroupChannel.fromJson({});
      expect(channel.id, '');
      expect(channel.name, '');
      expect(channel.kind, 'text');
      expect(channel.position, 0);
    });
  });

  group('VoiceSessionMember', () {
    test('fromJson parses all fields', () {
      final member = VoiceSessionMember.fromJson({
        'channel_id': 'ch-1',
        'user_id': 'user-1',
        'username': 'alice',
        'avatar_url': 'https://example.com/avatar.png',
        'is_muted': true,
        'is_deafened': false,
        'push_to_talk': true,
        'joined_at': '2026-01-01T10:00:00Z',
        'updated_at': '2026-01-01T10:30:00Z',
      });

      expect(member.channelId, 'ch-1');
      expect(member.userId, 'user-1');
      expect(member.username, 'alice');
      expect(member.avatarUrl, 'https://example.com/avatar.png');
      expect(member.isMuted, isTrue);
      expect(member.isDeafened, isFalse);
      expect(member.pushToTalk, isTrue);
    });

    test('fromJson handles missing fields', () {
      final member = VoiceSessionMember.fromJson({});
      expect(member.userId, '');
      expect(member.username, '');
      expect(member.isMuted, isFalse);
      expect(member.isDeafened, isFalse);
      expect(member.avatarUrl, isNull);
    });
  });
}
