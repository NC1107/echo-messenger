import AVFoundation
import Flutter
import UIKit
import UserNotifications

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  private var pushChannel: FlutterMethodChannel?
  private var pipBridge: Any?  // PipBridgePlugin, type-erased so iOS < 15 builds compile.

  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    // Set up push notification delegate
    UNUserNotificationCenter.current().delegate = self

    // Register for remote notifications (APNs)
    application.registerForRemoteNotifications()

    // Configure the AVAudioSession for VoIP-style playback so CallKit and
    // LiveKit's WebRTC engine share consistent options.  We don't activate
    // it here — CallKit owns activation when an outgoing call starts and
    // releases it on end.  Setting category up front avoids first-frame
    // audio drops when LiveKit grabs the session ahead of CallKit on a
    // cold-start join.
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .voiceChat,
        options: [.allowBluetooth, .allowBluetoothA2DP, .mixWithOthers, .defaultToSpeaker]
      )
    } catch {
      NSLog("[Echo] AVAudioSession setCategory failed: \(error.localizedDescription)")
    }

    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)

    // Set up MethodChannel for push token exchange with Dart.
    // Use the engine's binary messenger directly — casting pluginRegistry
    // to FlutterViewController fails because they are different types.
    let messenger: FlutterBinaryMessenger
    if let engine = engineBridge.pluginRegistry as? FlutterEngine {
      messenger = engine.binaryMessenger
    } else if let registrar = engineBridge.pluginRegistry.registrar(forPlugin: "EchoPush") {
      messenger = registrar.messenger()
    } else {
      NSLog("[Echo] WARNING: Could not obtain binary messenger for push channel")
      return
    }
    pushChannel = FlutterMethodChannel(
      name: "us.echomessenger/push",
      binaryMessenger: messenger
    )

    // Register the PiP method-channel handler.  Hosted on the root
    // window's view so the AVSampleBufferDisplayLayer we add for PiP
    // gets a valid superlayer; Flutter's content view itself isn't a
    // suitable host because Flutter manages its own layer hierarchy.
    if #available(iOS 15.0, *) {
      let host = window?.rootViewController?.view ?? UIView()
      let bridge = PipBridgePlugin()
      bridge.register(with: messenger, hostView: host)
      pipBridge = bridge
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

  // MARK: - Foreground Notification Display

  /// Show push notifications even when the app is in the foreground.
  /// Without this, iOS suppresses the visible banner for foreground apps.
  override func userNotificationCenter(
    _ center: UNUserNotificationCenter,
    willPresent notification: UNNotification,
    withCompletionHandler completionHandler: @escaping (UNNotificationPresentationOptions) -> Void
  ) {
    completionHandler([.banner, .sound, .badge])
  }

  // MARK: - Silent Push Handling

  override func application(
    _ application: UIApplication,
    didReceiveRemoteNotification userInfo: [AnyHashable: Any],
    fetchCompletionHandler completionHandler: @escaping (UIBackgroundFetchResult) -> Void
  ) {
    NSLog("[Echo] Silent push received, waking Dart engine")

    // Guard against double-calling completionHandler (iOS kills the app
    // if it's invoked more than once).
    var completed = false
    let finish: (UIBackgroundFetchResult) -> Void = { result in
      guard !completed else { return }
      completed = true
      completionHandler(result)
    }

    // Tell Dart to reconnect the WebSocket.
    pushChannel?.invokeMethod("onWake", arguments: nil) { _ in
      // Dart acknowledged — give a few more seconds for WS handshake.
      DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) {
        finish(.newData)
      }
    }

    // Safety net: complete before iOS's 30-second background limit.
    DispatchQueue.main.asyncAfter(deadline: .now() + 25.0) {
      finish(.newData)
    }
  }
}
