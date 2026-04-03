import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

import '../services/sound_service.dart';
import 'auth_provider.dart';
import 'channels_provider.dart';
import 'websocket_provider.dart';

class VoiceRtcState {
  final String? conversationId;
  final String? channelId;
  final bool isJoining;
  final bool isActive;
  final bool isCaptureEnabled;
  final bool isDeafened;
  final Map<String, String> peerConnectionStates;
  final String? error;

  const VoiceRtcState({
    this.conversationId,
    this.channelId,
    this.isJoining = false,
    this.isActive = false,
    this.isCaptureEnabled = true,
    this.isDeafened = false,
    this.peerConnectionStates = const {},
    this.error,
  });

  VoiceRtcState copyWith({
    String? conversationId,
    String? channelId,
    bool? isJoining,
    bool? isActive,
    bool? isCaptureEnabled,
    bool? isDeafened,
    Map<String, String>? peerConnectionStates,
    String? error,
  }) {
    return VoiceRtcState(
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      isJoining: isJoining ?? this.isJoining,
      isActive: isActive ?? this.isActive,
      isCaptureEnabled: isCaptureEnabled ?? this.isCaptureEnabled,
      isDeafened: isDeafened ?? this.isDeafened,
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
  final Map<String, RTCVideoRenderer> _remoteAudioRenderers = {};
  final Map<String, List<(RTCIceCandidate, DateTime)>> _pendingIceCandidates =
      {};
  Set<String> _currentParticipants = const {};
  Timer? _participantSyncTimer;

  /// Maximum pending ICE candidates per peer before oldest are dropped.
  static const _maxPendingIceCandidatesPerPeer = 50;

  /// Maximum age for a pending ICE candidate before it is skipped on flush.
  static const _iceCandidateTtl = Duration(seconds: 30);

  /// Expose remote audio renderers so the widget tree can mount hidden
  /// [RTCVideoView] widgets that enable audio playback on web/desktop.
  Map<String, RTCVideoRenderer> get remoteAudioRenderers =>
      Map.unmodifiable(_remoteAudioRenderers);

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
        'audio': {
          'echoCancellation': true,
          'noiseSuppression': true,
          'autoGainControl': true,
        },
        'video': false,
      });
      debugPrint(
        '[VoiceRTC] Got local stream: '
        '${_localStream!.getAudioTracks().length} audio tracks',
      );

      setCaptureEnabled(!startMuted);

      state = state.copyWith(isJoining: false, isActive: true, error: null);
      SoundService().playVoiceJoin();

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

      // Start periodic participant sync to reconcile stale peer state.
      _startPeriodicParticipantSync(conversationId, channelId);
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
    if (state.isActive) {
      SoundService().playVoiceLeave();
    }
    _participantSyncTimer?.cancel();
    _participantSyncTimer = null;

    for (final userId in _peerConnections.keys.toList()) {
      final pc = _peerConnections[userId];
      if (pc == null) {
        continue;
      }
      try {
        await pc.close();
      } catch (_) {}
      await _disposeRemoteRenderer(userId);
    }
    _peerConnections.clear();
    _remoteAudioRenderers.clear();
    _pendingIceCandidates.clear();
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

  /// Mute/unmute all incoming audio from remote peers.
  void setDeafened(bool deafened) {
    for (final renderer in _remoteAudioRenderers.values) {
      renderer.muted = deafened;
    }
    // Also disable remote audio tracks on all peer connections so audio
    // processing stops entirely while deafened.
    for (final pc in _peerConnections.values) {
      for (final stream in pc.getRemoteStreams()) {
        if (stream == null) continue;
        for (final track in stream.getAudioTracks()) {
          track.enabled = !deafened;
        }
      }
    }
    state = state.copyWith(isDeafened: deafened);
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
      await _disposeRemoteRenderer(userId);
      _pendingIceCandidates.remove(userId);
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
      // Keep under 5 ICE servers to avoid browser slowdown warning.
      // For production, self-host coturn and replace credentials.
      'iceServers': [
        {'urls': 'stun:stun.l.google.com:19302'},
        {
          'urls': [
            'turn:a.relay.metered.ca:80',
            'turn:a.relay.metered.ca:443',
            'turn:a.relay.metered.ca:443?transport=tcp',
          ],
          'username': 'e8dd65b92fdd45f4b4c8e207',
          'credential': 'kBBm6TlKbHJHoNjp',
        },
      ],
      'sdpSemantics': 'unified-plan',
      'iceTransportPolicy': 'all',
      'bundlePolicy': 'max-bundle',
    };

    final pc = await createPeerConnection(config);

