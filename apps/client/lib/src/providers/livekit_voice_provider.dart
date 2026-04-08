import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';

import '../services/debug_log_service.dart';
import '../services/sound_service.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';
import 'voice_settings_provider.dart';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

class LiveKitVoiceState {
  final bool isActive;
  final bool isJoining;
  final bool isCaptureEnabled;
  final bool isDeafened;
  final bool isVideoEnabled;

  /// Video bitrate in bits per second (e.g. 500000 = 500kbps).
  final int videoBitrate;

  /// Video frames per second.
  final int videoFps;

  /// When true, LiveKit adaptive stream handles quality automatically.
  final bool autoQuality;
  final String? conversationId;
  final String? channelId;
  final Map<String, double> peerAudioLevels;
  final double localAudioLevel;

  /// Number of remote participants currently in the room.
  final int peerCount;

  /// Mapped as peer identity -> "connected" for compatibility with widgets
  /// that previously read `peerConnectionStates`.
  final Map<String, String> peerConnectionStates;
  final Map<String, double> peerLatencies;
  final String? error;

  const LiveKitVoiceState({
    this.isActive = false,
    this.isJoining = false,
    this.isCaptureEnabled = true,
    this.isDeafened = false,
    this.isVideoEnabled = false,
    this.videoBitrate = 500000,
    this.videoFps = 24,
    this.autoQuality = false,
    this.conversationId,
    this.channelId,
    this.peerAudioLevels = const {},
    this.localAudioLevel = 0.0,
    this.peerCount = 0,
    this.peerConnectionStates = const {},
    this.peerLatencies = const {},
    this.error,
  });

  LiveKitVoiceState copyWith({
    bool? isActive,
    bool? isJoining,
    bool? isCaptureEnabled,
    bool? isDeafened,
    bool? isVideoEnabled,
    int? videoBitrate,
    int? videoFps,
    bool? autoQuality,
    String? conversationId,
    String? channelId,
    Map<String, double>? peerAudioLevels,
    double? localAudioLevel,
    int? peerCount,
    Map<String, String>? peerConnectionStates,
    Map<String, double>? peerLatencies,
    String? error,
  }) {
    return LiveKitVoiceState(
      isActive: isActive ?? this.isActive,
      isJoining: isJoining ?? this.isJoining,
      isCaptureEnabled: isCaptureEnabled ?? this.isCaptureEnabled,
      isDeafened: isDeafened ?? this.isDeafened,
      isVideoEnabled: isVideoEnabled ?? this.isVideoEnabled,
      videoBitrate: videoBitrate ?? this.videoBitrate,
      videoFps: videoFps ?? this.videoFps,
      autoQuality: autoQuality ?? this.autoQuality,
      conversationId: conversationId ?? this.conversationId,
      channelId: channelId ?? this.channelId,
      peerAudioLevels: peerAudioLevels ?? this.peerAudioLevels,
      localAudioLevel: localAudioLevel ?? this.localAudioLevel,
      peerCount: peerCount ?? this.peerCount,
      peerConnectionStates: peerConnectionStates ?? this.peerConnectionStates,
      peerLatencies: peerLatencies ?? this.peerLatencies,
      error: error,
    );
  }

  static const empty = LiveKitVoiceState();
}

// ---------------------------------------------------------------------------
// Notifier
// ---------------------------------------------------------------------------

class LiveKitVoiceNotifier extends StateNotifier<LiveKitVoiceState> {
  final Ref ref;

  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  Timer? _audioLevelTimer;
  bool _disposed = false;

  /// Tracks whether mic was muted before deafening so un-deafen restores
  /// the previous mute state instead of always enabling the mic.
  bool _wasMutedBeforeDeafen = false;

