import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Set up push notification delegate
    UNUserNotificationCenter.current().delegate = self

    // Register for remote notifications (APNs)
    application.registerForRemoteNotifications()

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Set up MethodChannel for push token exchange with Dart
    if let controller = engineBridge.pluginRegistry as? FlutterViewController {
      pushChannel = FlutterMethodChannel(
        name: "us.echomessenger/push",
        binaryMessenger: controller.binaryMessenger
      )
    } else if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EchoPush") {
      pushChannel = FlutterMethodChannel(
        name: "us.echomessenger/push",
        binaryMessenger: registrar.messenger()
      )
    }
  }

  // MARK: - APNs Token Registration

  override func application(
    _ application: UIApplication,
    didRegisterForRemoteNotificationsWithDeviceToken deviceToken: Data
  ) {
    // Convert token to hex string for server registration
    let token = deviceToken.map { String(format: "%02x", $0) }.joined()
    NSLog("[Echo] APNs device token: \(token.prefix(8))...")
    pushChannel?.invokeMethod("onToken", arguments: token)
  }

  override func application(
    _ application: UIApplication,
    didFailToRegisterForRemoteNotificationsWithError error: Error
  ) {
    NSLog("[Echo] APNs registration failed: \(error.localizedDescription)")
  }

  // MARK: - Silent Push Handling

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    // Silent push received — tell Flutter to reconnect WebSocket.
    // Delay the completion handler so iOS keeps the app alive while
    // Dart reconnects and fetches messages (~25s budget).
    NSLog("[Echo] Silent push received, waking Dart engine")
    pushChannel?.invokeMethod("onWake", arguments: nil) { _ in
      // Dart has acknowledged the wake — give it a few more seconds
      // to finish the WebSocket handshake before telling iOS we're done.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        completionHandler(.newData)
      }
    }

    // Safety net: if Dart doesn't respond within 25 seconds, complete anyway
    // to avoid iOS killing us for exceeding the 30-second background limit.
    DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) {
      completionHandler(.newData)
    }
  }
}
