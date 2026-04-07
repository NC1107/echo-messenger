import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';

import 'notification_service.dart';

/// Native (non-web) implementation using flutter_local_notifications.
NotificationService createNotificationService() => _NativeNotificationService();

class _NativeNotificationService implements NotificationService {
  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static int _notificationId = 0;

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
}
