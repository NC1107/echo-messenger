import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'notification_service.dart';

/// Web implementation using the browser Notifications API.
///
/// Uses a singleton so that permission state is retained across calls.
/// Previous code created a new instance each time via the factory constructor,
/// losing the `_permissionGranted` flag set by `requestPermission()`.
NotificationService createNotificationService() =>
    _WebNotificationService._instance;

class _WebNotificationService implements NotificationService {
  static final _WebNotificationService _instance = _WebNotificationService._();
  _WebNotificationService._();

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
    bool forceShow = false,
  }) {
    if (!_permissionGranted) return;
    try {
      // Show when the document is not visible (user tabbed away),
      // or when forceShow is true (e.g. test notification button).
      if (web.document.hidden || forceShow) {
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

  @override
  void setAppFocused(bool focused) {
    // On web, `document.hidden` is checked directly in showMessageNotification,
    // so there's nothing to track here.
  }
}
