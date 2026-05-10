// PipBridgePlugin
// ----------------
// Bridges the Dart `us.echomessenger/pip` MethodChannel to the iOS
// Picture-in-Picture system APIs.  Wires up an
// AVPictureInPictureController so the system records the activity as
// PiP-eligible the moment a remote screen share is published.
//
// CURRENT STATE: scaffolding only.  Actual rendering of the WebRTC track
// inside the PiP layer requires bridging livekit_client's RTCVideoFrames
// into an AVSampleBufferDisplayLayer — that needs a fork of the
// livekit_client iOS plugin to expose a PiP-renderer hook, which is
// tracked as a follow-up.  Until then, PiP entry will surface a system
// PiP window backed by a placeholder layer so iOS keeps the audio
// session alive (already covered by CallKit in Slice 2 anyway), but the
// user must return to the app to see the share.  Voice + the lounge UI
// stay running because of the foreground service / CallKit work in
// Slices 1 and 2; this plugin only governs the PiP-window rendering.

import AVKit
import Flutter
import UIKit

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
    // This is the path that integrates with WebRTC frames once we have a
    // frame bridge — for now the layer remains empty.
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
    // Aspect change — nothing to do until frame bridging lands.
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
