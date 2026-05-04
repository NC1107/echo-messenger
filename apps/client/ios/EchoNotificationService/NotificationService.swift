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

    // Show sender name as the notification title for encrypted messages.
    // The server redacts the title to "New message" so lock-screen glances
    // don't leak sender identity via APNs, but the sender_username field in
    // the custom payload lets us restore it here before display.
    // Future: full E2E decryption via shared Keychain session keys.
    if let sender = request.content.userInfo["sender_username"] as? String,
       !sender.isEmpty {
      content.title = sender
    }

    contentHandler(content)
  }

  override func serviceExtensionTimeWillExpire() {
    // Deliver whatever we have before iOS kills the extension.
    if let contentHandler, let content = bestAttemptContent {
      contentHandler(content)
    }
  }
}
