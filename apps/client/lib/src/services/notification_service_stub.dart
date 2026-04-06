import 'notification_service.dart';

/// Stub (non-web) implementation -- notifications are a no-op.
NotificationService createNotificationService() => _StubNotificationService();

class _StubNotificationService implements NotificationService {
  @override
  Future<void> requestPermission() async {}

  @override
  void showMessageNotification({
    required String senderUsername,
    required String body,
  }) {
    // TODO: Implement desktop/mobile visual notifications with
    // flutter_local_notifications. Requires native setup:
    // - Android: AndroidManifest permissions, notification channel
    // - Linux: libnotify-dev in CMakeLists.txt
    // - Windows: no extra setup but needs testing
    // The sound service already handles audio -- this just needs the popup.
  }

  @override
  void updateTabBadge(int totalUnread) {
    // No-op on non-web platforms.
    // TODO: Implement desktop notifications with flutter_local_notifications
    // once native platform setup (AndroidManifest, Linux libnotify) is done.
  }
}
