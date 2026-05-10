import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter_callkit_incoming/entities/entities.dart';
import 'package:flutter_callkit_incoming/flutter_callkit_incoming.dart';

import 'debug_log_service.dart';

/// Action emitted by the iOS CallKit lock-screen entry.
sealed class CallKitAction {
  const CallKitAction();
}

class CallKitMuteAction extends CallKitAction {
  final bool muted;
  const CallKitMuteAction({required this.muted});
}

class CallKitEndAction extends CallKitAction {
  const CallKitEndAction();
}

/// iOS-only wrapper around `flutter_callkit_incoming`.
///
/// When LiveKit voice joins, we report an outgoing CXStartCallAction so the
/// system shows a call entry in the lock-screen call UI and (more
/// importantly) holds the AVAudioSession active even if the app suspends.
/// Without an active CallKit call, modern iOS suspends `voip`-mode apps
/// within ~30s of backgrounding and tears down the WebRTC audio session.
///
/// On Android / desktop this is a no-op — Android uses the foreground
/// service in [BackgroundService], desktop apps aren't restricted.
class VoiceCallKitService {
  VoiceCallKitService._() {
    if (_isIos) {
      _eventSub = FlutterCallkitIncoming.onEvent.listen(_handleEvent);
    }
  }
  static final VoiceCallKitService instance = VoiceCallKitService._();

  static bool get _isIos {
    if (kIsWeb) return false;
    return Platform.isIOS;
  }

  final _actionController = StreamController<CallKitAction>.broadcast();
  StreamSubscription<CallEvent?>? _eventSub;
  String? _activeCallId;

  /// Stream of Mute / End taps from the CallKit UI.  iOS only.
  Stream<CallKitAction> get actions => _actionController.stream;

  /// Whether a CallKit call is currently active.
  bool get hasActiveCall => _activeCallId != null;

  /// Report an outgoing call to CallKit so iOS keeps the audio session
  /// alive when the app is backgrounded.  No-op outside iOS.
  ///
  /// [callId] should be a UUID-shaped string unique to the room.  Re-using
  /// the same id while a call is active is a no-op.
  Future<void> startCall({
    required String callId,
    required String channelName,
    required bool isMuted,
  }) async {
    if (!_isIos) return;
    if (_activeCallId == callId) return;
    if (_activeCallId != null) {
      // Stale call from a previous join — flush before starting the new one.
      await endCall();
    }

    final params = CallKitParams(
      id: callId,
      nameCaller: channelName,
      handle: 'Echo Messenger',
      type: 0,
      // CallKit's UI mute state must agree with our LiveKit mic state on
      // join; the handler below keeps it in sync after that.
      ios: const IOSParams(
        iconName: 'CallKitLogo',
        handleType: 'generic',
        supportsVideo: false,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'voiceChat',
        audioSessionActive: true,
        audioSessionPreferredSampleRate: 44100.0,
        audioSessionPreferredIOBufferDuration: 0.005,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
        ringtonePath: 'system_ringtone_default',
      ),
    );

    try {
      await FlutterCallkitIncoming.startCall(params);
      // Reflect the initial mute state into the CallKit UI so the user
      // doesn't see Unmuted while LiveKit started muted.
      if (isMuted) {
        await FlutterCallkitIncoming.muteCall(callId, isMuted: true);
      }
      _activeCallId = callId;
      _log('Started CallKit call: $callId ($channelName)');
    } catch (e) {
      _log('Failed to start CallKit call: $e', error: true);
    }
  }

  /// Tell CallKit the user just toggled mute from inside the app so the
  /// lock-screen mute pill stays in sync.
  Future<void> setMuted(bool muted) async {
    if (!_isIos || _activeCallId == null) return;
    try {
      await FlutterCallkitIncoming.muteCall(_activeCallId!, isMuted: muted);
    } catch (e) {
      _log('Failed to update CallKit mute state: $e', error: true);
    }
  }

  /// End the CallKit call and release the system audio session.
  Future<void> endCall() async {
    if (!_isIos || _activeCallId == null) return;
    final id = _activeCallId!;
    _activeCallId = null;
    try {
      await FlutterCallkitIncoming.endCall(id);
      _log('Ended CallKit call: $id');
    } catch (e) {
      _log('Failed to end CallKit call: $e', error: true);
    }
  }

  void _handleEvent(CallEvent? event) {
    if (event == null) return;
    final id = event.body['id'] as String?;
    if (id == null || id != _activeCallId) return;

    switch (event.event) {
      case Event.actionCallEnded:
      case Event.actionCallDecline:
      case Event.actionCallTimeout:
        _activeCallId = null;
        _actionController.add(const CallKitEndAction());
      case Event.actionCallToggleMute:
        final muted = (event.body['isMuted'] as bool?) ?? false;
        _actionController.add(CallKitMuteAction(muted: muted));
      // Other events (incoming/start/accept/hold/group) aren't relevant to
      // outgoing-only voice lounges.
      // ignore: no_default_cases
      default:
        break;
    }
  }

  void _log(String message, {bool error = false}) {
    debugPrint('[VoiceCallKit] $message');
    DebugLogService.instance.log(
      error ? LogLevel.error : LogLevel.info,
      'VoiceCallKit',
      message,
    );
  }

  /// Test-only: reset internal state.
  @visibleForTesting
  void resetForTesting() {
    _activeCallId = null;
  }

  /// Test-only: dispose the event subscription so test runners exit cleanly.
  @visibleForTesting
  Future<void> disposeForTesting() async {
    await _eventSub?.cancel();
    _eventSub = null;
    await _actionController.close();
  }
}
