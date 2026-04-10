import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'debug_log_service.dart';

/// Manages background execution for mobile platforms.
///
/// **Android**: Starts a foreground service with a persistent notification
/// ("Echo Messenger is running") so the OS keeps the WebSocket alive when the
/// app is backgrounded. No Google/Firebase dependency -- the WebSocket IS the
/// push mechanism.
///
/// **iOS**: Will use APNs silent pushes in the future (Apple requirement, not
/// Google). For now, the WebSocket reconnects when the app returns to
/// foreground.
///
/// **Desktop**: No-op. Desktop apps aren't restricted by OS backgrounding.
class BackgroundService {
  BackgroundService._();
  static final BackgroundService instance = BackgroundService._();

  static const _channel = MethodChannel('us.echomessenger/foreground_service');
  bool _running = false;

  /// Whether this platform needs a foreground service to stay connected.
  static bool get _needsForegroundService {
    if (kIsWeb) return false;
    return Platform.isAndroid;
  }

  /// Start the foreground service (Android only).
  ///
  /// Call after login when the WebSocket is established. The service shows a
  /// persistent notification and prevents the OS from killing the app's
  /// network connections.
  Future<void> start() async {
    if (!_needsForegroundService || _running) return;

    try {
      await _channel.invokeMethod('start');
      _running = true;
      debugPrint('[BackgroundService] Foreground service started');
      DebugLogService.instance.log(
        LogLevel.info,
        'BackgroundService',
        'Foreground service started',
      );
    } catch (e) {
      debugPrint('[BackgroundService] Failed to start: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'BackgroundService',
        'Failed to start foreground service: $e',
      );
    }
  }

  /// Stop the foreground service (call on logout).
  Future<void> stop() async {
    if (!_running) return;

    try {
      await _channel.invokeMethod('stop');
      _running = false;
      debugPrint('[BackgroundService] Foreground service stopped');
      DebugLogService.instance.log(
        LogLevel.info,
        'BackgroundService',
        'Foreground service stopped',
      );
    } catch (e) {
      debugPrint('[BackgroundService] Failed to stop: $e');
    }
  }

  bool get isRunning => _running;
}
