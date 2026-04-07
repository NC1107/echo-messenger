import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart';

/// State for screen sharing capture and local preview.
class ScreenShareState {
  final bool isScreenSharing;
  final String? error;

  const ScreenShareState({this.isScreenSharing = false, this.error});

  ScreenShareState copyWith({bool? isScreenSharing, String? error}) {
    return ScreenShareState(
      isScreenSharing: isScreenSharing ?? this.isScreenSharing,
      error: error,
    );
  }

  static const empty = ScreenShareState();
}

class ScreenShareNotifier extends StateNotifier<ScreenShareState> {
  MediaStream? _screenStream;
  RTCVideoRenderer? _screenRenderer;

  /// Expose the screen share stream for peer connection integration.
  MediaStream? get screenStream => _screenStream;

  /// Expose the renderer so the UI can display a local preview.
  RTCVideoRenderer? get screenRenderer => _screenRenderer;

  ScreenShareNotifier() : super(ScreenShareState.empty);

  /// Begin capturing the user's screen via `getDisplayMedia`.
  ///
  /// This requires HTTPS on web (localhost will not work).
  /// Platforms that do not support `getDisplayMedia` will surface a
  /// user-friendly error rather than crashing.
  Future<void> startScreenShare() async {
    if (state.isScreenSharing) return;

    try {
      final stream = await navigator.mediaDevices.getDisplayMedia({
        'video': true,
        'audio': false,
      });

      // Initialize the renderer for local preview.
      final renderer = RTCVideoRenderer();
      await renderer.initialize();
      renderer.srcObject = stream;

      _screenStream = stream;
      _screenRenderer = renderer;

      state = state.copyWith(isScreenSharing: true, error: null);

      // Listen for the user stopping the share via the browser/OS UI
      // (e.g. clicking "Stop sharing" in Chrome's native bar).
      final videoTracks = stream.getVideoTracks();
      if (videoTracks.isNotEmpty) {
        videoTracks.first.onEnded = () {
          stopScreenShare();
        };
      }
    } catch (e) {
      // getDisplayMedia can throw for many reasons:
      // - User cancelled the picker dialog
      // - Platform does not support screen capture
      // - HTTPS required but not available
      final message = _friendlyError(e);
      state = state.copyWith(isScreenSharing: false, error: message);
      debugPrint('[ScreenShare] getDisplayMedia failed: $e');
    }
  }

  /// Stop screen sharing and release all resources.
  Future<void> stopScreenShare() async {
    final stream = _screenStream;
    final renderer = _screenRenderer;

    _screenStream = null;
    _screenRenderer = null;

    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      await stream.dispose();
    }

    if (renderer != null) {
      renderer.srcObject = null;
      await renderer.dispose();
    }

    if (mounted) {
      state = state.copyWith(isScreenSharing: false, error: null);
    }
  }

  /// Map common exceptions to user-readable messages.
  static String _friendlyError(Object error) {
    final msg = error.toString().toLowerCase();
    if (msg.contains('notallowederror') || msg.contains('permission')) {
      return 'Screen sharing was cancelled or denied.';
    }
    if (msg.contains('notfounderror') || msg.contains('no sources')) {
      return 'No screen or window available to share.';
    }
    if (msg.contains('notsupportederror') || msg.contains('not supported')) {
      return 'Screen sharing is not supported on this platform.';
    }
    if (msg.contains('https') || msg.contains('secure context')) {
      return 'Screen sharing requires a secure (HTTPS) connection.';
    }
    if (!kIsWeb && defaultTargetPlatform == TargetPlatform.linux) {
      return 'Screen sharing failed on Linux. '
          'Ensure PipeWire, XDG Desktop Portal, and xdg-desktop-portal-gtk '
          'or xdg-desktop-portal-kde are installed and running.';
    }
    return 'Could not start screen sharing: $error';
  }

  @override
  void dispose() {
    // Fire-and-forget cleanup; the notifier is being torn down.
    unawaited(stopScreenShare());
    super.dispose();
  }
}

final screenShareProvider =
    StateNotifierProvider<ScreenShareNotifier, ScreenShareState>(
      (ref) => ScreenShareNotifier(),
    );
