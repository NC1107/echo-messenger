import 'dart:convert';
import 'dart:io' show Platform;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import 'debug_log_service.dart';

/// Registers the iOS APNs device token with the Echo server so offline
/// users receive silent push notifications that wake the app.
///
/// Android uses a foreground service instead of push. Desktop/web maintain
/// persistent WebSocket connections. This service is iOS-only.
class PushTokenService {
  PushTokenService._();
  static final PushTokenService instance = PushTokenService._();

  static const _channel = MethodChannel('us.echomessenger/push');
  String? _currentToken;
  String _serverUrl = '';
  String _authToken = '';

  /// Initialize the service and listen for device token from iOS native.
  ///
  /// Call once after login. On iOS, the native AppDelegate sends the APNs
  /// device token via MethodChannel; this service registers it with the
  /// Echo server. On other platforms this is a no-op.
  void init({
    required String serverUrl,
    required String authToken,
    required VoidCallback onWake,
  }) {
    if (kIsWeb || !Platform.isIOS) return;

    _serverUrl = serverUrl;
    _authToken = authToken;

    _channel.setMethodCallHandler((call) async {
      switch (call.method) {
        case 'onToken':
          final token = call.arguments as String?;
          if (token != null && token.isNotEmpty) {
            _currentToken = token;
            await _registerToken(token);
          }
        case 'onWake':
          // Silent push received — reconnect WebSocket
          DebugLogService.instance.log(
            LogLevel.info,
            'Push',
            'Silent push received, triggering reconnect',
          );
          onWake();
      }
    });
  }

  /// Update the auth token (e.g. after token refresh).
  void setAuthToken(String token) {
    _authToken = token;
  }

  /// Detach this client from ALL push tokens registered against the current
  /// server. Used by the server-switch flow before flipping
  /// [serverUrlProvider]: hits the new bulk-delete endpoint regardless of
  /// platform so non-iOS clients can call it unconditionally.
  ///
  /// Best-effort: network errors are swallowed so a switch-on-flaky-network
  /// is never blocked by push cleanup.
  Future<void> deregister({String? serverUrl, String? authToken}) async {
    final origin = serverUrl ?? _serverUrl;
    final token = authToken ?? _authToken;
    if (origin.isEmpty) return;
    try {
      await http
          .delete(
            Uri.parse('$origin/api/push/token'),
            headers: {
              'Content-Type': 'application/json',
              if (token.isNotEmpty) 'Authorization': 'Bearer $token',
            },
          )
          .timeout(const Duration(seconds: 5));
      DebugLogService.instance.log(
        LogLevel.info,
        'Push',
        'Push tokens cleared via DELETE /api/push/token',
      );
    } catch (e) {
      debugPrint('[Push] deregister failed: $e');
    }
    _currentToken = null;
  }

  /// Unregister the push token on logout.
  Future<void> unregister() async {
    final token = _currentToken;
    if (token == null || _serverUrl.isEmpty) return;

    try {
      await http.post(
        Uri.parse('$_serverUrl/api/push/unregister'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_authToken',
        },
        body: jsonEncode({'token': token}),
      );
      DebugLogService.instance.log(
        LogLevel.info,
        'Push',
        'Push token unregistered',
      );
    } catch (e) {
      debugPrint('[Push] Unregister failed: $e');
    }
    _currentToken = null;
  }

  Future<void> _registerToken(String token) async {
    if (_serverUrl.isEmpty || _authToken.isEmpty) return;

    try {
      final response = await http.post(
        Uri.parse('$_serverUrl/api/push/register'),
        headers: {
          'Content-Type': 'application/json',
          'Authorization': 'Bearer $_authToken',
        },
        body: jsonEncode({'token': token, 'platform': 'apns'}),
      );
      if (response.statusCode == 200) {
        DebugLogService.instance.log(
          LogLevel.info,
          'Push',
          'APNs token registered with server',
        );
      } else {
        debugPrint('[Push] Registration failed: ${response.statusCode}');
      }
    } catch (e) {
      debugPrint('[Push] Registration failed: $e');
    }
  }
}
