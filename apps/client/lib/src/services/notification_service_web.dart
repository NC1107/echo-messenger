import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'notification_service.dart';

/// Web implementation using the browser Notifications API.
///
/// Uses a singleton so that permission state is retained across calls.
NotificationService createNotificationService() =>
    _WebNotificationService._instance;

class _WebNotificationService implements NotificationService {
  static final _WebNotificationService _instance = _WebNotificationService._();
  _WebNotificationService._();

  bool _permissionGranted = false;

  /// Stream controller for notification tap events (conversation IDs).
  final _tapController = StreamController<String>.broadcast();

  @override
  Stream<String> get onNotificationTap => _tapController.stream;

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
    String? conversationId,
    bool isGroup = false,
    bool forceShow = false,
  }) {
    if (!_permissionGranted) return;
    try {
      // Show when the document is not visible (user tabbed away),
      // or when forceShow is true (e.g. test notification button).
      if (web.document.hidden || forceShow) {
        final notification = web.Notification(
          senderUsername,
          web.NotificationOptions(body: body),
        );
        // Navigate to the conversation when the user clicks the notification.
        if (conversationId != null && conversationId.isNotEmpty) {
          notification.onclick = (web.Event e) {
            web.window.focus();
            _tapController.add(conversationId);
          }.toJS;
        }
      }
    } catch (_) {
      // Best-effort -- silently ignore errors
    }
  }

  @override
  void cancelConversationNotifications(String conversationId) {
    // Browser Notifications API does not support cancelling by ID.
    // We could track Notification objects in a map, but the value is low
    // on web since notifications auto-dismiss.
  }

  @override
  void cancelAll() {
    // Not supported by browser Notifications API.
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
  void refreshPreferences() {
    // Web notifications don't cache SharedPreferences -- no-op.
  }

  @override
  void setAppFocused(bool focused) {
    // On web, `document.hidden` is checked directly in showMessageNotification,
    // so there's nothing to track here.
  }
}
