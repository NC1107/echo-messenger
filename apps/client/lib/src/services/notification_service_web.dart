import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'notification_service.dart';

/// Web implementation using the browser Notifications API.
NotificationService createNotificationService() => _WebNotificationService();

class _WebNotificationService implements NotificationService {
  bool _permissionGranted = false;

  @override
  Future<void> requestPermission() async {
    try {
      final permission = web.Notification.permission;
      if (permission == 'granted') {
        _permissionGranted = true;
        return;
      }
      if (permission == 'denied') {
        _permissionGranted = false;
        return;
      }
      // Ask the user
      final result = await web.Notification.requestPermission().toDart;
      _permissionGranted = result.toDart == 'granted';
    } catch (_) {
      _permissionGranted = false;
    }
  }

  @override
  void showMessageNotification({
    required String senderUsername,
    required String body,
  }) {
    if (!_permissionGranted) return;
    try {
      // Only show when the document is not visible (user tabbed away)
      if (web.document.hidden) {
        web.Notification(senderUsername, web.NotificationOptions(body: body));
      }
    } catch (_) {
      // Best-effort -- silently ignore errors
    }
  }

  @override
  void updateTabBadge(int totalUnread) {
    try {
      if (totalUnread > 0) {
        web.document.title = '($totalUnread) Echo Messenger';
      } else {
        web.document.title = 'Echo Messenger';
      }
    } catch (_) {
      // Best-effort -- silently ignore errors
    }
  }
}
