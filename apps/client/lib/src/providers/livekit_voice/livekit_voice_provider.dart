import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../services/background_service.dart';
import '../../services/debug_log_service.dart';
import '../../services/pip_controller.dart';
import '../../services/sound_service.dart';
import '../../services/voice_callkit_service.dart';
import '../auth_provider.dart';
import '../channels_provider.dart';
import '../server_url_provider.dart';
import '../voice_settings_provider.dart';

part 'livekit_voice_provider.g.dart';
part 'livekit_voice_av_controls.dart';

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

  /// Identities currently flagged as active speakers by LiveKit's
  /// server-side detector. Push-based via `ActiveSpeakersChangedEvent`,
  /// so the speaker outline reacts within network RTT (~30-50ms) rather
  /// than waiting for the local audio-level poll to ramp up (#907).
  final Set<String> activeSpeakerIdentities;

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
    this.videoBitrate = 1500000,
    this.videoFps = 30,
    this.autoQuality = true,
    this.conversationId,
    this.channelId,
    this.peerAudioLevels = const {},
    this.localAudioLevel = 0.0,
    this.activeSpeakerIdentities = const {},
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
    Set<String>? activeSpeakerIdentities,
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
      activeSpeakerIdentities:
          activeSpeakerIdentities ?? this.activeSpeakerIdentities,
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