    final stream = _localStream;
    if (stream != null) {
      final audioTracks = stream.getAudioTracks();
      debugPrint(
        '[VoiceRTC] Adding ${audioTracks.length} audio tracks to PC for $remoteUserId',
      );
      for (final track in audioTracks) {
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
      debugPrint(
        '[VoiceRTC] Connection state for $remoteUserId: $connectionState',
      );
      _updatePeerState(
        remoteUserId,
        connectionState.toString().split('.').last,
      );
    };

    pc.onIceConnectionState = (iceState) {
      debugPrint('[VoiceRTC] ICE state for $remoteUserId: $iceState');
    };

    pc.onIceGatheringState = (gatherState) {
      debugPrint('[VoiceRTC] ICE gathering for $remoteUserId: $gatherState');
    };

    pc.onTrack = (event) {
      debugPrint(
        '[VoiceRTC] onTrack from $remoteUserId: kind=${event.track.kind} '
        'streams=${event.streams.length}',
      );
      if (event.track.kind != 'audio') {
        return;
      }
      if (event.streams.isEmpty) {
        return;
      }
      _attachRemoteAudioStream(remoteUserId, event.streams.first);
    };

    return pc;
  }

  Future<void> _attachRemoteAudioStream(
    String remoteUserId,
    MediaStream stream,
  ) async {
    final isCurrentlyDeafened = state.isDeafened;

    final existing = _remoteAudioRenderers[remoteUserId];
    if (existing != null) {
      existing.srcObject = stream;
      existing.muted = isCurrentlyDeafened;
      return;
    }

    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    renderer.muted = isCurrentlyDeafened;
    _remoteAudioRenderers[remoteUserId] = renderer;

    // Disable remote audio tracks if currently deafened.
    if (isCurrentlyDeafened) {
      for (final track in stream.getAudioTracks()) {
        track.enabled = false;
      }
    }
  }

  Future<void> _disposeRemoteRenderer(String remoteUserId) async {
    final renderer = _remoteAudioRenderers.remove(remoteUserId);
    if (renderer == null) {
      return;
    }
    renderer.srcObject = null;
    await renderer.dispose();
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
      await _drainPendingIceCandidates(fromUserId, pc);
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
      await _drainPendingIceCandidates(fromUserId, pc);
      _updatePeerState(fromUserId, 'answer_applied');
    } catch (e) {
      debugPrint('[VoiceRTC] handleAnswer failed from $fromUserId: $e');
      _updatePeerState(fromUserId, 'answer_error');
    }
  }

  void _enqueueIceCandidate(String userId, RTCIceCandidate candidate) {
    final queue = _pendingIceCandidates.putIfAbsent(userId, () => []);
    queue.add((candidate, DateTime.now()));
    // Enforce max queue size -- drop oldest when exceeding limit.
    while (queue.length > _maxPendingIceCandidatesPerPeer) {
      queue.removeAt(0);
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
      _enqueueIceCandidate(
        fromUserId,
        RTCIceCandidate(candidate, sdpMid, sdpMLineIndex),
      );
      return;
    }

    try {
      await pc.addCandidate(RTCIceCandidate(candidate, sdpMid, sdpMLineIndex));
    } catch (e) {
      _enqueueIceCandidate(
        fromUserId,
        RTCIceCandidate(candidate, sdpMid, sdpMLineIndex),
      );
      debugPrint('[VoiceRTC] addCandidate deferred for $fromUserId: $e');
    }
  }

  Future<void> _drainPendingIceCandidates(
    String userId,
    RTCPeerConnection pc,
  ) async {
    final queue = _pendingIceCandidates[userId];
    if (queue == null || queue.isEmpty) {
      return;
    }

    final now = DateTime.now();
    final remaining = <(RTCIceCandidate, DateTime)>[];
    for (final entry in queue) {
      final (candidate, timestamp) = entry;
      // Skip candidates older than TTL.
      if (now.difference(timestamp) > _iceCandidateTtl) {
        debugPrint(
          '[VoiceRTC] Dropping stale ICE candidate for $userId '
          '(age: ${now.difference(timestamp).inSeconds}s)',
        );
        continue;
      }
      try {
        await pc.addCandidate(candidate);
      } catch (_) {
        remaining.add(entry);
      }
    }

    if (remaining.isEmpty) {
      _pendingIceCandidates.remove(userId);
    } else {
      _pendingIceCandidates[userId] = remaining;
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

  /// Periodically fetch voice participants from the server and reconcile
  /// with local peer state. Catches stale peers that may have disconnected
  /// without sending a proper leave event.
  void _startPeriodicParticipantSync(String conversationId, String channelId) {
    _participantSyncTimer?.cancel();
    _participantSyncTimer = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) async {
      if (!_isCurrentVoiceContext(conversationId, channelId)) {
        _participantSyncTimer?.cancel();
        _participantSyncTimer = null;
        return;
      }

      try {
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
        debugPrint('[VoiceRTC] periodic sync failed: $e');
      }
    });
  }

  @override
  void dispose() {
    _participantSyncTimer?.cancel();
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
