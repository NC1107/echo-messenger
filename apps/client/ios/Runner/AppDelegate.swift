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
    // Silent push received — tell Flutter to reconnect WebSocket
    NSLog("[Echo] Silent push received")
    pushChannel?.invokeMethod("onWake", arguments: nil)
    completionHandler(.newData)
  }
}
