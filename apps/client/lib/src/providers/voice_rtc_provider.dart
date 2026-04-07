import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:http/http.dart' as http;

import '../services/debug_log_service.dart';
import '../services/sound_service.dart';
import 'auth_provider.dart';
import 'channels_provider.dart';
import 'server_url_provider.dart';
import 'voice_settings_provider.dart';
import 'websocket_provider.dart';

class VoiceRtcState {
  final String? conversationId;
  final String? channelId;
  final bool isJoining;
  final bool isActive;
  final bool isCaptureEnabled;
  final bool isDeafened;
  final bool isVideoEnabled;
  final Map<String, String> peerConnectionStates;

  /// Round-trip latency in seconds per peer, extracted from RTCStats.
  final Map<String, double> peerLatencies;

  /// Audio levels per peer (0.0–1.0), polled from RTCStats.
  final Map<String, double> peerAudioLevels;

  /// Local microphone audio level (0.0–1.0).
  final double localAudioLevel;
  final String? error;

  const VoiceRtcState({
    this.conversationId,
    this.channelId,
    this.isJoining = false,
    this.isActive = false,
    this.isCaptureEnabled = true,
    this.isDeafened = false,
    this.isVideoEnabled = false,
    this.peerConnectionStates = const {},
    this.peerLatencies = const {},
    this.peerAudioLevels = const {},
    this.localAudioLevel = 0.0,
    this.error,
  });

  VoiceRtcState copyWith({
    String? conversationId,
    String? channelId,
    bool? isJoining,
    bool? isActive,
    bool? isCaptureEnabled,
    bool? isDeafened,
    bool? isVideoEnabled,
    Map<String, String>? peerConnectionStates,
    Map<String, double>? peerLatencies,
    Map<String, double>? peerAudioLevels,
    double? localAudioLevel,
    String? error,
  }) {
    return VoiceRtcState(
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      isJoining: isJoining ?? this.isJoining,
      isActive: isActive ?? this.isActive,
      isCaptureEnabled: isCaptureEnabled ?? this.isCaptureEnabled,
      isDeafened: isDeafened ?? this.isDeafened,
      isVideoEnabled: isVideoEnabled ?? this.isVideoEnabled,
      peerConnectionStates: peerConnectionStates ?? this.peerConnectionStates,
      peerLatencies: peerLatencies ?? this.peerLatencies,
      peerAudioLevels: peerAudioLevels ?? this.peerAudioLevels,
      localAudioLevel: localAudioLevel ?? this.localAudioLevel,
      error: error,
    );
  }

  static const empty = VoiceRtcState();
}

class VoiceRtcNotifier extends StateNotifier<VoiceRtcState> {
  final Ref ref;

  StreamSubscription<Map<String, dynamic>>? _signalSubscription;
  MediaStream? _localStream;
  MediaStream? _localVideoStream;
  final Map<String, RTCPeerConnection> _peerConnections = {};
  final Map<String, RTCVideoRenderer> _remoteAudioRenderers = {};
  final Map<String, RTCVideoRenderer> _remoteVideoRenderers = {};
  final Map<String, List<(RTCIceCandidate, DateTime)>> _pendingIceCandidates =
      {};
  Set<String> _currentParticipants = const {};
  Timer? _participantSyncTimer;
  Timer? _latencyTimer;
  List<Map<String, dynamic>>? _cachedIceServers;

  /// Tracks whether mic was muted before deafening, so un-deafen restores
  /// the previous mute state instead of always enabling the mic.
  bool _wasMutedBeforeDeafen = false;

  /// Maximum pending ICE candidates per peer before oldest are dropped.
  static const _maxPendingIceCandidatesPerPeer = 50;

  /// Maximum age for a pending ICE candidate before it is skipped on flush.
  static const _iceCandidateTtl = Duration(seconds: 30);

  /// Expose remote audio renderers so the widget tree can mount hidden
  /// [RTCVideoView] widgets that enable audio playback on web/desktop.
  Map<String, RTCVideoRenderer> get remoteAudioRenderers =>
      Map.unmodifiable(_remoteAudioRenderers);

  /// Expose remote video renderers for displaying peer video streams.
  Map<String, RTCVideoRenderer> get remoteVideoRenderers =>
      Map.unmodifiable(_remoteVideoRenderers);

