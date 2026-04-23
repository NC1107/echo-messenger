import UserNotifications

/// Notification Service Extension that processes push notifications before
/// display.  Runs in its own process -- works even when the main app is killed.
///
/// Currently passes the notification through unchanged.  Future: decrypt
/// E2E message content via shared Keychain keys.
class NotificationService: UNNotificationServiceExtension {
  private var contentHandler: ((UNNotificationContent) -> Void)?
  private var bestAttemptContent: UNMutableNotificationContent?

  override func didReceive(
    _ request: UNNotificationRequest,
    withContentHandler contentHandler: @escaping (UNNotificationContent) -> Void
  ) {
    self.contentHandler = contentHandler
    bestAttemptContent = request.content.mutableCopy() as? UNMutableNotificationContent

    guard let content = bestAttemptContent else {
      contentHandler(request.content)
      return
    }

    // Future: decrypt content here using shared Keychain group keys.
    // For now, pass through the server-provided alert as-is.

    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    // Deliver whatever we have before iOS kills the extension.
    if let contentHandler, let content = bestAttemptContent {
      contentHandler(content)
    }
  }
}
