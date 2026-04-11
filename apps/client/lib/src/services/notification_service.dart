import 'dart:async';

import 'notification_service_stub.dart'
    if (dart.library.js_interop) 'notification_service_web.dart';

/// Platform-agnostic notification service.
///
/// On web, delegates to the browser Notifications API.
/// On desktop/mobile, uses flutter_local_notifications with separate
/// channels for DMs and groups, conversation-based notification IDs,
/// and tap-to-open-conversation support.
abstract class NotificationService {
  /// Factory that returns the platform-appropriate implementation.
  factory NotificationService() => createNotificationService();

  /// Request notification permission from the user.
  Future<void> requestPermission();

  /// Show a notification for an incoming message.
  ///
  /// [conversationId] enables conversation-based grouping, tap-to-open
  /// routing, and notification replacement (new messages in the same
  /// conversation update the existing notification rather than stacking).
  ///
  /// [isGroup] selects the appropriate notification channel (DM vs group).
  ///
  /// Suppressed when the app is focused unless [forceShow] is true.
  void showMessageNotification({
    required String senderUsername,
    required String body,
    String? conversationId,
    String? conversationName,
    bool isGroup = false,
    bool forceShow = false,
  });

  /// Cancel notifications for a specific conversation (e.g. when opened).
  void cancelConversationNotifications(String conversationId);

  /// Cancel all notifications.
  void cancelAll();

  /// Update the browser tab title badge with total unread count.
  /// On web, sets document.title to "(N) Echo Messenger" or "Echo Messenger".
  /// No-op on non-web platforms.
  void updateTabBadge(int totalUnread);

  /// Tell the service whether the app is currently focused.
  ///
  /// On native platforms, notifications are suppressed while the app is in the
  /// foreground (matching the web behaviour which checks `document.hidden`).
  void setAppFocused(bool focused) {}

  /// Reload cached notification preferences from SharedPreferences.
  ///
  /// Call after the user changes notification settings so the service
  /// picks up the new values without restarting the app.
  void refreshPreferences() {}

  /// Stream of conversation IDs from tapped notifications.
  ///
  /// Subscribe to this in the router/home screen to navigate to the
  /// conversation when the user taps a notification.
  Stream<String> get onNotificationTap;
}
