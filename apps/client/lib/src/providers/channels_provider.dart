import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/channel.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';

class ChannelsState {
  final Map<String, List<GroupChannel>> channelsByConversation;
  final Map<String, List<VoiceSessionMember>> voiceSessionsByChannel;
  final Set<String> loadingConversations;
  final String? error;

  const ChannelsState({
    this.channelsByConversation = const {},
    this.voiceSessionsByChannel = const {},
    this.loadingConversations = const {},
    this.error,
  });

  ChannelsState copyWith({
    Map<String, List<GroupChannel>>? channelsByConversation,
    Map<String, List<VoiceSessionMember>>? voiceSessionsByChannel,
    Set<String>? loadingConversations,
    String? error,
  }) {
    return ChannelsState(
      channelsByConversation:
          channelsByConversation ?? this.channelsByConversation,
      voiceSessionsByChannel: voiceSessionsByChannel ?? this.voiceSessionsByChannel,
      loadingConversations: loadingConversations ?? this.loadingConversations,
      error: error,
    );
  }

  List<GroupChannel> channelsFor(String conversationId) {
    return channelsByConversation[conversationId] ?? const [];
  }

  List<VoiceSessionMember> voiceSessionsFor(String channelId) {
    return voiceSessionsByChannel[channelId] ?? const [];
  }

  bool isLoadingConversation(String conversationId) {
    return loadingConversations.contains(conversationId);
  }
}

class ChannelsNotifier extends StateNotifier<ChannelsState> {
  final Ref ref;

  ChannelsNotifier(this.ref) : super(const ChannelsState());

  String get _serverUrl => ref.read(serverUrlProvider);

  Map<String, String> _headersWithToken(String token) => {
    'Content-Type': 'application/json',
    'Authorization': 'Bearer $token',
  };

  Future<http.Response> _authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) async {
    return ref.read(authProvider.notifier).authenticatedRequest(requestFn);
  }

  Future<void> loadChannels(String conversationId) async {
    final loading = {...state.loadingConversations, conversationId};
    state = state.copyWith(loadingConversations: loading, error: null);

    try {
      final response = await _authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/groups/$conversationId/channels'),
          headers: _headersWithToken(token),
        ),
      );

      if (response.statusCode != 200) {
        state = state.copyWith(
          loadingConversations: {...state.loadingConversations}..remove(conversationId),
          error: 'Failed to load channels',
        );
        return;
      }

      final list = (jsonDecode(response.body) as List)
          .map((e) => GroupChannel.fromJson(e as Map<String, dynamic>))
          .toList()
        ..sort((a, b) {
          final kindOrder = a.kind.compareTo(b.kind);
          if (kindOrder != 0) return kindOrder;
          final posOrder = a.position.compareTo(b.position);
          if (posOrder != 0) return posOrder;
          return a.name.compareTo(b.name);
        });

      final updatedChannels = Map<String, List<GroupChannel>>.from(
        state.channelsByConversation,
      );
      updatedChannels[conversationId] = list;

      state = state.copyWith(
        channelsByConversation: updatedChannels,
        loadingConversations: {...state.loadingConversations}..remove(conversationId),
        error: null,
      );

      for (final voiceChannel in list.where((c) => c.isVoice)) {
        await loadVoiceSessions(conversationId, voiceChannel.id);
      }
    } catch (e) {
      debugPrint('[Channels] loadChannels failed for $conversationId: $e');
      state = state.copyWith(
        loadingConversations: {...state.loadingConversations}..remove(conversationId),
        error: e.toString(),
      );
    }
  }

  Future<void> loadVoiceSessions(String conversationId, String channelId) async {
    try {
      final response = await _authenticatedRequest(
        (token) => http.get(
          Uri.parse('$_serverUrl/api/groups/$conversationId/channels/$channelId/voice'),
          headers: _headersWithToken(token),
        ),
      );

      if (response.statusCode != 200) return;

      final list = (jsonDecode(response.body) as List)
          .map((e) => VoiceSessionMember.fromJson(e as Map<String, dynamic>))
          .toList();

      final updated = Map<String, List<VoiceSessionMember>>.from(
        state.voiceSessionsByChannel,
      );
      updated[channelId] = list;

      state = state.copyWith(voiceSessionsByChannel: updated);
    } catch (e) {
      debugPrint('[Channels] loadVoiceSessions failed for $channelId: $e');
    }
  }

  Future<bool> joinVoiceChannel(String conversationId, String channelId) async {
    try {
      final response = await _authenticatedRequest(
        (token) => http.post(
          Uri.parse(
            '$_serverUrl/api/groups/$conversationId/channels/$channelId/voice/join',
          ),
          headers: _headersWithToken(token),
        ),
      );
      if (response.statusCode != 200) {
        return false;
      }
      await loadChannels(conversationId);
      return true;
    } catch (e) {
      debugPrint('[Channels] joinVoiceChannel failed for $channelId: $e');
      return false;
    }
  }

  Future<bool> leaveVoiceChannel(String conversationId, String channelId) async {
    try {
      final response = await _authenticatedRequest(
        (token) => http.post(
          Uri.parse(
            '$_serverUrl/api/groups/$conversationId/channels/$channelId/voice/leave',
          ),
          headers: _headersWithToken(token),
        ),
      );
      if (response.statusCode != 200) {
        return false;
      }
      await loadVoiceSessions(conversationId, channelId);
      return true;
    } catch (e) {
      debugPrint('[Channels] leaveVoiceChannel failed for $channelId: $e');
      return false;
    }
  }

  Future<bool> updateVoiceState({
    required String conversationId,
    required String channelId,
    required bool isMuted,
    required bool isDeafened,
    required bool pushToTalk,
  }) async {
    try {
      final response = await _authenticatedRequest(
        (token) => http.put(
          Uri.parse(
            '$_serverUrl/api/groups/$conversationId/channels/$channelId/voice/state',
          ),
          headers: _headersWithToken(token),
          body: jsonEncode({
            'is_muted': isMuted,
            'is_deafened': isDeafened,
            'push_to_talk': pushToTalk,
          }),
        ),
      );
      if (response.statusCode != 200) {
        return false;
      }
      await loadVoiceSessions(conversationId, channelId);
      return true;
    } catch (e) {
      debugPrint('[Channels] updateVoiceState failed for $channelId: $e');
      return false;
    }
  }
}

final channelsProvider = StateNotifierProvider<ChannelsNotifier, ChannelsState>((
  ref,
) {
  return ChannelsNotifier(ref);
});
