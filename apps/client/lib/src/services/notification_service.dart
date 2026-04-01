import 'notification_service_stub.dart'
    if (dart.library.js_interop) 'notification_service_web.dart';

/// Platform-agnostic notification service.
///
/// On web, delegates to the browser Notifications API.
/// On desktop/mobile, this is currently a no-op (can be extended later
/// with flutter_local_notifications).
abstract class NotificationService {
  /// Factory that returns the platform-appropriate implementation.
  factory NotificationService() => createNotificationService();

  /// Request notification permission from the user.
  Future<void> requestPermission();

  /// Show a notification for an incoming message.
  /// On web, only shows when the document is not focused.
  void showMessageNotification({
    required String senderUsername,
    required String body,
  });
}
