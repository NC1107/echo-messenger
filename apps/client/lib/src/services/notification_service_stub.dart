import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'debug_log_service.dart';
import 'notification_service.dart';

/// Native (non-web) implementation using flutter_local_notifications.
///
/// Uses a singleton so that the [_appFocused] flag and init state are shared
/// across all callers (mirrors the web implementation pattern).
NotificationService createNotificationService() =>
    _NativeNotificationService._instance;

class _NativeNotificationService implements NotificationService {
  static final _NativeNotificationService _instance =
      _NativeNotificationService._();
  _NativeNotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static int _notificationId = 0;
  static bool _appFocused = true;

  static const _channel = AndroidNotificationDetails(
    'echo_messages',
    'Messages',
    channelDescription: 'Incoming message notifications',
    importance: Importance.high,
    priority: Priority.high,
  );

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const linux = LinuxInitializationSettings(defaultActionName: 'Open');
      const initSettings = InitializationSettings(
        android: android,
        linux: linux,
      );
      await _plugin.initialize(initSettings);
      _initialized = true;
    } catch (e) {
      debugPrint('[Notifications] init failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Notifications',
        'Init failed (notifications will not be shown). '
            'On Linux, ensure a D-Bus notification daemon is running: $e',
      );
    }
  }

  @override
  Future<void> requestPermission() async {
    if (kIsWeb) return;
    await _ensureInitialized();
    // Android 13+ runtime permission
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Not on Android or permission denied -- non-fatal.
    }
  }

  @override
  void showMessageNotification({
    required String senderUsername,
    required String body,
    bool forceShow = false,
  }) {
    // Suppress when the app is focused (matches web behaviour).
    if (_appFocused && !forceShow) return;

    _ensureInitialized().then((_) {
      if (!_initialized) return;
      _plugin.show(
        _notificationId++,
        senderUsername,
        body,
        const NotificationDetails(
          android: _channel,
          linux: LinuxNotificationDetails(),
        ),
      );
    });
  }

  @override
  void updateTabBadge(int totalUnread) {
    // No-op on native platforms (tab badge is a web concept).
  }

  @override
  void setAppFocused(bool focused) {
    _appFocused = focused;
  }
}
