import 'dart:async';
import 'dart:js_interop';

import 'package:web/web.dart' as web;

import 'notification_service.dart';
import '../screens/settings/notification_section.dart'
    show shouldSuppressNotification;

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
      // The browser requires that Notification.requestPermission() is called
      // from inside a short-running user-gesture handler (click/tap). On
      // startup there is no gesture context, so we only sync the current
      // state here. The actual prompt is deferred to [promptPermission],
      // which should be called from a user-initiated action (e.g. a button).
      _permissionGranted = false;
    } catch (_) {
      _permissionGranted = false;
    }
  }

  /// Prompt the user for notification permission.
  ///
  /// Must be called from a user-gesture context (e.g. a button tap).
  /// Returns true if permission was granted.
  @override
  Future<bool> promptPermission() async {
    try {
      final result = await web.Notification.requestPermission().toDart;
      _permissionGranted = result.toDart == 'granted';
      return _permissionGranted;
    } catch (_) {
      _permissionGranted = false;
      return false;
    }
  }

  @override
  void showMessageNotification({
    required String senderUsername,
    required String body,
    String? conversationId,
    String? conversationName,
    bool isGroup = false,
    bool forceShow = false,
  }) {
    if (!_permissionGranted) return;

    // Check Do Not Disturb and Quiet Hours (async, suppress if active).
    if (!forceShow) {
      shouldSuppressNotification().then((suppress) {
        if (!suppress) _showWebNotification(senderUsername, body, conversationId);
      });
      return;
    }

    _showWebNotification(senderUsername, body, conversationId, force: true);
  }

  void _showWebNotification(
    String senderUsername,
    String body,
    String? conversationId, {
    bool force = false,
  }) {
    try {
      // Show when the document is not visible (user tabbed away),
      // or when forced (e.g. test notification button).
      if (web.document.hidden || force) {
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
