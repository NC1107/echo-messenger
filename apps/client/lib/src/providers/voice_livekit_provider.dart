import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import 'auth_provider.dart';
import 'server_url_provider.dart';

class VoiceLivekitState {
  final String? conversationId;
  final String? channelId;
  final bool isJoining;
  final bool isActive;
  final bool isMuted;
  final bool isDeafened;
  final List<String> participantIds;
  final String? error;

  const VoiceLivekitState({
    this.conversationId,
    this.channelId,
    this.isJoining = false,
    this.isActive = false,
    this.isMuted = false,
    this.isDeafened = false,
    this.participantIds = const [],
    this.error,
  });

  VoiceLivekitState copyWith({
    String? conversationId,
    String? channelId,
    bool? isJoining,
    bool? isActive,
    bool? isMuted,
    bool? isDeafened,
    List<String>? participantIds,
    String? error,
  }) {
    return VoiceLivekitState(
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      isJoining: isJoining ?? this.isJoining,
      isActive: isActive ?? this.isActive,
      isMuted: isMuted ?? this.isMuted,
      isDeafened: isDeafened ?? this.isDeafened,
      participantIds: participantIds ?? this.participantIds,
      error: error,
    );
  }

  static const empty = VoiceLivekitState();
}

class VoiceLivekitNotifier extends StateNotifier<VoiceLivekitState> {
  final Ref ref;
  Room? _room;
  EventsListener<RoomEvent>? _listener;

  VoiceLivekitNotifier(this.ref) : super(VoiceLivekitState.empty);

  Future<void> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async {
    state = state.copyWith(isJoining: true, error: null);
    try {
      // 1. Fetch token from server
      final serverUrl = ref.read(serverUrlProvider);
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse(
                '$serverUrl/api/groups/$conversationId/channels/$channelId/voice/token',
              ),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
            ),
          );
      if (response.statusCode != 200) {
        throw Exception('Failed to get voice token: ${response.statusCode}');
      }
      final data = jsonDecode(response.body) as Map<String, dynamic>;
      final livekitToken = data['token'] as String;
      final livekitUrl = data['url'] as String;

      // 2. Create and connect room
      _room = Room(
        roomOptions: const RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioPublishOptions: AudioPublishOptions(
            audioBitrate: AudioPreset.music,
          ),
        ),
      );
      _setupListeners();

      await _room!.connect(livekitUrl, livekitToken);

      // 3. Enable microphone
      await _room!.localParticipant?.setMicrophoneEnabled(!startMuted);

      state = state.copyWith(
        conversationId: conversationId,
        channelId: channelId,
        isJoining: false,
        isActive: true,
        isMuted: startMuted,
      );
      _updateParticipants();
    } catch (e) {
      debugPrint('[VoiceLiveKit] join failed: $e');
      state = state.copyWith(isJoining: false, error: e.toString());
    }
  }

  Future<void> leaveChannel() async {
    await _room?.disconnect();
    _listener?.dispose();
    _listener = null;
    _room = null;
    state = VoiceLivekitState.empty;
  }

  /// Set the microphone mute state. When [muted] is true the local
  /// microphone track is disabled so no audio is published.
  Future<void> setMuted(bool muted) async {
    await _room?.localParticipant?.setMicrophoneEnabled(!muted);
    state = state.copyWith(isMuted: muted);
  }

  /// Convenience alias used by voice controls that still use the old
  /// `setCaptureEnabled` name from the P2P provider.
  void setCaptureEnabled(bool enabled) {
    setMuted(!enabled);
  }

  /// Mute/unmute all incoming audio from remote participants.
  Future<void> setDeafened(bool deafened) async {
    if (_room != null) {
      for (final p in _room!.remoteParticipants.values) {
        for (final pub in p.audioTrackPublications) {
          if (pub.subscribed && pub.track != null) {
            pub.track!.mediaStreamTrack.enabled = !deafened;
          }
        }
      }
    }
    state = state.copyWith(isDeafened: deafened);
  }

  void _setupListeners() {
    _listener = _room!.createListener();
    _listener!
      ..on<ParticipantConnectedEvent>((e) => _updateParticipants())
      ..on<ParticipantDisconnectedEvent>((e) => _updateParticipants())
      ..on<RoomDisconnectedEvent>((e) => leaveChannel())
      ..on<TrackSubscribedEvent>((e) {
        // Apply deafen state to newly subscribed tracks
        if (state.isDeafened) {
          e.track.mediaStreamTrack.enabled = false;
        }
      });
  }

  void _updateParticipants() {
    final ids = _room?.remoteParticipants.keys.toList() ?? [];
    state = state.copyWith(participantIds: ids);
  }

  @override
  void dispose() {
    _room?.disconnect();
    _listener?.dispose();
    super.dispose();
  }
}

final voiceLivekitProvider =
    StateNotifierProvider<VoiceLivekitNotifier, VoiceLivekitState>(
      (ref) => VoiceLivekitNotifier(ref),
    );