  /// Expose the local video stream so the UI can show a self-preview.
  MediaStream? get localVideoStream => _localVideoStream;

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
    if (_disposed) {
      return;
    }

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
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceRTC',
        'Got local stream: ${_localStream!.getAudioTracks().length} audio tracks',
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
      _startLatencyPolling();
      _startAudioLevelPolling();
    } catch (e) {
      debugPrint('[VoiceRTC] join failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'VoiceRTC',
        'Join failed: $e',
      );
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
    _stopLatencyPolling();
    _stopAudioLevelPolling();

    for (final userId in _peerConnections.keys.toList()) {
      final pc = _peerConnections[userId];
      if (pc == null) {
        continue;
      }
      try {
        await pc.close();
      } catch (_) {}
      await _disposeRemoteRenderer(userId);
      await _disposeRemoteVideoRenderer(userId);
    }
    _peerConnections.clear();
    _remoteAudioRenderers.clear();
    _remoteVideoRenderers.clear();
    _pendingIceCandidates.clear();
    _currentParticipants = const {};

    if (_localStream != null) {
      for (final track in _localStream!.getTracks()) {
        track.stop();
      }
      await _localStream!.dispose();
      _localStream = null;
    }

    // Stop and dispose the local video stream if active.
    if (_localVideoStream != null) {
      for (final track in _localVideoStream!.getTracks()) {
        track.stop();
      }
      await _localVideoStream!.dispose();
      _localVideoStream = null;
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
  ///
  /// Following Discord convention, deafening also mutes the microphone.
  /// Un-deafening restores mic to whatever state it was before deafening.
  ///
  /// Uses [RTCRtpReceiver] to reliably access remote audio tracks under
  /// unified-plan SDP semantics (`getRemoteStreams()` can be empty).
  Future<void> setDeafened(bool deafened) async {
    if (deafened) {
      // Save current mic state before deafening so we can restore it later
      _wasMutedBeforeDeafen = !state.isCaptureEnabled;
      // Mute mic when deafening (Discord convention)
      setCaptureEnabled(false);
    } else {
      // Restore mic to pre-deafen state
      if (!_wasMutedBeforeDeafen) {
        setCaptureEnabled(true);
      }
    }

    for (final renderer in _remoteAudioRenderers.values) {
      renderer.muted = deafened;
    }
    // Disable remote audio tracks via receivers -- this is the reliable
    // unified-plan approach and stops audio processing while deafened.
    for (final pc in _peerConnections.values) {
      final receivers = await pc.getReceivers();
      for (final receiver in receivers) {
        final track = receiver.track;
        if (track != null && track.kind == 'audio') {
          track.enabled = !deafened;
        }
      }
    }
    state = state.copyWith(isDeafened: deafened);
  }

  /// Toggle local video on/off. When enabling, acquires a camera stream and
  /// adds the video track to all active peer connections. When disabling,
  /// removes and stops the video track.
  Future<void> toggleVideo() async {
    if (_disposed || !state.isActive) return;

    if (state.isVideoEnabled) {
      // --- Disable video ---
      // Remove video tracks from all peer connections.
      for (final pc in _peerConnections.values) {
        final senders = await pc.getSenders();
        for (final sender in senders) {
          if (sender.track?.kind == 'video') {
            await pc.removeTrack(sender);
          }
        }
      }
      // Stop and dispose the local video stream.
      if (_localVideoStream != null) {
        for (final track in _localVideoStream!.getTracks()) {
          track.stop();
        }
        await _localVideoStream!.dispose();
        _localVideoStream = null;
      }
      state = state.copyWith(isVideoEnabled: false);
    } else {
      // --- Enable video ---
      try {
        _localVideoStream = await navigator.mediaDevices.getUserMedia({
          'audio': false,
          'video': {'facingMode': 'user', 'width': 640, 'height': 480},
        });
        final videoTracks = _localVideoStream!.getVideoTracks();
        debugPrint(
          '[VoiceRTC] Got local video stream: '
          '${videoTracks.length} video tracks',
        );
        DebugLogService.instance.log(
          LogLevel.info,
          'VoiceRTC',
          'Got local video stream: ${videoTracks.length} video tracks',
        );

        // Add video track to every existing peer connection.
        for (final pc in _peerConnections.values) {
          for (final track in videoTracks) {
            await pc.addTrack(track, _localVideoStream!);
          }
        }

        state = state.copyWith(isVideoEnabled: true);
      } catch (e) {
        debugPrint('[VoiceRTC] toggleVideo failed: $e');
        DebugLogService.instance.log(
          LogLevel.error,
          'VoiceRTC',
          'toggleVideo failed: $e',
        );
        state = state.copyWith(error: 'Failed to enable camera');
      }
    }
  }

  Future<void> syncParticipants({
    required String conversationId,
    required String channelId,
    required List<String> participantUserIds,
  }) async {
    if (_disposed) return;
    if (!_isCurrentVoiceContext(conversationId, channelId)) return;

    final me = ref.read(authProvider).userId ?? '';
    if (me.isEmpty) return;

    final targetPeers = participantUserIds
        .where((id) => id.isNotEmpty && id != me)
        .toSet();

    if (setEquals(_currentParticipants, targetPeers)) return;

    await _closeStalePeers(targetPeers);
    await _connectNewPeers(targetPeers, me);

    _currentParticipants = targetPeers;
    _publishPeerStates();
  }

  /// Close peer connections for users no longer in the voice channel.
  Future<void> _closeStalePeers(Set<String> targetPeers) async {
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
      await _disposeRemoteVideoRenderer(userId);
      _pendingIceCandidates.remove(userId);
    }
  }

  /// Create peer connections for new participants and send offers where needed.
  Future<void> _connectNewPeers(Set<String> targetPeers, String me) async {
    final sortedTargets = targetPeers.toList()..sort();
    for (final peerUserId in sortedTargets) {
      if (_peerConnections.containsKey(peerUserId)) continue;

      final pc = await _createPeerConnection(peerUserId);
      _peerConnections[peerUserId] = pc;

      // Deterministic initiator avoids glare: lexicographically smaller user ID initiates.
      if (me.compareTo(peerUserId) < 0) {
        await _createAndSendOffer(peerUserId, pc);
      }
    }
  }

  Future<List<Map<String, dynamic>>> _fetchIceServers() async {
    if (_cachedIceServers != null) return _cachedIceServers!;
    try {
      final serverUrl = ref.read(serverUrlProvider);
      final resp = await http.get(Uri.parse('$serverUrl/api/config/ice'));
      if (resp.statusCode == 200) {
        final json = jsonDecode(resp.body);
        final servers = (json['iceServers'] as List?)
            ?.map((e) => Map<String, dynamic>.from(e as Map))
            .toList();
        if (servers != null && servers.isNotEmpty) {
          _cachedIceServers = servers;
          return servers;
        }
      }
    } catch (e) {
      debugPrint('[VoiceRTC] Failed to fetch ICE config: $e');
      DebugLogService.instance.log(
        LogLevel.warning,
        'VoiceRTC',
        'Failed to fetch ICE config: $e',
      );
    }
    // Fallback to STUN only
    return [
      {'urls': 'stun:stun.l.google.com:19302'},
    ];
  }

  Future<RTCPeerConnection> _createPeerConnection(String remoteUserId) async {
    final iceServers = await _fetchIceServers();
    final config = {
      'iceServers': iceServers,
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
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceRTC',
        'Adding ${audioTracks.length} audio tracks to PC for $remoteUserId',
      );
      for (final track in audioTracks) {
        await pc.addTrack(track, stream);
      }
    }

    // If video is already enabled, add video tracks to the new peer connection.
    final videoStream = _localVideoStream;
    if (videoStream != null && state.isVideoEnabled) {
      final videoTracks = videoStream.getVideoTracks();
      debugPrint(
        '[VoiceRTC] Adding ${videoTracks.length} video tracks to PC for $remoteUserId',
      );
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceRTC',
        'Adding ${videoTracks.length} video tracks to PC for $remoteUserId',
      );
      for (final track in videoTracks) {
        await pc.addTrack(track, videoStream);
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
      final stateStr = connectionState.toString().split('.').last;
      debugPrint(
        '[VoiceRTC] Connection state for $remoteUserId: $connectionState',
      );
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceRTC',
        'Connection state for $remoteUserId: $stateStr',
      );
      _updatePeerState(remoteUserId, stateStr);
    };

    pc.onIceConnectionState = (iceState) {
      debugPrint('[VoiceRTC] ICE state for $remoteUserId: $iceState');
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceRTC',
        'ICE state for $remoteUserId: $iceState',
      );
    };

    pc.onIceGatheringState = (gatherState) {
      debugPrint('[VoiceRTC] ICE gathering for $remoteUserId: $gatherState');
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceRTC',
        'ICE gathering for $remoteUserId: $gatherState',
      );
    };

    pc.onTrack = (event) {
      debugPrint(
        '[VoiceRTC] onTrack from $remoteUserId: kind=${event.track.kind} '
        'streams=${event.streams.length}',
      );
      DebugLogService.instance.log(
        LogLevel.info,
        'VoiceRTC',
        'onTrack from $remoteUserId: kind=${event.track.kind} '
            'streams=${event.streams.length}',
      );
      if (event.streams.isEmpty) return;
      if (event.track.kind == 'audio') {
        _attachRemoteAudioStream(remoteUserId, event.streams.first);
      } else if (event.track.kind == 'video') {
        _attachRemoteVideoStream(remoteUserId, event.streams.first);
      }
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

  Future<void> _attachRemoteVideoStream(
    String remoteUserId,
    MediaStream stream,
  ) async {
    final existing = _remoteVideoRenderers[remoteUserId];
    if (existing != null) {
      existing.srcObject = stream;
      return;
    }

    final renderer = RTCVideoRenderer();
    await renderer.initialize();
    renderer.srcObject = stream;
    _remoteVideoRenderers[remoteUserId] = renderer;
    // Trigger a state rebuild so widgets can pick up the new renderer.
    state = state.copyWith(
      peerConnectionStates: Map.of(state.peerConnectionStates),
    );
  }

  Future<void> _disposeRemoteVideoRenderer(String remoteUserId) async {
    final renderer = _remoteVideoRenderers.remove(remoteUserId);
    if (renderer == null) return;
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
        'offerToReceiveVideo': 1,
      });
      await pc.setLocalDescription(offer);
      _sendSignal(remoteUserId, {'type': 'offer', 'sdp': offer.sdp});
    } catch (e) {
      debugPrint('[VoiceRTC] createOffer failed for $remoteUserId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'VoiceRTC',
        'createOffer failed for $remoteUserId: $e',
      );
      _updatePeerState(remoteUserId, 'offer_failed');
    }
  }

  Future<void> _onVoiceSignal(Map<String, dynamic> envelope) async {
    if (_disposed) {
      return;
    }

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
      // No constraints needed on answer -- offer SDP already defines media
      final answer = await pc.createAnswer();
      await pc.setLocalDescription(answer);

      _sendSignal(fromUserId, {'type': 'answer', 'sdp': answer.sdp});
      _updatePeerState(fromUserId, 'answer_sent');
    } catch (e) {
      debugPrint('[VoiceRTC] handleOffer failed from $fromUserId: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'VoiceRTC',
        'handleOffer failed from $fromUserId: $e',
      );
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
      DebugLogService.instance.log(
        LogLevel.error,
        'VoiceRTC',
        'handleAnswer failed from $fromUserId: $e',
      );
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
      DebugLogService.instance.log(
        LogLevel.warning,
        'VoiceRTC',
        'addCandidate deferred for $fromUserId: $e',
      );
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
        DebugLogService.instance.log(
          LogLevel.warning,
          'VoiceRTC',
          'Dropping stale ICE candidate for $userId '
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
    if (_disposed) {
      return;
    }

    final conversationId = state.conversationId;
    final channelId = state.channelId;
    if (conversationId == null || channelId == null) {
      return;
    }

    try {
      ref
          .read(websocketProvider.notifier)
          .sendVoiceSignal(
            conversationId: conversationId,
            channelId: channelId,
            toUserId: toUserId,
            signal: signal,
          );
    } catch (e) {
      debugPrint('[VoiceRTC] sendSignal failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'VoiceRTC',
        'sendSignal failed: $e',
      );
    }
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

  // ---------------------------------------------------------------------------
  // Latency polling -- extracts currentRoundTripTime from RTCStats every 5s
  // ---------------------------------------------------------------------------

  void _startLatencyPolling() {
    _latencyTimer?.cancel();
    _latencyTimer = Timer.periodic(const Duration(seconds: 5), (_) {
      if (_disposed) {
        _latencyTimer?.cancel();
        _latencyTimer = null;
        return;
      }
      _pollPeerLatencies();
    });
  }

  void _stopLatencyPolling() {
    _latencyTimer?.cancel();
    _latencyTimer = null;
  }

  // -- Audio level polling (VAD) --

  Timer? _audioLevelTimer;

  void _startAudioLevelPolling() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_disposed) {
        _audioLevelTimer?.cancel();
        _audioLevelTimer = null;
        return;
      }
      _pollAudioLevels();
    });
  }

  void _stopAudioLevelPolling() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer = null;
  }

  Future<void> _pollAudioLevels() async {
    final levels = <String, double>{};
    double localLevel = 0.0;

    for (final entry in _peerConnections.entries) {
      try {
        final stats = await entry.value.getStats();
        for (final report in stats) {
          if (report.type == 'inbound-rtp') {
            final kind = report.values['kind'];
            if (kind == 'audio') {
              final level = report.values['audioLevel'];
              if (level is double) {
                levels[entry.key] = level;
              }
              break;
            }
          }
        }
      } catch (_) {}
    }

    // Local audio level from outbound stats
    for (final entry in _peerConnections.entries) {
      try {
        final stats = await entry.value.getStats();
        for (final report in stats) {
          if (report.type == 'media-source') {
            final kind = report.values['kind'];
            if (kind == 'audio') {
              final level = report.values['audioLevel'];
              if (level is double) {
                localLevel = level;
              }
              break;
            }
          }
        }
        if (localLevel > 0) break;
      } catch (_) {}
    }

    if (!_disposed) {
      state = state.copyWith(
        peerAudioLevels: levels,
        localAudioLevel: localLevel,
      );
    }
  }

  Future<void> _pollPeerLatencies() async {
    final latencies = <String, double>{};
    for (final entry in _peerConnections.entries) {
      try {
        final stats = await entry.value.getStats();
        for (final report in stats) {
          // Look for the nominated candidate-pair stat.
          if (report.type == 'candidate-pair') {
            final rtt = report.values['currentRoundTripTime'];
            if (rtt is double && rtt > 0) {
              latencies[entry.key] = rtt;
              break;
            }
          }
        }
      } catch (_) {
        // getStats can fail if the peer connection is closing.
      }
    }
    if (!_disposed && latencies.isNotEmpty) {
      state = state.copyWith(peerLatencies: latencies);
    }
  }

  /// Periodically fetch voice participants from the server and reconcile
  /// with local peer state. Catches stale peers that may have disconnected
  /// without sending a proper leave event.
  bool _disposed = false;

  void _startPeriodicParticipantSync(String conversationId, String channelId) {
    _participantSyncTimer?.cancel();
    _participantSyncTimer = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) async {
      if (_disposed) {
        _participantSyncTimer?.cancel();
        _participantSyncTimer = null;
        return;
      }
      if (!_isCurrentVoiceContext(conversationId, channelId)) {
        _participantSyncTimer?.cancel();
        _participantSyncTimer = null;
        return;
      }

      try {
        final authBefore = ref.read(authProvider);
        final voiceSettings = ref.read(voiceSettingsProvider);

        await ref
            .read(channelsProvider.notifier)
            .updateVoiceState(
              conversationId: conversationId,
              channelId: channelId,
              isMuted: voiceSettings.selfMuted,
              isDeafened: voiceSettings.selfDeafened,
              pushToTalk: voiceSettings.pushToTalkEnabled,
            );

        await ref
            .read(channelsProvider.notifier)
            .loadVoiceSessions(conversationId, channelId);

        final authAfter = ref.read(authProvider);
        if (authBefore.isLoggedIn && !authAfter.isLoggedIn) {
          _participantSyncTimer?.cancel();
          _participantSyncTimer = null;
          await leaveChannel();
          if (!_disposed) {
            state = state.copyWith(
              error: 'Voice disconnected. Please sign in again.',
            );
          }
          return;
        }

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
        DebugLogService.instance.log(
          LogLevel.warning,
          'VoiceRTC',
          'Periodic sync failed: $e',
        );
      }
    });
  }

  @override
  void dispose() {
    _disposed = true;
    _participantSyncTimer?.cancel();
    _latencyTimer?.cancel();
    _audioLevelTimer?.cancel();
    _signalSubscription?.cancel();
    unawaited(leaveChannel());
    super.dispose();
  }
}

/// Legacy P2P WebRTC voice provider. Kept as a fallback; primary voice is now
/// handled by [livekitVoiceProvider] in `livekit_voice_provider.dart`.
final legacyVoiceRtcProvider =
    StateNotifierProvider<VoiceRtcNotifier, VoiceRtcState>((ref) {
      return VoiceRtcNotifier(ref);
    });
