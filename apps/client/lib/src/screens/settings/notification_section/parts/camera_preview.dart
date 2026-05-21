part of '../../notification_section.dart';

// ---------------------------------------------------------------------------
// Live camera preview
// ---------------------------------------------------------------------------

/// Renders a live preview of the selected camera so users can confirm framing
/// and focus before joining a call. Tears down + re-opens the stream when the
/// selected [deviceId] changes, and stops tracks on dispose.
///
/// Supported on Android, iOS, macOS and Web (any platform where
/// `flutter_webrtc`'s `getUserMedia` is reliable). Linux/Windows desktop fall
/// back to a "preview not supported" placeholder.
class _CameraPreview extends StatefulWidget {
  /// The voice-settings camera device id. Empty string means "default".
  final String deviceId;

  const _CameraPreview({required this.deviceId});

  @override
  State<_CameraPreview> createState() => _CameraPreviewState();
}

class _CameraPreviewState extends State<_CameraPreview> {
  final webrtc.RTCVideoRenderer _renderer = webrtc.RTCVideoRenderer();
  webrtc.MediaStream? _stream;
  bool _rendererInitialized = false;
  String? _error;
  bool _permissionDenied = false;
  // Monotonic generation counter — every _restart()/_startStream() entry
  // increments this and captures the new value locally. Any in-flight call
  // whose captured value no longer matches must cancel cleanly without
  // mutating shared state, preventing device-change races (#404).
  int _generation = 0;

  bool get _platformSupported {
    if (kIsWeb) return true;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS ||
        defaultTargetPlatform == TargetPlatform.macOS;
  }

  @override
  void initState() {
    super.initState();
    if (_platformSupported) {
      _initRenderer();
    }
  }

  @override
  void didUpdateWidget(covariant _CameraPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.deviceId != widget.deviceId && _platformSupported) {
      _restart();
    }
  }

  Future<void> _initRenderer() async {
    final int gen = ++_generation;
    await _renderer.initialize();
    if (!mounted || gen != _generation) return;
    setState(() => _rendererInitialized = true);
    await _startStream();
  }

  Future<void> _restart() async {
    // Only attempt a restart once the renderer has been initialized — a
    // device-id change that races initialize() would otherwise call
    // _startStream() against an uninitialized renderer and throw a
    // StateError on some webrtc plugin versions.
    if (!_rendererInitialized) return;
    await _stopStream();
    await _startStream();
  }

  Future<void> _startStream() async {
    final int gen = ++_generation;
    if (mounted) {
      setState(() {
        _error = null;
        _permissionDenied = false;
      });
    }
    try {
      final constraints = <String, dynamic>{
        'audio': false,
        'video': widget.deviceId.isEmpty
            ? true
            : {
                'deviceId': {'exact': widget.deviceId},
              },
      };
      final stream = await webrtc.navigator.mediaDevices.getUserMedia(
        constraints,
      );
      // Stale call (newer _startStream/_restart superseded us) or widget
      // unmounted: tear down the just-acquired stream and bail out without
      // touching shared state.
      if (!mounted || gen != _generation) {
        for (final t in stream.getTracks()) {
          t.stop();
        }
        await stream.dispose();
        return;
      }
      _stream = stream;
      _renderer.srcObject = stream;
      setState(() {});
    } catch (e) {
      if (!mounted || gen != _generation) return;
      final msg = e.toString().toLowerCase();
      setState(() {
        _permissionDenied =
            msg.contains('permission') || msg.contains('notallowed');
        _error = _permissionDenied
            ? 'Camera access blocked.'
            : 'Could not start camera preview.';
      });
    }
  }

  Future<void> _stopStream() async {
    final stream = _stream;
    _stream = null;
    _renderer.srcObject = null;
    if (stream != null) {
      for (final t in stream.getTracks()) {
        t.stop();
      }
      await stream.dispose();
    }
  }

  @override
  void dispose() {
    // dispose() must be synchronous; fire-and-forget of _stopStream() left
    // the camera hardware live on Android until the next GC. Instead, stop
    // tracks synchronously here so the OS camera indicator clears the
    // moment the widget unmounts. The async stream/renderer dispose
    // futures are issued unawaited in the correct order.
    _generation++;
    final stream = _stream;
    final rendererInitialized = _rendererInitialized;
    _stream = null;
    _rendererInitialized = false;
    // Guard the srcObject clear — the underlying RTCVideoRenderer throws
    // "Call initialize before setting the stream" if dispose() fires
    // without the renderer ever having been initialised (the settings
    // screen mounts the preview widget but the user never opened the
    // camera step). Skip the clear if there was no init.
    if (rendererInitialized) {
      _renderer.srcObject = null;
    }
    if (stream != null) {
      for (final t in stream.getTracks()) {
        t.stop();
      }
      // Unawaited: dispose() is sync. Track.stop() above already released
      // the hardware; this just cleans up plugin-side handles.
      // ignore: unawaited_futures
      stream.dispose();
    }
    if (rendererInitialized) {
      // ignore: unawaited_futures
      _renderer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_platformSupported) {
      return _buildPlaceholder(
        context,
        icon: Icons.videocam_off_outlined,
        message: 'Preview not supported on this platform.',
      );
    }
    if (_error != null) {
      return _buildPlaceholder(
        context,
        icon: _permissionDenied ? Icons.lock_outline : Icons.error_outline,
        message: _error!,
        action: _permissionDenied
            ? TextButton(
                onPressed: _startStream,
                child: const Text('Grant camera access'),
              )
            : null,
      );
    }

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: Container(
              color: Colors.black,
              child: _rendererInitialized && _stream != null
                  ? webrtc.RTCVideoView(
                      _renderer,
                      objectFit: webrtc
                          .RTCVideoViewObjectFit
                          .RTCVideoViewObjectFitCover,
                      mirror: true,
                    )
                  : const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPlaceholder(
    BuildContext context, {
    required IconData icon,
    required String message,
    Widget? action,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 320),
        child: AspectRatio(
          aspectRatio: 16 / 9,
          child: Container(
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: context.border),
            ),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                Icon(icon, color: context.textMuted, size: 28),
                const SizedBox(height: 8),
                Text(
                  message,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                  textAlign: TextAlign.center,
                ),
                if (action != null) ...[const SizedBox(height: 8), action],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
