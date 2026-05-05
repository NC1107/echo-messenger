import 'dart:async';

import 'package:flutter/foundation.dart'
    show TargetPlatform, debugPrint, defaultTargetPlatform, kIsWeb;
import 'package:flutter_webrtc/flutter_webrtc.dart';
import 'package:riverpod_annotation/riverpod_annotation.dart';

part 'screen_share_provider.g.dart';

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

@Riverpod(keepAlive: true)
class ScreenShare extends _$ScreenShare {
  MediaStream? _screenStream;
  RTCVideoRenderer? _screenRenderer;

  /// True after the provider is disposed; gates state writes from
  /// async callbacks (the StateNotifier `mounted` check has no
  /// equivalent on Notifier so we track it manually).
  bool _disposed = false;

  /// Expose the screen share stream for peer connection integration.
  MediaStream? get screenStream => _screenStream;

  /// Expose the renderer so the UI can display a local preview.
  RTCVideoRenderer? get screenRenderer => _screenRenderer;

  @override
  ScreenShareState build() {
    ref.onDispose(() {
      _disposed = true;
      // Fire-and-forget cleanup when the provider is torn down.
      unawaited(stopScreenShare());
    });
    return ScreenShareState.empty;
  }

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

      _screenStream = stream;
      _screenRenderer = RTCVideoRenderer();
      await _screenRenderer!.initialize();
      _screenRenderer!.srcObject = stream;

      // Auto-stop on user-cancellation via browser native UI.
      stream.getVideoTracks().firstOrNull?.onEnded = () {
        debugPrint('[ScreenShare] track ended (user cancelled)');
        unawaited(stopScreenShare());
      };

      state = state.copyWith(isScreenSharing: true, error: null);
    } catch (e) {
      debugPrint('[ScreenShare] getDisplayMedia failed: $e');
      state = state.copyWith(isScreenSharing: false, error: _friendlyError(e));
    }
  }

  /// Stop the active capture, dispose the renderer, and clear state.
  Future<void> stopScreenShare() async {
    final stream = _screenStream;
    final renderer = _screenRenderer;

    _screenStream = null;
    _screenRenderer = null;

    if (renderer != null) {
      try {
        renderer.srcObject = null;
        await renderer.dispose();
      } catch (e) {
        debugPrint('[ScreenShare] renderer dispose failed: $e');
      }
    }

    if (stream != null) {
      try {
        for (final track in stream.getTracks()) {
          await track.stop();
        }
        await stream.dispose();
      } catch (e) {
        debugPrint('[ScreenShare] stream dispose failed: $e');
      }
    }

    if (!_disposed) {
      state = state.copyWith(isScreenSharing: false, error: null);
    }
  }

  /// Mark screen sharing as active/inactive without acquiring a stream.
  ///
  /// Used when LiveKit SDK manages the capture internally via
  /// [LocalParticipant.setScreenShareEnabled].
  void setLiveKitScreenShareActive(bool active) {
    if (!_disposed) {
      state = state.copyWith(isScreenSharing: active, error: null);
    }
  }

  /// Translate platform errors into actionable user-facing strings.
  String _friendlyError(Object error) {
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
}
