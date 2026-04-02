import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import 'auth_provider.dart';
import 'channels_provider.dart';
import 'websocket_provider.dart';

class VoiceRtcState {
  final String? conversationId;
  final String? channelId;
  final bool isJoining;
  final bool isActive;
  final bool isCaptureEnabled;
  final Map<String, String> peerConnectionStates;
  final String? error;

  const VoiceRtcState({
    this.conversationId,
    this.channelId,
    this.isJoining = false,
    this.isActive = false,
    this.isCaptureEnabled = true,
    this.peerConnectionStates = const {},
    this.error,
  });

  VoiceRtcState copyWith({
    String? conversationId,
    String? channelId,
    bool? isJoining,
    bool? isActive,
    bool? isCaptureEnabled,
    Map<String, String>? peerConnectionStates,
    String? error,
  }) {
    return VoiceRtcState(
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      isJoining: isJoining ?? this.isJoining,
      isActive: isActive ?? this.isActive,
      isCaptureEnabled: isCaptureEnabled ?? this.isCaptureEnabled,
      peerConnectionStates: peerConnectionStates ?? this.peerConnectionStates,
      error: error,
    );
  }

  static const empty = VoiceRtcState();
}

class VoiceRtcNotifier extends StateNotifier<VoiceRtcState> {
  final Ref ref;

  StreamSubscription<Map<String, dynamic>>? _signalSubscription;
  MediaStream? _localStream;
  final Map<String, RTCPeerConnection> _peerConnections = {};
  Set<String> _currentParticipants = const {};

  VoiceRtcNotifier(this.ref) : super(VoiceRtcState.empty) {
    _signalSubscription = ref
        .read(websocketProvider.notifier)
        .voiceSignals
        .listen(_onVoiceSignal);
  }

  bool _isCurrentVoiceContext(String conversationId, String channelId) {
    return state.isActive &&
        state.conversationId == conversationId &&
        state.channelId == channelId;
  }

  Future<void> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async {
    if (_isCurrentVoiceContext(conversationId, channelId)) {
      await syncParticipants(
        conversationId: conversationId,
        channelId: channelId,
        participantUserIds: ref
            .read(channelsProvider)
            .voiceSessionsFor(channelId)
            .map((m) => m.userId)
            .toList(),
      );
      return;
    }

    await leaveChannel();

    state = state.copyWith(
      conversationId: conversationId,
      channelId: channelId,
      isJoining: true,
      isActive: false,
      error: null,
      peerConnectionStates: const {},
    );

    try {
      _localStream = await navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

      setCaptureEnabled(!startMuted);

      state = state.copyWith(isJoining: false, isActive: true, error: null);

      await ref
          .read(channelsProvider.notifier)
          .loadVoiceSessions(conversationId, channelId);

      final participants = ref
          .read(channelsProvider)
          .voiceSessionsFor(channelId)
          .map((m) => m.userId)
          .toList();

      await syncParticipants(
        conversationId: conversationId,
        channelId: channelId,
        participantUserIds: participants,
      );
    } catch (e) {
      debugPrint('[VoiceRTC] join failed: $e');
      await leaveChannel();
      state = state.copyWith(
        isJoining: false,
        isActive: false,
        error: 'Failed to initialize voice stream',
      );
    }
  }

  Future<void> leaveChannel() async {
    for (final pc in _peerConnections.values) {
      try {
        await pc.close();
      } catch (_) {}
    }
    _peerConnections.clear();
    _currentParticipants = const {};

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    state = VoiceRtcState.empty;
  }

  void setCaptureEnabled(bool enabled) {
    for (final track
        in _localStream?.getAudioTracks() ?? const <MediaStreamTrack>[]) {
      track.enabled = enabled;
    }

    state = state.copyWith(isCaptureEnabled: enabled);
  }

  Future<void> syncParticipants({
    required String conversationId,
    required String channelId,
    required List<String> participantUserIds,
  }) async {
    if (!_isCurrentVoiceContext(conversationId, channelId)) {
      return;
    }

    final me = ref.read(authProvider).userId ?? '';
    if (me.isEmpty) return;

    final targetPeers = participantUserIds
        .where((id) => id.isNotEmpty && id != me)
        .toSet();

    if (setEquals(_currentParticipants, targetPeers)) {
      return;
    }

    // Close peers that are no longer in the voice channel.
    final stale = _peerConnections.keys
        .where((userId) => !targetPeers.contains(userId))
        .toList();
    for (final userId in stale) {
      final pc = _peerConnections.remove(userId);
      if (pc != null) {
        try {
          await pc.close();
        } catch (_) {}
      }
    }

    final sortedTargets = targetPeers.toList()..sort();
    for (final peerUserId in sortedTargets) {
      if (_peerConnections.containsKey(peerUserId)) {
        continue;
      }

      final pc = await _createPeerConnection(peerUserId);
      _peerConnections[peerUserId] = pc;

      // Deterministic initiator avoids glare: lexicographically smaller user ID initiates.
      if (me.compareTo(peerUserId) < 0) {
        await _createAndSendOffer(peerUserId, pc);
      }
    }

    _currentParticipants = targetPeers;
    _publishPeerStates();
  }

