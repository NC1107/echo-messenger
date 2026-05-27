/// Screen share viewer, draggable floating window, and fullscreen overlay.
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';
import '../../theme/echo_theme.dart';

// ---------------------------------------------------------------------------
// Screen share viewer (local)
// ---------------------------------------------------------------------------

class ScreenShareViewer extends ConsumerWidget {
  const ScreenShareViewer({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    // Watch only isScreenSharing so the widget rebuilds when the screen share
    // track becomes available, without rebuilding on every audio level tick.
    ref.watch(screenShareProvider.select((s) => s.isScreenSharing));
    final room = ref.read(livekitVoiceProvider.notifier).room;
    final localParticipant = room?.localParticipant;
    if (localParticipant == null) return const SizedBox.shrink();

    final screenPub = localParticipant.videoTrackPublications
        .where(
          (pub) =>
              pub.track != null &&
              pub.source == lk.TrackSource.screenShareVideo,
        )
        .firstOrNull;

    final screenTrack = screenPub?.track as lk.VideoTrack?;
    if (screenTrack == null) return const SizedBox.shrink();

    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxHeight: 400),
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.border),
      ),
      clipBehavior: Clip.antiAlias,
      child: Stack(
        children: [
          Center(
            child: AspectRatio(
              aspectRatio: 16 / 9,
              child: lk.VideoTrackRenderer(
                screenTrack,
                fit: lk.VideoViewFit.contain,
              ),
            ),
          ),
          Positioned(
            top: 8,
            left: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: EchoTheme.danger.withValues(alpha: 0.85),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(Icons.screen_share, size: 14, color: Colors.white),
                  SizedBox(width: 6),
                  Text(
                    'Your screen',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
          Positioned(
            top: 8,
            right: 12,
            child: IconButton(
              icon: const Icon(Icons.close, size: 18, color: Colors.white),
              tooltip: 'Stop sharing',
              onPressed: () async {
                await ref
                    .read(livekitVoiceProvider.notifier)
                    .setScreenShareEnabled(false);
                ref
                    .read(screenShareProvider.notifier)
                    .setLiveKitScreenShareActive(false);
              },
              style: IconButton.styleFrom(
                backgroundColor: EchoTheme.danger.withValues(alpha: 0.7),
                padding: const EdgeInsets.all(10),
                minimumSize: const Size(44, 44),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Draggable + resizable screen share window on the canvas
// ---------------------------------------------------------------------------

class DraggableScreenShareWindow extends StatefulWidget {
  final double initialTop;
  final double initialRight;
  final String label;
  final bool isLocal;
  final Widget child;

  const DraggableScreenShareWindow({
    super.key,
    this.initialTop = 16,
    this.initialRight = 16,
    required this.label,
    this.isLocal = false,
    required this.child,
  });

  @override
  State<DraggableScreenShareWindow> createState() =>
      _DraggableScreenShareWindowState();
}

class _DraggableScreenShareWindowState
    extends State<DraggableScreenShareWindow> {
  late double _top;
  late double _left;
  double _width = 320;
  double _height = 180;
  bool _positioned = false;

  static const double _minWidth = 160;
  static const double _minHeight = 90;

  @override
  void initState() {
    super.initState();
    _top = widget.initialTop;
    _left = 0; // Will be calculated in build
  }

  @override
  Widget build(BuildContext context) {
    // Stack requires Positioned children: wrap in Positioned.fill, then inner Stack for LayoutBuilder.
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          if (!_positioned) {
            _left = constraints.maxWidth - widget.initialRight - _width;
            _positioned = true;
          }
          // Clamp position within bounds
          _left = _left.clamp(0, constraints.maxWidth - 60);
          _top = _top.clamp(0, constraints.maxHeight - 40);

          return Stack(
            clipBehavior: Clip.none,
            children: [
              Positioned(
                left: _left,
                top: _top,
                child: GestureDetector(
                  onPanUpdate: (d) {
                    setState(() {
                      _left += d.delta.dx;
                      _top += d.delta.dy;
                    });
                  },
                  child: Container(
                    width: _width,
                    height: _height,
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(12),
                      // Softer accent ring (alpha .25, hairline) so the
                      // window sits in the canvas without reading as a
                      // hard frame the user mistakes for the canvas
                      // boundary.
                      border: Border.all(
                        color:
                            (widget.isLocal ? EchoTheme.danger : context.accent)
                                .withValues(alpha: 0.25),
                        width: 0.5,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.5),
                          blurRadius: 16,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      children: [
                        Positioned.fill(child: widget.child),
                        // Label badge
                        Positioned(
                          top: 6,
                          left: 8,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 3,
                            ),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                const Icon(
                                  Icons.screen_share,
                                  size: 11,
                                  color: Colors.white70,
                                ),
                                const SizedBox(width: 4),
                                Text(
                                  widget.label,
                                  style: const TextStyle(
                                    color: Colors.white70,
                                    fontSize: 10,
                                    fontWeight: FontWeight.w500,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                        // Resize handle (bottom-right corner)
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: GestureDetector(
                            onPanUpdate: (d) {
                              setState(() {
                                _width = (_width + d.delta.dx).clamp(
                                  _minWidth,
                                  constraints.maxWidth - _left,
                                );
                                _height = (_height + d.delta.dy).clamp(
                                  _minHeight,
                                  constraints.maxHeight - _top,
                                );
                              });
                            },
                            child: Container(
                              width: 20,
                              height: 20,
                              alignment: Alignment.bottomRight,
                              child: Icon(
                                Icons.open_in_full,
                                size: 12,
                                color: Colors.white.withValues(alpha: 0.4),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Fullscreen video overlay
// ---------------------------------------------------------------------------

/// Full-screen page for a single video stream.
///
/// Hides system UI (status bar + navigation bar) while active.
/// Tap anywhere to close and restore system UI.
class FullscreenVideoPage extends StatefulWidget {
  final lk.VideoTrack track;
  final bool mirror;

  const FullscreenVideoPage({
    super.key,
    required this.track,
    this.mirror = false,
  });

  @override
  State<FullscreenVideoPage> createState() => _FullscreenVideoPageState();
}

class _FullscreenVideoPageState extends State<FullscreenVideoPage> {
  /// Desktop platforms (Linux/macOS/Windows) have no system UI bars to hide
  /// and some Linux window managers respond to SystemUiMode.immersive by
  /// graying out the Flutter window chrome, causing the lounge UI behind this
  /// route to appear grey (#17a). Skip the calls on desktop/web.
  static bool get _supportsSystemUiMode {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    if (_supportsSystemUiMode) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.immersive);
    }
  }

  @override
  void dispose() {
    if (_supportsSystemUiMode) {
      SystemChrome.setEnabledSystemUIMode(SystemUiMode.edgeToEdge);
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PopScope(
      canPop: true,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              Navigator.of(context).pop(),
        },
        child: Focus(
          autofocus: true,
          child: Scaffold(
            backgroundColor: Colors.black,
            body: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTap: () => Navigator.of(context).pop(),
              child: lk.VideoTrackRenderer(
                widget.track,
                fit: lk.VideoViewFit.contain,
                mirrorMode: widget.mirror
                    ? lk.VideoViewMirrorMode.mirror
                    : lk.VideoViewMirrorMode.off,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