  LiveKitVoiceNotifier(this.ref) : super(LiveKitVoiceState.empty);

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Join a voice channel by requesting a LiveKit token from the server and
  /// connecting to the LiveKit SFU room.
  Future<void> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async {
    if (_disposed) return;

    // Already in this exact channel -- nothing to do.
    if (state.isActive &&
        state.conversationId == conversationId &&
        state.channelId == channelId) {
      return;
    }

    // Leave any existing channel first.
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
      // 1. Fetch a LiveKit JWT from the Echo server.
      final tokenResult = await _fetchLiveKitToken(conversationId, channelId);
      if (tokenResult == null) {
        state = state.copyWith(
          isJoining: false,
          error: 'Failed to obtain voice token',
        );
        return;
      }

      final livekitUrl = tokenResult.url;
      final livekitToken = tokenResult.token;

      // 2. Create and connect a LiveKit Room.
      final voiceSettings = ref.read(voiceSettingsProvider);
      final room = Room(
        roomOptions: RoomOptions(
          adaptiveStream: true,
          dynacast: true,
          defaultAudioCaptureOptions: AudioCaptureOptions(
            noiseSuppression: voiceSettings.noiseSuppression,
            echoCancellation: voiceSettings.echoCancellation,
            autoGainControl: voiceSettings.autoGainControl,
          ),
          defaultAudioPublishOptions: const AudioPublishOptions(
            audioBitrate: AudioPreset.speech,
          ),
          defaultVideoPublishOptions: VideoPublishOptions(
            videoEncoding: VideoEncoding(
              maxBitrate: state.videoBitrate,
              maxFramerate: state.videoFps,
            ),
          ),
        ),
      );
      _room = room;

      _attachRoomListeners(room);

      await room.connect(livekitUrl, livekitToken);

      // Set display name so peers see a username instead of a UUID identity.
      final username = ref.read(authProvider).username;
      if (username != null && username.isNotEmpty) {
        room.localParticipant?.setName(username);
      }

      // 3. Enable microphone (unless starting muted).
      final micEnabled = !startMuted;
      await room.localParticipant?.setMicrophoneEnabled(micEnabled);

      state = state.copyWith(
        isJoining: false,
        isActive: true,
        isCaptureEnabled: micEnabled,
        error: null,
      );

      _syncPeerState();
      _startAudioLevelPolling();
      SoundService().playVoiceJoin();

      DebugLogService.instance.log(
        LogLevel.info,
        'LiveKitVoice',
        'Joined room for channel $channelId',
      );
    } catch (e) {
      debugPrint('[LiveKitVoice] join failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'Join failed: $e',
      );
      await _cleanupRoom();
      state = state.copyWith(
        isJoining: false,
        isActive: false,
        error: 'Failed to join voice channel',
      );
    }
  }

  /// Disconnect from the LiveKit room and reset state.
  Future<void> leaveChannel() async {
    if (state.isActive) {
      SoundService().playVoiceLeave();
    }
    try {
      await _cleanupRoom();
    } catch (e) {
      // Ensure state is always cleaned up even if disconnect throws
      // (e.g. SocketException on connection timeout).
      debugPrint('[LiveKitVoice] cleanup error during leave: $e');
      DebugLogService.instance.log(
        LogLevel.warning,
        'LiveKitVoice',
        'Cleanup error during leave (ignored): $e',
      );
    }
    state = LiveKitVoiceState.empty;
  }

  /// Enable or disable the local microphone.
  void setCaptureEnabled(bool enabled) {
    _room?.localParticipant?.setMicrophoneEnabled(enabled);
    state = state.copyWith(isCaptureEnabled: enabled);
  }

  /// Mute/unmute all incoming audio from remote participants.
  ///
  /// Following Discord convention, deafening also mutes the microphone.
  /// Un-deafening restores mic to whatever state it was before deafening.
  Future<void> setDeafened(bool deafened) async {
    if (deafened) {
      _wasMutedBeforeDeafen = !state.isCaptureEnabled;
      setCaptureEnabled(false);
    } else {
      if (!_wasMutedBeforeDeafen) {
        setCaptureEnabled(true);
      }
    }

    // Disable/enable audio on all remote participant tracks.
    final room = _room;
    if (room != null) {
      for (final participant in room.remoteParticipants.values) {
        for (final pub in participant.audioTrackPublications) {
          final track = pub.track;
          if (track != null) {
            if (deafened) {
              await track.disable();
            } else {
              await track.enable();
            }
          }
        }
      }
    }

    state = state.copyWith(isDeafened: deafened);
  }

  /// Toggle the local camera on/off.
  Future<void> toggleVideo() async {
    if (_disposed || !state.isActive) return;
    final room = _room;
    if (room == null) return;

    final enabled = !state.isVideoEnabled;
    try {
      await room.localParticipant?.setCameraEnabled(enabled);
      state = state.copyWith(isVideoEnabled: enabled);
    } catch (e) {
      debugPrint('[LiveKitVoice] toggleVideo failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'toggleVideo failed: $e',
      );
      state = state.copyWith(error: _friendlyMediaError(e, 'camera'));
    }
  }

  /// Enable or disable screen sharing via LiveKit.
  ///
  /// Uses the SDK's built-in [setScreenShareEnabled] which handles both
  /// capture (getDisplayMedia) and publishing the track to the room.
  Future<bool> setScreenShareEnabled(bool enabled) async {
    if (_disposed || !state.isActive) return false;
    final room = _room;
    if (room == null) return false;

    try {
      await room.localParticipant?.setScreenShareEnabled(enabled);
      return true;
    } catch (e) {
      debugPrint('[LiveKitVoice] setScreenShareEnabled($enabled) failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'Screen share toggle failed: $e',
      );
      state = state.copyWith(error: _friendlyMediaError(e, 'screen share'));
      return false;
    }
  }

  /// Change the video bitrate and FPS.
  ///
  /// Updates the encoding parameters on the currently published video track
  /// (if any) and stores the preference in state for future publishes.
  Future<void> setVideoParams({int? bitrate, int? fps}) async {
    state = state.copyWith(
      videoBitrate: bitrate ?? state.videoBitrate,
      videoFps: fps ?? state.videoFps,
    );

    await _applyVideoEncoding();
  }

  /// Toggle auto quality mode.
  ///
  /// When enabled, LiveKit adaptive stream manages quality automatically
  /// and manual bitrate/fps settings are ignored.
  Future<void> setAutoQuality(bool enabled) async {
    state = state.copyWith(autoQuality: enabled);
    // Auto quality is handled by the room's adaptiveStream option;
    // manual encoding is only applied when auto quality is off.
    if (!enabled) {
      await _applyVideoEncoding();
    }
  }

  /// Apply the current videoBitrate / videoFps to the active camera track.
  Future<void> _applyVideoEncoding() async {
    final room = _room;
    if (room == null || !state.isVideoEnabled || state.autoQuality) return;

    final cameraPub = room.localParticipant?.videoTrackPublications
        .where((pub) => pub.source == TrackSource.camera && pub.track != null)
        .firstOrNull;

    if (cameraPub != null) {
      try {
        await room.localParticipant?.publishVideoTrack(
          cameraPub.track!,
          publishOptions: VideoPublishOptions(
            videoEncoding: VideoEncoding(
              maxBitrate: state.videoBitrate,
              maxFramerate: state.videoFps,
            ),
          ),
        );
      } catch (e) {
        debugPrint('[LiveKitVoice] setVideoParams failed: $e');
        DebugLogService.instance.log(
          LogLevel.warning,
          'LiveKitVoice',
          'Video params change failed: $e',
        );
      }
    }
  }

  /// Map media errors to user-readable messages shown in the voice UI.
  static String _friendlyMediaError(Object e, String feature) {
    final msg = e.toString().toLowerCase();
    if (msg.contains('notallowederror') || msg.contains('not allowed')) {
      return '${feature[0].toUpperCase()}${feature.substring(1)} permission denied. '
          'Check your browser or system settings.';
    }
    if (msg.contains('source not found') || msg.contains('notfounderror')) {
      if (feature == 'screen share') {
        return 'No screen source found. On Linux, ensure PipeWire and '
            'xdg-desktop-portal are running.';
      }
      return 'No $feature device found.';
    }
    if (msg.contains('not supported') || msg.contains('notsupportederror')) {
      return '${feature[0].toUpperCase()}${feature.substring(1)} is not supported '
          'on this platform.';
    }
    return 'Failed to enable $feature.';
  }

  /// Access the LiveKit [Room] directly for advanced widget rendering
  /// (e.g. [VideoTrackRenderer]).
  Room? get room => _room;

  // -------------------------------------------------------------------------
  // Token fetching
  // -------------------------------------------------------------------------

  Future<_LiveKitTokenResult?> _fetchLiveKitToken(
    String conversationId,
    String channelId,
  ) async {
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    if (token == null) return null;

    try {
      final resp = await http.post(
        Uri.parse('$serverUrl/api/voice/token'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $token',
        },
        body: jsonEncode({
          'conversation_id': conversationId,
          'channel_id': channelId,
        }),
      );

      if (resp.statusCode == 200) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        final lkToken = data['token'] as String?;
        // Server may not return url — derive from serverUrl
        final lkUrl = data['url'] as String? ?? _deriveLiveKitUrl(serverUrl);

        if (lkToken != null) {
          debugPrint('[LiveKitVoice] token obtained, connecting to $lkUrl');
          return _LiveKitTokenResult(url: lkUrl, token: lkToken);
        }
      }

      debugPrint(
        '[LiveKitVoice] token request failed: ${resp.statusCode} ${resp.body}',
      );
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'Token request failed: ${resp.statusCode}',
      );
    } catch (e) {
      debugPrint('[LiveKitVoice] token fetch error: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'Token fetch error: $e',
      );
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // Room event listeners
  // -------------------------------------------------------------------------

  void _attachRoomListeners(Room room) {
    _roomListener = room.createListener();
    final listener = _roomListener!;

    listener
      ..on<ParticipantConnectedEvent>((event) {
        _syncPeerState();
        DebugLogService.instance.log(
          LogLevel.info,
          'LiveKitVoice',
          'Participant joined: ${event.participant.identity}',
        );
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        _syncPeerState();
        DebugLogService.instance.log(
          LogLevel.info,
          'LiveKitVoice',
          'Participant left: ${event.participant.identity}',
        );
      })
      ..on<TrackSubscribedEvent>((event) {
        _syncPeerState();
      })
      ..on<TrackUnsubscribedEvent>((event) {
        _syncPeerState();
      })
      ..on<RoomDisconnectedEvent>((_) {
        DebugLogService.instance.log(
          LogLevel.warning,
          'LiveKitVoice',
          'Room disconnected',
        );
        if (!_disposed) {
          state = state.copyWith(
            isActive: false,
            error: 'Disconnected from voice channel',
          );
        }
      })
      ..on<RoomReconnectedEvent>((_) {
        DebugLogService.instance.log(
          LogLevel.info,
          'LiveKitVoice',
          'Room reconnected',
        );
        _syncPeerState();
      })
      ..on<RoomReconnectingEvent>((_) {
        DebugLogService.instance.log(
          LogLevel.warning,
          'LiveKitVoice',
          'Room reconnecting...',
        );
      });
  }

  /// Synchronize the participant list from the LiveKit room into our state.
  void _syncPeerState() {
    final room = _room;
    if (room == null || _disposed) return;

    final participants = room.remoteParticipants;
    final peerStates = <String, String>{};
    for (final p in participants.values) {
      final String label;
      if (p.name.isNotEmpty) {
        label = p.name;
      } else if (p.identity.isNotEmpty) {
        label = p.identity;
      } else {
        label = p.sid.toString();
      }
      peerStates[label] = 'connected';
    }

    state = state.copyWith(
      peerCount: participants.length,
      peerConnectionStates: peerStates,
    );
  }

  // -------------------------------------------------------------------------
  // Audio level polling
  // -------------------------------------------------------------------------

  void _startAudioLevelPolling() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer = Timer.periodic(
      const Duration(milliseconds: 100),
      (_) => _pollAudioLevels(),
    );
  }

  void _stopAudioLevelPolling() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer = null;
  }

  void _pollAudioLevels() {
    final room = _room;
    if (room == null || _disposed) return;

    // Local audio level.
    final localLevel = room.localParticipant?.audioLevel ?? 0.0;

    // Remote audio levels -- keyed by identity (stable, unique per participant)
    // so the voice lounge UI can look them up consistently.
    final peerLevels = <String, double>{};
    for (final p in room.remoteParticipants.values) {
      final key = p.identity.isNotEmpty ? p.identity : p.sid.toString();
      peerLevels[key] = p.audioLevel;
    }

    if (!_disposed) {
      state = state.copyWith(
        localAudioLevel: localLevel,
        peerAudioLevels: peerLevels,
      );
    }
  }

  // -------------------------------------------------------------------------
  // Cleanup
  // -------------------------------------------------------------------------

  Future<void> _cleanupRoom() async {
    _stopAudioLevelPolling();
    _roomListener?.dispose();
    _roomListener = null;

    final room = _room;
    _room = null;
    if (room != null) {
      try {
        await room.disconnect();
      } catch (_) {
        // SocketException / TimeoutException on flaky connections -- ignore.
      }
      try {
        await room.dispose();
      } catch (_) {
        // Dispose may throw if disconnect left resources in a bad state.
      }
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _stopAudioLevelPolling();

    // Synchronously null out references so in-flight callbacks hit null checks
    // instead of accessing freed memory. The actual network disconnect is
    // fire-and-forget on captured local references.
    final listener = _roomListener;
    final room = _room;
    _roomListener = null;
    _room = null;
    listener?.dispose();
    if (room != null) {
      unawaited(
        room.disconnect().then((_) => room.dispose()).catchError((_) => false),
      );
    }

    super.dispose();
  }
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

class _LiveKitTokenResult {
  final String url;
  final String token;
  const _LiveKitTokenResult({required this.url, required this.token});
}

/// Derive LiveKit WebSocket URL from the Echo server URL.
/// https://echo-messenger.us → wss://livekit.echo-messenger.us
String _deriveLiveKitUrl(String serverUrl) {
  final uri = Uri.parse(serverUrl);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  return '$scheme://livekit.${uri.host}';
}

// ---------------------------------------------------------------------------
// Provider
// ---------------------------------------------------------------------------

/// Primary voice provider using LiveKit SFU.
final livekitVoiceProvider =
    StateNotifierProvider<LiveKitVoiceNotifier, LiveKitVoiceState>(
      (ref) => LiveKitVoiceNotifier(ref),
    );

/// Convenience aliases so widgets/tests can use old names without mass-renaming.
final voiceRtcProvider = livekitVoiceProvider;
typedef VoiceRtcState = LiveKitVoiceState;
typedef VoiceRtcNotifier = LiveKitVoiceNotifier;
