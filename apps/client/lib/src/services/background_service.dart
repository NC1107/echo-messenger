import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debug_log_service.dart';

/// Action emitted by the voice notification's Mute / Leave buttons.
sealed class VoiceNotificationAction {
  const VoiceNotificationAction();
}

class VoiceMuteAction extends VoiceNotificationAction {
  final bool muted;
  const VoiceMuteAction({required this.muted});
}

class VoiceLeaveAction extends VoiceNotificationAction {
  const VoiceLeaveAction();
}

/// Manages background execution for mobile platforms.
///
/// **Android**: Starts a foreground service.  Two modes:
///
///   - keep-alive (default): generic notification, type DATA_SYNC, used so
///     the WebSocket stays connected for incoming messages.
///   - voice: notification shows the channel name + Mute / Leave actions,
///     type MICROPHONE | MEDIA_PLAYBACK so Android 14+ does not revoke
///     RECORD_AUDIO when the app is backgrounded.  See
///     [LiveKitVoiceNotifier.joinChannel] / [leaveChannel].
///
/// **iOS**: Background voice survival is handled by AVAudioSession + CallKit
/// (see [VoiceCallKitService]).  Silent APNs pushes wake the app for chat.
///
/// **Desktop**: No-op.
class BackgroundService {
  BackgroundService._() {
    try {
      _channel.setMethodCallHandler(_handleMethodCall);
    } catch (_) {
      // No binary messenger yet (unit tests without WidgetsFlutterBinding).
      // Notification actions are an Android runtime concern; tests that
      // exercise them should call ensureInitialized() before importing
      // anything that touches LiveKitVoiceNotifier.
    }
  }
  static final BackgroundService instance = BackgroundService._();

  static const _channel = MethodChannel('us.echomessenger/foreground_service');

  final _actionController =
      StreamController<VoiceNotificationAction>.broadcast();

  /// Stream of Mute / Leave taps from the voice notification (Android only).
  Stream<VoiceNotificationAction> get notificationActions =>
      _actionController.stream;

  bool _keepaliveRunning = false;
  bool _voiceRunning = false;

  static bool get _isAndroid {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  /// Start the keep-alive foreground service (Android only).  Idempotent.
  Future<void> start() async {
    if (!_isAndroid || _keepaliveRunning || _voiceRunning) return;
    try {
      await _channel.invokeMethod('start');
      _keepaliveRunning = true;
      _log('Keep-alive service started');
    } catch (e) {
      _log('Failed to start keep-alive service: $e', error: true);
    }
  }

  /// Stop the keep-alive foreground service.  No-op if voice mode is active
  /// (caller should use [stopVoice] instead).
  Future<void> stop() async {
    if (!_isAndroid || (!_keepaliveRunning && !_voiceRunning)) return;
    try {
      await _channel.invokeMethod('stop');
      _keepaliveRunning = false;
      _voiceRunning = false;
      _log('Foreground service stopped');
    } catch (e) {
      _log('Failed to stop foreground service: $e', error: true);
    }
  }

  /// Promote the foreground service to voice mode.  Safe to call whether
  /// the keep-alive service is running or not — the service will reconfigure
  /// itself with the MICROPHONE | MEDIA_PLAYBACK type.
  Future<void> startVoice({
    required String channelName,
    required bool isMuted,
    required int participantCount,
  }) async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('startVoice', {
        'channelName': channelName,
        'isMuted': isMuted,
        'participantCount': participantCount,
      });
      _voiceRunning = true;
      // Voice mode subsumes keep-alive on the same service instance.
      _keepaliveRunning = false;
      _log(
        'Voice service started: $channelName (muted=$isMuted, n=$participantCount)',
      );
    } catch (e) {
      _log('Failed to start voice service: $e', error: true);
    }
  }

  /// Update the live voice notification with new state.  Safe to call from
  /// any frequency; the underlying notification just gets re-issued.
  Future<void> updateVoice({
    String? channelName,
    bool? isMuted,
    int? participantCount,
  }) async {
    if (!_isAndroid || !_voiceRunning) return;
    try {
      await _channel.invokeMethod('updateVoice', {
        'channelName': ?channelName,
        'isMuted': ?isMuted,
        'participantCount': ?participantCount,
      });
    } catch (e) {
      _log('Failed to update voice notification: $e', error: true);
    }
  }

  /// Stop the voice-mode foreground service (called on leaveChannel).
  Future<void> stopVoice() async {
    if (!_isAndroid) return;
    try {
      await _channel.invokeMethod('stopVoice');
      _voiceRunning = false;
      _log('Voice service stopped');
    } catch (e) {
      _log('Failed to stop voice service: $e', error: true);
    }
  }

  Future<dynamic> _handleMethodCall(MethodCall call) async {
    if (call.method != 'onNotificationAction') return null;
    final args = (call.arguments as Map?) ?? const {};
    final action = args['action'] as String?;
    switch (action) {
      case 'mute':
        final muted = (args['muted'] as bool?) ?? false;
        _actionController.add(VoiceMuteAction(muted: muted));
      case 'leave':
        _actionController.add(const VoiceLeaveAction());
    }
    return null;
  }

  bool get isRunning => _keepaliveRunning || _voiceRunning;
  bool get isVoiceRunning => _voiceRunning;

  void _log(String message, {bool error = false}) {
    debugPrint('[BackgroundService] $message');
    DebugLogService.instance.log(
      error ? LogLevel.error : LogLevel.info,
      'BackgroundService',
      message,
    );
  }

  /// Test-only: reset internal flags so `setUp(() => ...)` can run with a
  /// fresh state.  Does NOT touch the platform side.
  @visibleForTesting
  void resetForTesting() {
    _keepaliveRunning = false;
    _voiceRunning = false;
  }
}
