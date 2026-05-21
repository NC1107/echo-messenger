import AVFoundation
import AVKit
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
    NSLog("[Echo] didFinishLaunching start")

    // Install a global handler so any Objective-C exception that
    // escapes Swift (e.g. unrecognized-selector crashes inside a
    // dispatched block, like the iOS 26 voice/video crash we saw on
    // TestFlight build 546) logs its selector, receiver class, and
    // symbolicated call stack to Console.app before the process
    // aborts. Stripped binary offsets in the .ips crash report aren't
    // actionable without the dSYM; the human-readable lines this
    // writes are.
    NSSetUncaughtExceptionHandler { exception in
      let name = exception.name.rawValue
      let reason = exception.reason ?? "(no reason)"
      NSLog("[Echo] UNCAUGHT EXCEPTION: %@ — %@", name, reason)
      let userInfo = exception.userInfo ?? [:]
      if !userInfo.isEmpty {
        NSLog("[Echo] EXCEPTION userInfo: %@", userInfo as NSDictionary)
      }
      for line in exception.callStackSymbols {
        NSLog("[Echo] EXCEPTION stack: %@", line)
      }
    }

    // Set up push notification delegate
    UNUserNotificationCenter.current().delegate = self

    // Register for remote notifications (APNs)
    application.registerForRemoteNotifications()

    // Configure the AVAudioSession category for VoIP-style audio so CallKit
    // and LiveKit's WebRTC engine share consistent options. Mode is .default
    // rather than .voiceChat: .voiceChat aggressively claims the audio route
    // and conflicts with the .voiceProcessingIO mode LiveKit sets internally
    // on the native WebRTC track.
    //
    // CRITICAL: do NOT call setActive(true) here. The previous version of
    // this code did so as a "pre-warm" — but on iOS 17+ with mic permission
    // in .notDetermined, setActive(true) on a .playAndRecord session blocks
    // the main thread waiting for a TCC mic-permission prompt that cannot
    // be presented yet (no UIScene up). The system watchdog then SIGKILLs
    // the app after 20-30s. Symptom: orange mic dot appears (input route
    // armed), no Dart breadcrumbs persist, no /api/voice/token request
    // reaches the server — exactly what the production crash report shows.
    //
    // LiveKit's LocalAudioTrack.create activates the session itself at the
    // right moment, AFTER a UI scene exists and after mic permission has
    // been explicitly requested via permission_handler in joinChannel.
    // Also dropped .mixWithOthers from the option set — it fights against
    // .voiceProcessingIO that LiveKit installs.
    do {
      let session = AVAudioSession.sharedInstance()
      try session.setCategory(
        .playAndRecord,
        mode: .default,
        options: [.allowBluetooth, .allowBluetoothA2DP, .defaultToSpeaker]
      )
      NSLog("[Echo] audio session category set")
    } catch {
      NSLog("[Echo] AVAudioSession setCategory failed: \(error.localizedDescription)")
    }

    let result = super.application(application, didFinishLaunchingWithOptions: launchOptions)
    NSLog("[Echo] didFinishLaunching done result=\(result)")
    return result
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

// MARK: - PiP bridge
//
// Bridges the Dart `us.echomessenger/pip` MethodChannel to the iOS
// Picture-in-Picture system APIs.  Wires up an
// AVPictureInPictureController so the system records the activity as
// PiP-eligible the moment a remote screen share is published.
//
// CURRENT STATE: scaffolding only.  Actual rendering of the LiveKit
// screen-share track inside the PiP layer requires a fork of the
// livekit_client iOS plugin so we can attach our own renderer to a
// LiveKit RemoteVideoTrack and forward its frames into an
// AVSampleBufferDisplayLayer — tracked as a follow-up.  Until then, PiP
// entry surfaces a system PiP window backed by a placeholder layer so
// iOS keeps the audio session alive (already covered by CallKit in
// Slice 2 anyway), but the user must return to the app to see the
// share.  Voice + the lounge UI stay running because of the foreground
// service / CallKit work in Slices 1 and 2; this bridge only governs
// the PiP-window rendering.
//
// Inlined into AppDelegate.swift on purpose — Flutter's iOS Runner
// project doesn't auto-discover loose .swift files in ios/Runner; they
// have to be added to project.pbxproj.  Keeping the class here avoids
// that step and matches the AppDelegate-extension pattern Flutter
// itself uses for plugin glue.

@available(iOS 15.0, *)
final class PipBridgePlugin: NSObject, AVPictureInPictureControllerDelegate {
  private static let channelName = "us.echomessenger/pip"

