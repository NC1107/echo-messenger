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
  }) {}
}