/// Facade for the LiveKit voice notifier — owns shared state, connection
/// lifecycle (`joinChannel` / `leaveChannel` / `dispose`), the room event
/// listener, peer-state sync, audio-level polling, and the LiveKit JWT
/// fetch. AV controls (mic / camera / screen share / video quality) live
/// in [LiveKitVoiceAvControlsMixin] in `livekit_voice_av_controls.dart`.
@Riverpod(keepAlive: true)
class LiveKitVoiceNotifier extends _$LiveKitVoiceNotifier
    with LiveKitVoiceAvControlsMixin {
  @override
  Room? _room;
  EventsListener<RoomEvent>? _roomListener;
  Timer? _audioLevelTimer;
  @override
  bool _disposed = false;

  @override
  bool _wasMutedBeforeDeafen = false;

  /// Subscription to the foreground-service notification actions so the
  /// Mute / Leave buttons in the live notification map back into LiveKit
  /// state changes.  Active only while a voice room is connected.
  StreamSubscription<VoiceNotificationAction>? _notificationActionSub;

  /// Subscription to CallKit lock-screen actions on iOS.  Same lifecycle
  /// as the Android notification action sub — active only during a call.
  StreamSubscription<CallKitAction>? _callKitActionSub;

  @override
  LiveKitVoiceState build() {
    ref.onDispose(_handleDispose);
    return LiveKitVoiceState.empty;
  }

  /// Resolve the human-readable channel name for the active room so the
  /// voice notification can show "lounge" instead of a UUID.  Falls back
  /// to "Voice" when the channel hasn't been hydrated yet.
  String _resolveChannelName(String conversationId, String channelId) {
    final channels = ref.read(channelsProvider).channelsFor(conversationId);
    final match = channels.where((c) => c.id == channelId).firstOrNull;
    final name = match?.name;
    if (name == null || name.isEmpty) return 'Voice';
    return name;
  }

  void _attachNotificationActionListener() {
    _notificationActionSub ??= BackgroundService.instance.notificationActions
        .listen((action) {
          switch (action) {
            case VoiceMuteAction(muted: final muted):
              // Notification button maps "muted=true" → mic off.
              setCaptureEnabled(!muted);
            case VoiceLeaveAction():
              unawaited(leaveChannel());
          }
        });
    _callKitActionSub ??= VoiceCallKitService.instance.actions.listen((action) {
      switch (action) {
        case CallKitMuteAction(muted: final muted):
          setCaptureEnabled(!muted);
        case CallKitEndAction():
          unawaited(leaveChannel());
      }
    });
  }

  void _detachNotificationActionListener() {
    _notificationActionSub?.cancel();
    _notificationActionSub = null;
    _callKitActionSub?.cancel();
    _callKitActionSub = null;
  }

  /// Push the latest voice state into the live notification + CallKit
  /// entry.  No-op on platforms that don't surface either.
  void _syncVoiceNotification() {
    if (_disposed || !state.isActive) return;
    unawaited(
      BackgroundService.instance.updateVoice(
        isMuted: !state.isCaptureEnabled,
        participantCount: state.peerCount + 1,
      ),
    );
    unawaited(VoiceCallKitService.instance.setMuted(!state.isCaptureEnabled));
  }

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

    String? attemptedUrl;
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
      attemptedUrl = livekitUrl;
      DebugLogService.instance.log(
        LogLevel.info,
        'LiveKitVoice',
        'Connecting to $livekitUrl (token len=${livekitToken.length})',
      );

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
            encoding: AudioEncoding.presetMusic,
            dtx: true,
          ),
          defaultCameraCaptureOptions: const CameraCaptureOptions(
            params: VideoParametersPresets.h720_169,
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

      // Promote the foreground service to voice mode (Android) and report
      // an outgoing CallKit call (iOS) so the OS keeps the mic + audio
      // session alive when the app is backgrounded.  Listen for Mute /
      // Leave / End taps coming back from either UI.
      final resolvedChannelName = _resolveChannelName(
        conversationId,
        channelId,
      );
      _attachNotificationActionListener();
      unawaited(
        BackgroundService.instance.startVoice(
          channelName: resolvedChannelName,
          isMuted: !micEnabled,
          participantCount: state.peerCount + 1,
        ),
      );
      unawaited(
        VoiceCallKitService.instance.startCall(
          // CallKit identifies the call by id; use the room's conversation
          // + channel pair so a future "rejoin same room" call is a no-op.
          callId: '$conversationId:$channelId',
          channelName: resolvedChannelName,
          isMuted: !micEnabled,
        ),
      );

      DebugLogService.instance.log(
        LogLevel.info,
        'LiveKitVoice',
        'Joined room for channel $channelId',
      );
    } catch (e) {
      // Surface the URL we tried so a 404 / DNS failure points ops at the
      // exact subdomain that needs DNS or Traefik attention.
      final tried = attemptedUrl ?? '<token-fetch>';
      debugPrint('[LiveKitVoice] join failed at $tried: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'LiveKitVoice',
        'Join failed at $tried: $e',
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
    _detachNotificationActionListener();
    unawaited(BackgroundService.instance.stopVoice());
    unawaited(VoiceCallKitService.instance.endCall());
    unawaited(PipController.instance.disable());
    state = LiveKitVoiceState.empty;
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
        SoundService().playVoiceJoin();
        DebugLogService.instance.log(
          LogLevel.info,
          'LiveKitVoice',
          'Participant joined: ${event.participant.identity}',
        );
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        _syncPeerState();
        SoundService().playVoiceLeave();
        DebugLogService.instance.log(
          LogLevel.info,
          'LiveKitVoice',
          'Participant left: ${event.participant.identity}',
        );
      })
      ..on<TrackSubscribedEvent>((event) {
        _syncPeerState();
        _syncRemoteScreenShareForPip();
      })
      ..on<TrackUnsubscribedEvent>((event) {
        _syncPeerState();
        _syncRemoteScreenShareForPip();
      })
      ..on<ActiveSpeakersChangedEvent>((event) {
        if (_disposed) return;
        // Push-based: reacts within ~RTT to the server-side detector,
        // rather than waiting for the 100ms local audio-level poll to
        // ramp past the static threshold (#907).
        final ids = <String>{};
        for (final p in event.speakers) {
          final id = p.identity.isNotEmpty ? p.identity : p.sid.toString();
          ids.add(id);
        }
        state = state.copyWith(activeSpeakerIdentities: ids);
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

  /// Walk the remote participants for an active screen-share video track
  /// and tell [PipController] whether to keep the activity PiP-eligible.
  /// Pure idempotent — safe to call from any TrackSubscribed /
  /// TrackUnsubscribed event without checking which track changed.
  void _syncRemoteScreenShareForPip() {
    final room = _room;
    if (room == null || _disposed) return;
    for (final participant in room.remoteParticipants.values) {
      for (final pub in participant.videoTrackPublications) {
        if (pub.track != null &&
            pub.subscribed &&
            pub.source == TrackSource.screenShareVideo) {
          // Native side stores 16:9 default when 0 is passed; LiveKit
          // doesn't surface frame dimensions synchronously, so we accept
          // a slightly-off aspect for the first PiP entry.  Frame-size
          // tracking via VideoTrackRenderer is a follow-up.
          unawaited(PipController.instance.enable(width: 0, height: 0));
          return;
        }
      }
    }
    unawaited(PipController.instance.disable());
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

    // Keep the live notification's participant count fresh as people come
    // and go.  No-op on platforms that don't surface a foreground service.
    _syncVoiceNotification();
  }

  /// Override the AV mixin's mute toggle so the live notification keeps
  /// step with the LiveKit mic state.  Optimistic — the foreground service
  /// re-issues the notification when [updateVoice] returns.
  @override
  void setCaptureEnabled(bool enabled) {
    super.setCaptureEnabled(enabled);
    _syncVoiceNotification();
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

  /// Wired up via `ref.onDispose` in `build()`. Mirrors the StateNotifier-era
  /// `dispose()` override so timers, notifications, and the LiveKit room
  /// are released when the provider is invalidated.
  void _handleDispose() {
    _disposed = true;
    _stopAudioLevelPolling();
    _detachNotificationActionListener();
    unawaited(BackgroundService.instance.stopVoice());
    unawaited(VoiceCallKitService.instance.endCall());

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
///
/// Back-compat alias — the generated provider is
/// [liveKitVoiceNotifierProvider]; we re-export the historical short name
/// here so the ~80 existing call sites and tests do not change.
final livekitVoiceProvider = liveKitVoiceNotifierProvider;

/// Convenience aliases so widgets/tests can use old names without mass-renaming.
final voiceRtcProvider = livekitVoiceProvider;
typedef VoiceRtcState = LiveKitVoiceState;
typedef VoiceRtcNotifier = LiveKitVoiceNotifier;