  private var channel: FlutterMethodChannel?
  private var pipController: AVPictureInPictureController?
  private var sampleBufferLayer: AVSampleBufferDisplayLayer?
  private var hostView: UIView?
  private var eligibleWidth: Int = 0
  private var eligibleHeight: Int = 0

  /// Whether a remote screen share is currently active.  PiP entry is a
  /// no-op when false even if `enterPip` is called.
  private var isEligible: Bool { eligibleWidth > 0 && eligibleHeight > 0 }

  func register(with messenger: FlutterBinaryMessenger, hostView: UIView) {
    self.hostView = hostView
    let channel = FlutterMethodChannel(name: PipBridgePlugin.channelName, binaryMessenger: messenger)
    channel.setMethodCallHandler { [weak self] call, result in
      self?.handle(call: call, result: result)
    }
    self.channel = channel
  }

  private func handle(call: FlutterMethodCall, result: @escaping FlutterResult) {
    switch call.method {
    case "setEligible":
      if let args = call.arguments as? [String: Any],
         let w = args["width"] as? Int,
         let h = args["height"] as? Int {
        eligibleWidth = w
        eligibleHeight = h
        if w > 0 && h > 0 {
          ensureControllerCreated()
        } else {
          tearDownController()
        }
      }
      result(nil)
    case "enterPip":
      result(startPipIfPossible())
    default:
      result(FlutterMethodNotImplemented)
    }
  }

  private func ensureControllerCreated() {
    guard pipController == nil else { return }
    guard AVPictureInPictureController.isPictureInPictureSupported() else {
      NSLog("[PipBridge] AVPictureInPictureController not supported on this device")
      return
    }
    guard let host = hostView else { return }

    let layer = AVSampleBufferDisplayLayer()
    layer.videoGravity = .resizeAspect
    layer.frame = host.bounds
    host.layer.addSublayer(layer)
    sampleBufferLayer = layer

    // ContentSource using the sample-buffer playback variant (iOS 15+).
    // Once the livekit_client renderer hook lands, the LiveKit track's
    // frames flow into this layer; for now it remains empty.
    let source = AVPictureInPictureController.ContentSource(
      sampleBufferDisplayLayer: layer,
      playbackDelegate: PipPlaybackDelegate.shared
    )
    let controller = AVPictureInPictureController(contentSource: source)
    controller.delegate = self
    controller.canStartPictureInPictureAutomaticallyFromInline = true
    pipController = controller
  }

  private func tearDownController() {
    pipController?.stopPictureInPicture()
    pipController = nil
    sampleBufferLayer?.removeFromSuperlayer()
    sampleBufferLayer = nil
  }

  private func startPipIfPossible() -> Bool {
    guard isEligible else { return false }
    guard let controller = pipController else { return false }
    if controller.isPictureInPicturePossible {
      controller.startPictureInPicture()
      return true
    }
    return false
  }

  // MARK: - AVPictureInPictureControllerDelegate

  func pictureInPictureControllerDidStartPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel?.invokeMethod("onPipChanged", arguments: ["inPip": true])
  }

  func pictureInPictureControllerDidStopPictureInPicture(
    _ pictureInPictureController: AVPictureInPictureController
  ) {
    channel?.invokeMethod("onPipChanged", arguments: ["inPip": false])
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    failedToStartPictureInPictureWithError error: Error
  ) {
    NSLog("[PipBridge] failedToStartPictureInPicture: \(error.localizedDescription)")
    channel?.invokeMethod("onPipChanged", arguments: ["inPip": false])
  }
}

@available(iOS 15.0, *)
private final class PipPlaybackDelegate: NSObject, AVPictureInPictureSampleBufferPlaybackDelegate {
  static let shared = PipPlaybackDelegate()

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    setPlaying playing: Bool
  ) {
    // Live screen share is always "playing"; the user can't pause a
    // co-broadcast.  No-op until we wire frame delivery.
  }

  func pictureInPictureControllerTimeRangeForPlayback(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> CMTimeRange {
    // Live source — report an unbounded range.
    return CMTimeRange(start: .negativeInfinity, end: .positiveInfinity)
  }

  func pictureInPictureControllerIsPlaybackPaused(
    _ pictureInPictureController: AVPictureInPictureController
  ) -> Bool {
    return false
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    didTransitionToRenderSize newRenderSize: CMVideoDimensions
  ) {
    // Aspect change — nothing to do until the LiveKit renderer hook
    // lands and starts pushing track-resolution updates.
  }

  func pictureInPictureController(
    _ pictureInPictureController: AVPictureInPictureController,
    skipByInterval skipInterval: CMTime,
    completion completionHandler: @escaping () -> Void
  ) {
    // Live source has no scrubbing.
    completionHandler()
  }
}
