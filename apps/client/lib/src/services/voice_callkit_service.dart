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
    if (!_isIos) return;
    // Subscribe defensively — on a fresh install the plugin may not be
    // fully registered yet and getting `onEvent` can throw on some iOS
    // versions.  A failure here must NOT crash the app; CallKit
    // integration just becomes a no-op.
    try {
      _eventSub = FlutterCallkitIncoming.onEvent.listen(
        _handleEvent,
        onError: (Object e) {
          _log('CallKit event-stream error (ignored): $e', error: true);
        },
      );
    } catch (e, stack) {
      _log(
        'Failed to subscribe to CallKit event stream — service will run in no-op mode: $e',
        error: true,
      );
      _log('Stack: $stack', error: true);
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

    // Bare-minimum IOSParams — every optional field we set in v0.0.299 has
    // been a candidate for the on-tap crash, so we drop everything that
    // isn't strictly required to start an outgoing call.  Notably
    // `iconName` is gone (it referenced a CallKitLogo.png we don't bundle,
    // a hard-crash trigger when CallKit tries to resolve the asset) and
    // audioSessionMode is reset to 'default' to match the upstream
    // example.
    final params = CallKitParams(
      id: callId,
      nameCaller: channelName,
      handle: 'Echo Messenger',
      type: 0,
      ios: const IOSParams(
        handleType: 'generic',
        supportsVideo: false,
        maximumCallGroups: 1,
        maximumCallsPerCallGroup: 1,
        audioSessionMode: 'default',
        audioSessionActive: true,
        supportsDTMF: false,
        supportsHolding: false,
        supportsGrouping: false,
        supportsUngrouping: false,
      ),
    );

    // CallKit failure must NOT take down the voice join — LiveKit is
    // already connected by the time we get here, and the user's
    // experience of "voice works but iOS may suspend faster" is far
    // better than "tap channel, app crashes."  Catch everything,
    // including platform exceptions, asset-resolution errors, and
    // permission failures.
    try {
      await FlutterCallkitIncoming.startCall(params);
      if (isMuted) {
        try {
          await FlutterCallkitIncoming.muteCall(callId, isMuted: true);
        } catch (e) {
          _log('CallKit muteCall failed (non-fatal): $e', error: true);
        }
      }
      _activeCallId = callId;
      _log('Started CallKit call: $callId ($channelName)');
    } catch (e, stack) {
      _log(
        'CallKit startCall threw — voice will run without it: $e',
        error: true,
      );
      _log('Stack: $stack', error: true);
      // Leave _activeCallId null so endCall is also a no-op; the
      // foreground-service / notification stays in charge.
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