  Future<RTCPeerConnection> _createPeerConnection(String remoteUserId) async {
    final config = {
      'iceServers': [
        {
          'urls': [
            'stun:stun.l.google.com:19302',
            'stun:stun1.l.google.com:19302',
          ],
        },
      ],
      'sdpSemantics': 'unified-plan',
    };

    final pc = await createPeerConnection(config);

    final stream = _localStream;
    if (stream != null) {
      for (final track in stream.getAudioTracks()) {
        await pc.addTrack(track, stream);
      }
    }

    pc.onIceCandidate = (candidate) {
      final candidateValue = candidate.candidate;
      if (candidateValue == null || candidateValue.isEmpty) {
        return;
      }

      _sendSignal(remoteUserId, {
        'type': 'ice-candidate',
        'candidate': candidateValue,
        'sdpMid': candidate.sdpMid,
        'sdpMLineIndex': candidate.sdpMLineIndex,
      });
    };

    pc.onConnectionState = (connectionState) {
      _updatePeerState(
        remoteUserId,
        connectionState.toString().split('.').last,
      );
    };

    return pc;
  }

  Future<void> _createAndSendOffer(
    String remoteUserId,
    RTCPeerConnection pc,
  ) async {
    try {
      final offer = await pc.createOffer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await pc.setLocalDescription(offer);
      _sendSignal(remoteUserId, {'type': 'offer', 'sdp': offer.sdp});
    } catch (e) {
      debugPrint('[VoiceRTC] createOffer failed for $remoteUserId: $e');
      _updatePeerState(remoteUserId, 'offer_failed');
    }
  }

  Future<void> _onVoiceSignal(Map<String, dynamic> envelope) async {
    final conversationId = envelope['conversation_id'] as String?;
    final channelId = envelope['channel_id'] as String?;
    final fromUserId = envelope['from_user_id'] as String?;
    final signal = envelope['signal'];

    if (conversationId == null ||
        channelId == null ||
        fromUserId == null ||
        signal is! Map<String, dynamic>) {
      return;
    }

    if (!_isCurrentVoiceContext(conversationId, channelId)) {
      return;
    }

    final signalType = signal['type'] as String?;
    if (signalType == null) return;

    switch (signalType) {
      case 'offer':
        final sdp = signal['sdp'] as String?;
        if (sdp == null || sdp.isEmpty) return;
        await _handleOffer(fromUserId, sdp);
      case 'answer':
        final sdp = signal['sdp'] as String?;
        if (sdp == null || sdp.isEmpty) return;
        await _handleAnswer(fromUserId, sdp);
      case 'ice-candidate':
        final candidate = signal['candidate'] as String?;
        final sdpMid = signal['sdpMid'] as String?;
        final sdpMLineIndex = signal['sdpMLineIndex'] as int?;
        if (candidate == null || candidate.isEmpty) return;
        await _handleIceCandidate(fromUserId, candidate, sdpMid, sdpMLineIndex);
    }
  }

  Future<void> _handleOffer(String fromUserId, String sdp) async {
    RTCPeerConnection pc =
        _peerConnections[fromUserId] ?? await _createPeerConnection(fromUserId);
    _peerConnections[fromUserId] = pc;

    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'offer'));
      final answer = await pc.createAnswer({
        'offerToReceiveAudio': 1,
        'offerToReceiveVideo': 0,
      });
      await pc.setLocalDescription(answer);

      _sendSignal(fromUserId, {'type': 'answer', 'sdp': answer.sdp});
      _updatePeerState(fromUserId, 'answer_sent');
    } catch (e) {
      debugPrint('[VoiceRTC] handleOffer failed from $fromUserId: $e');
      _updatePeerState(fromUserId, 'offer_error');
    }
  }

  Future<void> _handleAnswer(String fromUserId, String sdp) async {
    final pc = _peerConnections[fromUserId];
    if (pc == null) {
      return;
    }

    try {
      await pc.setRemoteDescription(RTCSessionDescription(sdp, 'answer'));
      _updatePeerState(fromUserId, 'answer_applied');
    } catch (e) {
      debugPrint('[VoiceRTC] handleAnswer failed from $fromUserId: $e');
      _updatePeerState(fromUserId, 'answer_error');
    }
  }

  Future<void> _handleIceCandidate(
    String fromUserId,
    String candidate,
    String? sdpMid,
    int? sdpMLineIndex,
  ) async {
    final pc = _peerConnections[fromUserId];
    if (pc == null) {
      return;
    }

    try {
      await pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
    } catch (e) {
      debugPrint('[VoiceRTC] addCandidate failed from $fromUserId: $e');
      _updatePeerState(fromUserId, 'ice_error');
    }
  }

  void _sendSignal(String toUserId, Map<String, dynamic> signal) {
    final conversationId = state.conversationId;
    final channelId = state.channelId;
    if (conversationId == null || channelId == null) {
      return;
    }

    ref
        .read(websocketProvider.notifier)
        .sendVoiceSignal(
          conversationId: conversationId,
          channelId: channelId,
          toUserId: toUserId,
          signal: signal,
        );
  }

  void _updatePeerState(String userId, String connectionState) {
    final updated = Map<String, String>.from(state.peerConnectionStates);
    updated[userId] = connectionState;
    state = state.copyWith(peerConnectionStates: updated);
  }

  void _publishPeerStates() {
    final updated = Map<String, String>.from(state.peerConnectionStates);

    for (final userId in _peerConnections.keys) {
      updated.putIfAbsent(userId, () => 'connecting');
    }

    updated.removeWhere((userId, _) => !_peerConnections.containsKey(userId));
    state = state.copyWith(peerConnectionStates: updated);
  }

  @override
  void dispose() {
    _signalSubscription?.cancel();
    unawaited(leaveChannel());
    super.dispose();
  }
}

final voiceRtcProvider = StateNotifierProvider<VoiceRtcNotifier, VoiceRtcState>(
  (ref) {
    return VoiceRtcNotifier(ref);
  },
);
