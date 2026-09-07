import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:livekit_client/livekit_client.dart';
import 'package:record/record.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../../screens/voice_lounge/participant_volume_controller.dart';
import '../../services/background_service.dart';
import '../../services/debug_log_service.dart';
import '../../services/pip_controller.dart';
import '../../services/push_to_talk_listener.dart';
import '../../services/sound_service.dart';
import '../../services/voice_callkit_service.dart';
import '../auth_provider.dart';
import '../channels_provider.dart';
import '../server_url_provider.dart';
import '../voice_settings_provider.dart';
import 'rtc_stats_poll.dart';

part 'livekit_voice_provider.g.dart';
part 'livekit_voice_av_controls.dart';

/// Debug-log tag for this subsystem (one place, not a repeated literal — S1192).
const _kLogTag = 'LiveKitVoice';

// ---------------------------------------------------------------------------
// State
// ---------------------------------------------------------------------------

/// Sentinel for [LiveKitVoiceState.copyWith.callStartedAt] so callers can
/// explicitly reset the timestamp to `null` while a plain absent argument
/// preserves the existing value. Required because Dart's null-default
/// idiom collapses "not passed" and "passed null" into the same case.
const Object _callStartedAtSentinel = Object();

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

  /// LiveKit's coarse connection-quality measurement for the local
  /// participant. Updated via `ParticipantConnectionQualityUpdatedEvent`.
  /// Surfaces as a colored badge in the voice dock so beta testers can
  /// diagnose call quality at a glance (#906).
  final ConnectionQuality localConnectionQuality;

  /// Number of remote participants currently in the room.
  final int peerCount;

  /// Mapped as peer identity -> "connected" for compatibility with widgets
  /// that previously read `peerConnectionStates`.
  final Map<String, String> peerConnectionStates;
  final Map<String, double> peerLatencies;
  final String? error;

  /// Wall-clock timestamp when the local participant successfully joined the
  /// LiveKit room. `null` while idle / joining. Drives the M:SS call-duration
  /// label rendered in the voice dock (#925).
  final DateTime? callStartedAt;

  /// Most recent outbound audio bitrate (bits per second) sampled from the
  /// LiveKit peer connections via `RtcStatsPoll`. `0` while idle or before
  /// the first poll tick.  Surfaced in the dock connection-quality tooltip
  /// (#937, follow-up to #906).
  final int audioBitrateBps;

  /// Most recent round-trip time (milliseconds) for the selected ICE
  /// candidate pair. `0` while idle or before the first poll tick.
  final double rttMs;

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
    this.localConnectionQuality = ConnectionQuality.unknown,
    this.peerCount = 0,
    this.peerConnectionStates = const {},
    this.peerLatencies = const {},
    this.error,
    this.callStartedAt,
    this.audioBitrateBps = 0,
    this.rttMs = 0,
  });

  // S107: copyWith mirrors 21 independent fields; grouping would break call sites.
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
    ConnectionQuality? localConnectionQuality,
    int? peerCount,
    Map<String, String>? peerConnectionStates,
    Map<String, double>? peerLatencies,
    String? error,
    Object? callStartedAt = _callStartedAtSentinel,
    int? audioBitrateBps,
    double? rttMs,
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
      localConnectionQuality:
          localConnectionQuality ?? this.localConnectionQuality,
      peerCount: peerCount ?? this.peerCount,
      peerConnectionStates: peerConnectionStates ?? this.peerConnectionStates,
      peerLatencies: peerLatencies ?? this.peerLatencies,
      error: error,
      callStartedAt: identical(callStartedAt, _callStartedAtSentinel)
          ? this.callStartedAt
          : callStartedAt as DateTime?,
      audioBitrateBps: audioBitrateBps ?? this.audioBitrateBps,
      rttMs: rttMs ?? this.rttMs,
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
  RtcStatsPoll? _rtcStatsPoll;
  @override
  bool _disposed = false;

  /// True while a join sequence is in progress.  Prevents a second
  /// [joinChannel] call from racing the first when the user taps a new
  /// lounge before the previous one finishes connecting or tearing down.
  bool _isJoining = false;

  @override
  bool _wasMutedBeforeDeafen = false;

  /// Subscription to the foreground-service notification actions so the
  /// Mute / Leave buttons in the live notification map back into LiveKit
  /// state changes.  Active only while a voice room is connected.
  StreamSubscription<VoiceNotificationAction>? _notificationActionSub;

  /// Subscription to CallKit lock-screen actions on iOS.  Same lifecycle
  /// as the Android notification action sub — active only during a call.
  StreamSubscription<CallKitAction>? _callKitActionSub;

  /// Push-to-talk keyboard listener.  Non-null only while a room is active
  /// and the user has PTT enabled in voice settings.
  PushToTalkListener? _pttListener;

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
              unawaited(
                leaveChannel().catchError((e, st) {
                  debugPrint('[livekit] notification leave failed: $e');
                }),
              );
          }
        });
    _callKitActionSub ??= VoiceCallKitService.instance.actions.listen((action) {
      switch (action) {
        case CallKitMuteAction(muted: final muted):
          setCaptureEnabled(!muted);
        case CallKitEndAction():
          unawaited(
            leaveChannel().catchError((e, st) {
              debugPrint('[livekit] callkit leave failed: $e');
            }),
          );
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
      BackgroundService.instance
          .updateVoice(
            isMuted: !state.isCaptureEnabled,
            participantCount: state.peerCount + 1,
          )
          .catchError((e, st) {
            debugPrint('[livekit] update voice notification failed: $e');
          }),
    );
    unawaited(
      VoiceCallKitService.instance.setMuted(!state.isCaptureEnabled).catchError(
        (e, st) {
          debugPrint('[livekit] set callkit muted failed: $e');
        },
      ),
    );
  }

  // -------------------------------------------------------------------------
  // Public API
  // -------------------------------------------------------------------------

  /// Join a voice channel by requesting a LiveKit token from the server and
  /// connecting to the LiveKit SFU room.
  ///
  /// Returns `true` only when the LiveKit room is actually connected and the
  /// session is active. Returns `false` on any failure (timeout, track-publish
  /// error, denied permission) — callers MUST gate their success side-effects
  /// (highlighting the chip, showing the lounge, announcing "call started") on
  /// this result. The method swallows its own exceptions, so a `false` return
  /// is the only failure signal; treating a completed Future as "joined" leaves
  /// the chip highlighted after a failed join (the stuck-lounge bug).
  Future<bool> joinChannel({
    required String conversationId,
    required String channelId,
    bool startMuted = false,
  }) async {
    if (_disposed) return false;

    // Prevent concurrent join sequences from racing (tap new lounge mid-join).
    if (_isJoining) {
      DebugLogService.instance.log(
        LogLevel.warning,
        _kLogTag,
        'joinChannel: ignored — join already in progress for $channelId',
      );
      return false;
    }

    // Already in this exact channel -- nothing to do.
    if (state.isActive &&
        state.conversationId == conversationId &&
        state.channelId == channelId) {
      return true;
    }

    _isJoining = true;

    // Switching between voice channels across groups: tell the server we
    // left the previous voice session BEFORE joining the new one. Without
    // this the server keeps the old session row alive, fans out voice
    // signaling for two channels to this client, and the UI references a
    // disposed Room while the new one is mid-connect — crashes on switch.
    final prevConvId = state.conversationId;
    final prevChanId = state.channelId;
    if (state.isActive &&
        prevConvId != null &&
        prevChanId != null &&
        (prevConvId != conversationId || prevChanId != channelId)) {
      try {
        await ref
            .read(channelsProvider.notifier)
            .leaveVoiceChannel(prevConvId, prevChanId);
      } catch (e) {
        // leaveVoiceChannel already handles its own errors (returns false);
        // catch is belt-and-suspenders for unexpected throws so the new
        // join isn't blocked by a transient leave failure.
        DebugLogService.instance.log(
          LogLevel.warning,
          _kLogTag,
          'leaveVoiceChannel($prevConvId/$prevChanId) before switch threw '
          '(ignored): $e',
        );
      }
    }

    // Await full teardown before new join: prevents EventChannel stream collision
    // (PlatformException "No active stream to cancel") on the LiveKit native side.
    await _teardownCurrent();

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
      // Breadcrumb 0-4: mic permission, token, room, connect, setName, mic enable
      final joinResult = await _performJoinSequence(
        conversationId,
        channelId,
        startMuted,
      );
      attemptedUrl = joinResult.attemptedUrl;
      final room = joinResult.room;
      final micEnabled = joinResult.micEnabled;

      // Breadcrumb 5: foreground service + CallKit
      await _setupBackgroundServices(
        conversationId,
        channelId,
        room,
        micEnabled,
      );

      DebugLogService.instance.log(
        LogLevel.info,
        _kLogTag,
        'joinChannel: successfully joined channel $channelId',
      );
      return true;
    } catch (e) {
      // Surface URL on failure so a 404/DNS error points ops at the right subdomain.
      final tried = attemptedUrl ?? '<token-fetch>';
      debugPrint('[LiveKitVoice] join failed at $tried: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'joinChannel: failed at $tried: $e',
      );
      await _cleanupRoom();
      state = state.copyWith(
        isJoining: false,
        isActive: false,
        error: 'Failed to join voice channel',
      );
      return false;
    } finally {
      _isJoining = false;
    }
  }

  /// Perform the ordered join sequence: mic permission → token → room → connect
  /// → setName → mic enable → PTT setup. Returns room and mic state.
  Future<({String? attemptedUrl, Room room, bool micEnabled})>
  _performJoinSequence(
    String conversationId,
    String channelId,
    bool startMuted,
  ) async {
    // iOS: mic permission MUST resolve before room.connect / setMicrophoneEnabled
    // or AVAudioSession activation races the TCC prompt and the watchdog SIGKILLs
    // the app after ~22s of blocked main thread.
    final micPermitted = await _requestMicrophonePermission();
    if (!micPermitted) {
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'joinChannel: microphone permission denied — aborting',
      );
      state = state.copyWith(
        isJoining: false,
        isActive: false,
        error: 'Microphone access is required to join a voice channel',
      );
      throw Exception('Microphone permission denied');
    }

    // ---- breadcrumb 1: token fetch ----------------------------------------
    _LiveKitTokenResult? tokenResult;
    try {
      tokenResult = await _fetchLiveKitToken(conversationId, channelId);
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'joinChannel: token fetch threw: $e',
      );
      rethrow;
    }

    if (tokenResult == null) {
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'joinChannel: token fetch returned null — aborting',
      );
      state = state.copyWith(
        isJoining: false,
        error: 'Failed to obtain voice token',
      );
      throw Exception('Token fetch returned null');
    }

    final livekitUrl = tokenResult.url;
    final livekitToken = tokenResult.token;

    // ---- breadcrumb 2: room creation ----------------------------------------
    final voiceSettings = ref.read(voiceSettingsProvider);
    late final Room room;
    try {
      room = Room(
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
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'joinChannel: Room() constructor threw: $e',
      );
      rethrow;
    }
    _room = room;
    _attachRoomListeners(room);

    // ---- breadcrumb 3: room.connect -----------------------------------------
    try {
      await room.connect(livekitUrl, livekitToken);
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'joinChannel: room.connect threw: $e',
      );
      rethrow;
    }

    // setName needs `canUpdateOwnMetadata` grant; missing grant closes signal
    // channel and breaks every subsequent call. Guard against grant regression.
    final username = ref.read(authProvider).username;
    if (username != null && username.isNotEmpty) {
      try {
        room.localParticipant?.setName(username);
      } catch (e) {
        DebugLogService.instance.log(
          LogLevel.warning,
          _kLogTag,
          'joinChannel: setName failed (non-fatal): $e',
        );
      }
    }

    // Mic permission already resolved at breadcrumb 0; this call is non-blocking.
    final micEnabled = !startMuted;
    try {
      await room.localParticipant?.setMicrophoneEnabled(micEnabled);
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
        'joinChannel: setMicrophoneEnabled threw: $e',
      );
      rethrow;
    }

    // PTT: force mic off at join regardless of startMuted, then arm key listener.
    final voiceSettingsForPtt = ref.read(voiceSettingsProvider);
    final pttActive = voiceSettingsForPtt.pushToTalkEnabled;
    if (pttActive) {
      await room.localParticipant?.setMicrophoneEnabled(false);
      _pttListener?.stop();
      _pttListener = PushToTalkListener(
        keyId: voiceSettingsForPtt.pushToTalkKeyId,
        onSetCaptureEnabled: setCaptureEnabled,
      )..start();
    }

    state = state.copyWith(
      isJoining: false,
      isActive: true,
      isCaptureEnabled: pttActive ? false : micEnabled,
      error: null,
      callStartedAt: DateTime.now(),
    );

    _syncPeerState();
    _startAudioLevelPolling();
    _startRtcStatsPolling(room);
    SoundService().playVoiceJoin();

    return (attemptedUrl: livekitUrl, room: room, micEnabled: micEnabled);
  }

  /// Setup background services and CallKit for voice channel.
  Future<void> _setupBackgroundServices(
    String conversationId,
    String channelId,
    Room room,
    bool micEnabled,
  ) async {
    final resolvedChannelName = _resolveChannelName(conversationId, channelId);
    DebugLogService.instance.log(
      LogLevel.info,
      _kLogTag,
      'joinChannel: starting background service / CallKit for "$resolvedChannelName"',
    );
    // Foreground service (Android) + CallKit (iOS) keep mic/audio alive when
    // backgrounded; listener routes their Mute/Leave taps back into state.
    _attachNotificationActionListener();
    unawaited(
      BackgroundService.instance
          .startVoice(
            channelName: resolvedChannelName,
            isMuted: !micEnabled,
            participantCount: state.peerCount + 1,
          )
          .catchError((e, st) {
            debugPrint('[livekit] start background voice service failed: $e');
          }),
    );
    unawaited(
      VoiceCallKitService.instance
          .startCall(
            // CallKit CXCall ID must be a valid UUID — Swift force-unwraps
            // UUID(uuidString:); a composite "convId:chanId" crashed every iOS join.
            callId: channelId,
            channelName: resolvedChannelName,
            isMuted: !micEnabled,
          )
          .catchError((e, st) {
            debugPrint('[livekit] start callkit call failed: $e');
          }),
    );
  }

  /// Fully tear down the current room, background services, and CallKit.
  ///
  /// Separated from [leaveChannel] so [joinChannel] can await a complete
  /// teardown before starting a new join — preventing the
  /// "No active stream to cancel" PlatformException that fires when a second
  /// LiveKit Room tries to open its EventChannel streams before the first
  /// Room's streams are fully closed.
  Future<void> _teardownCurrent() async {
    // Stop background/CallKit before room so OS audio session releases in order.
    _detachNotificationActionListener();
    unawaited(
      BackgroundService.instance.stopVoice().catchError((e, st) {
        debugPrint('[livekit] stop background voice service failed: $e');
      }),
    );
    unawaited(
      VoiceCallKitService.instance.endCall().catchError((e, st) {
        debugPrint('[livekit] end callkit call failed: $e');
      }),
    );
    unawaited(
      PipController.instance.disable().catchError((e, st) {
        debugPrint('[livekit] disable pip controller failed: $e');
      }),
    );

    try {
      await _cleanupRoom();
    } on PlatformException catch (e) {
      // Swallow LiveKit "No active stream to cancel" on double-teardown races.
      debugPrint(
        '[LiveKitVoice] PlatformException during teardown (ignored): $e',
      );
      DebugLogService.instance.log(
        LogLevel.warning,
        _kLogTag,
        'PlatformException during teardown (ignored): $e',
      );
    } catch (e) {
      // SocketException / TimeoutException on flaky connections.
      debugPrint('[LiveKitVoice] cleanup error during teardown: $e');
      DebugLogService.instance.log(
        LogLevel.warning,
        _kLogTag,
        'Cleanup error during teardown (ignored): $e',
      );
    }
  }

  /// True while a leave sequence is in progress.  Guards against concurrent
  /// callers (double-tap UI, notification action, CallKit — all fire
  /// leaveChannel independently).
  bool _isLeaving = false;

  /// Disconnect from the LiveKit room and reset state. Also clears the
  /// server-side voice session row so the user doesn't appear stuck in the
  /// lounge to other members.
  Future<void> leaveChannel() async {
    if (_disposed) return;
    if (_isLeaving) {
      DebugLogService.instance.log(
        LogLevel.warning,
        _kLogTag,
        'leaveChannel: ignored — leave already in progress',
      );
      return;
    }
    _isLeaving = true;
    try {
      final convId = state.conversationId;
      final chanId = state.channelId;
      if (state.isActive) {
        SoundService().playVoiceLeave();
      }
      await _teardownCurrent();
      state = LiveKitVoiceState.empty;
      if (convId != null && chanId != null) {
        try {
          await ref
              .read(channelsProvider.notifier)
              .leaveVoiceChannel(convId, chanId);
        } catch (e) {
          DebugLogService.instance.log(
            LogLevel.warning,
            _kLogTag,
            'leaveVoiceChannel($convId/$chanId) on leave threw (ignored): $e',
          );
        }
      }
    } finally {
      _isLeaving = false;
    }
  }

  /// Access the LiveKit [Room] directly for advanced widget rendering
  /// (e.g. [VideoTrackRenderer]).
  Room? get room => _room;

  // -------------------------------------------------------------------------
  // Mic permission
  // -------------------------------------------------------------------------

  /// Request microphone permission before handing off to LiveKit.
  ///
  /// On iOS the first call to `setMicrophoneEnabled` triggers the system
  /// mic-permission dialog *while* the AVAudioSession is mid-activation.
  /// If the user has never granted mic permission, iOS presents the dialog,
  /// the audio thread blocks waiting for the dialog result, and the
  /// AVAudioSession setActive call can deadlock — manifesting as a 27-second
  /// hang after which the watchdog kills the app.
  ///
  /// Pre-requesting permission here via the `record` package ensures the
  /// dialog fires in a clean, idle context.  If the user denies, we surface
  /// the error and abort before LiveKit ever touches the audio session.
  ///
  /// Returns `true` if mic is available (granted or already authorised),
  /// `false` if denied / permanently denied.
  Future<bool> _requestMicrophonePermission() async {
    // Web/desktop: WebRTC requests permission inline via browser-native dialog.
    if (kIsWeb ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.windows ||
        defaultTargetPlatform == TargetPlatform.macOS) {
      return true;
    }

    final recorder = AudioRecorder();
    try {
      final granted = await recorder.hasPermission();
      if (!granted) {
        DebugLogService.instance.log(
          LogLevel.error,
          _kLogTag,
          'Microphone permission denied — cannot join voice channel',
        );
      }
      return granted;
    } catch (e) {
      // Proceed optimistically: don't lock out users when the check itself fails.
      DebugLogService.instance.log(
        LogLevel.warning,
        _kLogTag,
        'Microphone permission check threw (proceeding optimistically): $e',
      );
      return true;
    } finally {
      await recorder.dispose();
    }
  }

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
        final lkUrl = data['url'] as String? ?? deriveLiveKitUrl(serverUrl);

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
        _kLogTag,
        'Token request failed: ${resp.statusCode}',
      );
    } catch (e) {
      debugPrint('[LiveKitVoice] token fetch error: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        _kLogTag,
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
          _kLogTag,
          'Participant joined: ${event.participant.identity}',
        );
      })
      ..on<ParticipantDisconnectedEvent>((event) {
        _syncPeerState();
        SoundService().playVoiceLeave();
        DebugLogService.instance.log(
          LogLevel.info,
          _kLogTag,
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
      ..on<ParticipantConnectionQualityUpdatedEvent>((event) {
        if (_disposed) return;
        // Only local quality drives the dock badge; remote is shown elsewhere.
        if (event.participant.identity == room.localParticipant?.identity) {
          state = state.copyWith(
            localConnectionQuality: event.connectionQuality,
          );
        }
      })
      ..on<ActiveSpeakersChangedEvent>((event) {
        if (_disposed) return;
        // Push-based: server-detected speakers react within RTT, not poll cadence (#907).
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
          _kLogTag,
          'Room disconnected',
        );
        // VL-11: a terminal disconnect (e.g. network drop) doesn't go through
        // leaveChannel/_cleanupRoom, so the 2s RTC-stats + audio-level timers
        // would keep reflecting into a dead room. Stop them here; they restart
        // on the next join. (Transient blips fire Reconnecting/Reconnected, not
        // Disconnected, so this doesn't kill polling across auto-reconnect.)
        _stopRtcStatsPolling();
        _stopAudioLevelPolling();
        if (!_disposed) {
          state = state.copyWith(
            isActive: false,
            error: 'Disconnected from voice channel',
            callStartedAt: null,
          );
        }
      })
      ..on<RoomReconnectedEvent>((_) {
        DebugLogService.instance.log(
          LogLevel.info,
          _kLogTag,
          'Room reconnected',
        );
        _syncPeerState();
      })
      ..on<RoomReconnectingEvent>((_) {
        DebugLogService.instance.log(
          LogLevel.warning,
          _kLogTag,
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
          // Native stores 16:9 default for 0/0; LiveKit dims aren't sync-available.
          unawaited(
            PipController.instance.enable(width: 0, height: 0).catchError((
              e,
              st,
            ) {
              debugPrint('[livekit] enable pip controller failed: $e');
            }),
          );
          return;
        }
      }
    }
    unawaited(
      PipController.instance.disable().catchError((e, st) {
        debugPrint('[livekit] disable pip controller failed: $e');
      }),
    );
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
    // Web CanvasKit repaint cost forces 250ms cadence (vs 100ms native) to avoid
    // tab crashes; _pollAudioLevels also dedups when values barely change.
    final interval = kIsWeb
        ? const Duration(milliseconds: 250)
        : const Duration(milliseconds: 100);
    _audioLevelTimer = Timer.periodic(interval, (_) => _pollAudioLevels());
  }

  void _stopAudioLevelPolling() {
    _audioLevelTimer?.cancel();
    _audioLevelTimer = null;
  }

  // -------------------------------------------------------------------------
  // RTC stats polling (bitrate + RTT for the dock tooltip — #937)
  // -------------------------------------------------------------------------

  void _startRtcStatsPolling(Room room) {
    _rtcStatsPoll?.dispose();
    final poll = RtcStatsPoll(
      room,
      onSample: (sample) {
        if (_disposed) return;
        state = state.copyWith(
          audioBitrateBps: sample.audioBitrateBps,
          rttMs: sample.rttMs,
        );
      },
    );
    _rtcStatsPoll = poll;
    poll.start();
  }

  void _stopRtcStatsPolling() {
    _rtcStatsPoll?.dispose();
    _rtcStatsPoll = null;
  }

  void _pollAudioLevels() {
    final room = _room;
    if (room == null || _disposed) return;

    final localLevel = room.localParticipant?.audioLevel ?? 0.0;

    // Keyed by identity (stable+unique) so the lounge UI can look peers up.
    final peerLevels = <String, double>{};
    for (final p in room.remoteParticipants.values) {
      final key = p.identity.isNotEmpty ? p.identity : p.sid.toString();
      peerLevels[key] = p.audioLevel;
    }

    // Dedup near-silence (epsilon 0.01) so CanvasKit doesn't repaint on noise.
    if (!_disposed && _audioLevelsChanged(localLevel, peerLevels)) {
      state = state.copyWith(
        localAudioLevel: localLevel,
        peerAudioLevels: peerLevels,
      );
    }
  }

  /// Returns true when the new audio-level snapshot is meaningfully
  /// different from the one currently published. Treats values below
  /// 0.01 as silence and ignores fluctuations between two silence
  /// readings so the participant grid doesn't rebuild ten times per
  /// second when nothing is happening.
  bool _audioLevelsChanged(double newLocal, Map<String, double> newPeers) {
    const epsilon = 0.01;
    final prev = state;
    bool changed(double a, double b) {
      final aQuiet = a < epsilon;
      final bQuiet = b < epsilon;
      if (aQuiet && bQuiet) return false;
      return (a - b).abs() >= epsilon;
    }

    if (changed(prev.localAudioLevel, newLocal)) return true;
    if (prev.peerAudioLevels.length != newPeers.length) return true;
    for (final entry in newPeers.entries) {
      final prevLevel = prev.peerAudioLevels[entry.key] ?? 0.0;
      if (changed(prevLevel, entry.value)) return true;
    }
    return false;
  }

  // -------------------------------------------------------------------------
  // Cleanup
  // -------------------------------------------------------------------------

  Future<void> _cleanupRoom() async {
    _stopAudioLevelPolling();
    _stopRtcStatsPolling();
    _pttListener?.stop();
    _pttListener = null;
    _roomListener?.dispose();
    _roomListener = null;

    final room = _room;
    _room = null;
    if (room != null) {
      // #927: restore per-track volumes to 1.0 BEFORE disconnect — Windows
      // WASAPI persists session volume across process lifetime, leaving the
      // system mixer pinned at the lowered level otherwise.
      try {
        await ParticipantVolumeController.instance.restoreAll(room);
      } catch (e) {
        DebugLogService.instance.log(
          LogLevel.warning,
          _kLogTag,
          'Volume restore failed during cleanup (ignored): $e',
        );
      }
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
    _stopRtcStatsPolling();
    _pttListener?.stop();
    _pttListener = null;
    _detachNotificationActionListener();
    unawaited(
      BackgroundService.instance.stopVoice().catchError((e, st) {
        debugPrint(
          '[livekit] stop background voice service on dispose failed: $e',
        );
      }),
    );
    unawaited(
      VoiceCallKitService.instance.endCall().catchError((e, st) {
        debugPrint('[livekit] end callkit call on dispose failed: $e');
      }),
    );

    // Null refs sync so in-flight callbacks hit null checks, not freed memory.
    final listener = _roomListener;
    final room = _room;
    _roomListener = null;
    _room = null;
    listener?.dispose();
    if (room != null) {
      // #927: restore volumes before disconnect (see _cleanupRoom for rationale).
      unawaited(
        ParticipantVolumeController.instance
            .restoreAll(room)
            .catchError((_) {})
            .then((_) => room.disconnect())
            .then((_) => room.dispose())
            .catchError((_) => false),
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
///
/// Regional Echo subdomains (`us-east.echo-messenger.us`, `eu.echo-messenger.us`, ...)
/// all share one LiveKit deployment at `livekit.echo-messenger.us`, so any
/// `*.echo-messenger.us` host normalizes to the apex. Self-hosted (non-Echo)
/// domains keep verbatim host prefixing — and preserve a non-standard port —
/// so unknown deployments still work.
///
/// Examples:
///   `https://echo-messenger.us`         → `wss://livekit.echo-messenger.us`
///   `https://us-east.echo-messenger.us` → `wss://livekit.echo-messenger.us`
///   `https://chat.example.com:8443`     → `wss://livekit.chat.example.com:8443`
@visibleForTesting
String deriveLiveKitUrl(String serverUrl) {
  final uri = Uri.parse(serverUrl);
  final scheme = uri.scheme == 'https' ? 'wss' : 'ws';
  final host = uri.host;
  const echoApex = 'echo-messenger.us';
  final isEchoHost = host == echoApex || host.endsWith('.$echoApex');
  if (isEchoHost) return '$scheme://livekit.$echoApex';
  final port = uri.hasPort ? ':${uri.port}' : '';
  return '$scheme://livekit.$host$port';
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
