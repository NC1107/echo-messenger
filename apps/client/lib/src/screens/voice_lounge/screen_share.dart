/// Screen share viewer, draggable floating window, and fullscreen overlay.
library;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as rtc;
import 'package:livekit_client/livekit_client.dart' as lk;

import '../../providers/livekit_voice/livekit_voice_provider.dart';
import '../../providers/screen_share_provider.dart';
import '../../theme/echo_theme.dart';
import 'screen_share_actions.dart' show toggleScreenShare;

// ---------------------------------------------------------------------------
// Aspect-aware track renderer
// ---------------------------------------------------------------------------

/// Renders a [lk.VideoTrack] and continuously reports the source video's
/// aspect ratio via [aspectRatio]. This lets a portrait-source screen
/// share (e.g. an iPhone) drive a portrait-shaped viewer window instead
/// of being letterboxed inside a hard-coded 16:9 frame.
///
/// Owns its own [rtc.RTCVideoRenderer] so it can listen for dimension
/// updates (the LiveKit-managed renderer inside [lk.VideoTrackRenderer]
/// doesn't expose those). The renderer is shared with the LiveKit
/// widget via the `cachedRenderer` parameter so we don't pay for two
/// textures.
class AspectAwareVideoTrack extends StatefulWidget {
  final lk.VideoTrack track;
  final lk.VideoViewFit fit;
  final lk.VideoViewMirrorMode mirrorMode;

  /// Output: receives the source video's width / height each time the
  /// underlying renderer reports new dimensions. Stays `null` until the
  /// first frame arrives. Callers can `addListener` to react.
  final ValueNotifier<double?> aspectRatio;

  const AspectAwareVideoTrack({
    super.key,
    required this.track,
    required this.aspectRatio,
    this.fit = lk.VideoViewFit.contain,
    this.mirrorMode = lk.VideoViewMirrorMode.off,
  });

  @override
  State<AspectAwareVideoTrack> createState() => _AspectAwareVideoTrackState();
}

class _AspectAwareVideoTrackState extends State<AspectAwareVideoTrack> {
  rtc.RTCVideoRenderer? _renderer;

  @override
  void initState() {
    super.initState();
    _initRenderer();
  }

  Future<void> _initRenderer() async {
    final renderer = rtc.RTCVideoRenderer();
    await renderer.initialize();
    if (!mounted) {
      // Disposed during async init; drop the renderer to avoid leaking.
      // ignore: unawaited_futures
      renderer.dispose();
      return;
    }
    renderer.addListener(_onRendererValue);
    setState(() => _renderer = renderer);
  }

  void _onRendererValue() {
    final r = _renderer;
    if (r == null) return;
    final w = r.value.width;
    final h = r.value.height;
    if (w <= 0 || h <= 0) return;
    final aspect = w / h;
    if (widget.aspectRatio.value != aspect) {
      widget.aspectRatio.value = aspect;
    }
  }

  @override
  void dispose() {
    final renderer = _renderer;
    _renderer = null;
    if (renderer != null) {
      renderer.removeListener(_onRendererValue);
      // VideoTrackRenderer was constructed with autoDisposeRenderer:
      // false so we own the lifecycle here.
      // ignore: unawaited_futures
      renderer.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final renderer = _renderer;
    if (renderer == null) {
      // While the renderer is initializing, render nothing. The first
      // valid frame triggers a rebuild via setState in _initRenderer.
      return const SizedBox.shrink();
    }
    return lk.VideoTrackRenderer(
      widget.track,
      fit: widget.fit,
      mirrorMode: widget.mirrorMode,
      cachedRenderer: renderer,
      autoDisposeRenderer: false,
    );
  }
}

// ---------------------------------------------------------------------------
// Screen share viewer (local)
// ---------------------------------------------------------------------------

class ScreenShareViewer extends ConsumerStatefulWidget {
  const ScreenShareViewer({super.key});

  @override
  ConsumerState<ScreenShareViewer> createState() => _ScreenShareViewerState();
}

class _ScreenShareViewerState extends ConsumerState<ScreenShareViewer> {
  // Lives for the widget's lifetime so the same notifier is reused
  // across rebuilds. AspectAwareVideoTrack writes into it as new
  // frames arrive; the ValueListenableBuilder below reads it.
  final ValueNotifier<double?> _aspectRatio = ValueNotifier<double?>(null);

  @override
  void dispose() {
    _aspectRatio.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Watch only isScreenSharing so the widget rebuilds when the
    // screen-share track becomes available, without rebuilding on
    // every audio-level tick.
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
            child: ValueListenableBuilder<double?>(
              valueListenable: _aspectRatio,
              // Fall back to 16:9 until the first frame arrives. After
              // that, the viewer matches the source so a portrait phone
              // share renders vertically.
              builder: (_, ratio, child) =>
                  AspectRatio(aspectRatio: ratio ?? 16 / 9, child: child),
              child: AspectAwareVideoTrack(
                track: screenTrack,
                aspectRatio: _aspectRatio,
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
              // Route through the shared toggle so the in-flight
              // guard + iOS broadcast settle delay applies here too —
              // tapping Close + then Share in quick succession was the
              // exact pattern that triggered the iOS "Recording
              // interrupted by another application" loop (#mobile-voice).
              onPressed: () => toggleScreenShare(context, ref),
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

/// Builder signature for [DraggableScreenShareWindow.childBuilder]. The
/// [aspectRatio] notifier is owned by the window and lives for the
/// widget's lifetime — pass it into an [AspectAwareVideoTrack] so the
/// window's aspect ratio reshapes when the source's dimensions change.
typedef ScreenShareChildBuilder =
    Widget Function(BuildContext context, ValueNotifier<double?> aspectRatio);

class DraggableScreenShareWindow extends StatefulWidget {
  /// Optional initial top offset from the canvas top edge. When null the
  /// window spawns centred in the visible canvas area instead of
  /// anchoring to a corner — matches user expectation that "starting a
  /// screen share" puts the window where they're already looking.
  final double? initialTop;
  final double? initialRight;
  final String label;
  final bool isLocal;

  /// Either a static [child] or a [childBuilder] that consumes the
  /// window's own aspect-ratio notifier. Exactly one must be provided.
  /// Use [childBuilder] when the child renders a live video track so
  /// the window can reshape itself to match the source (a phone share
  /// arrives portrait, not 16:9).
  final Widget? child;
  final ScreenShareChildBuilder? childBuilder;

  const DraggableScreenShareWindow({
    super.key,
    this.initialTop,
    this.initialRight,
    required this.label,
    this.isLocal = false,
    this.child,
    this.childBuilder,
  }) : assert(
         (child == null) != (childBuilder == null),
         'Provide exactly one of child or childBuilder',
       );

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
  bool _hovered = false;

  /// Owned by this widget; lives for the State's lifetime. Fed into the
  /// [ScreenShareChildBuilder] so the child (an [AspectAwareVideoTrack])
  /// can push the source video's true aspect ratio up to us as frames
  /// arrive. Stays at the default landscape value until the first
  /// frame reports a different shape.
  final ValueNotifier<double?> _sourceAspect = ValueNotifier<double?>(null);

  /// Locked aspect ratio for the window. Defaults to landscape; updated
  /// from [_sourceAspect] when the underlying video reports its first
  /// frame. Locking the window to the source ratio means the resize
  /// gesture scales the window proportionally and the underlying
  /// content never deforms regardless of source orientation.
  double _aspectRatio = 16.0 / 9.0;

  static const double _minWidth = 160;
  static const double _minHeight = 90;
  // Cap so a 9:19.5 phone share doesn't produce a window so narrow
  // it's unreadable, and so an ultrawide source can't grow wider than
  // the canvas typically affords.
  static const double _maxAspectRatio = 21.0 / 9.0;
  static const double _minAspectRatio = 9.0 / 21.0;

  @override
  void initState() {
    super.initState();
    _top = widget.initialTop ?? 0; // overridden in build when null
    _left = 0; // overridden in build
    _sourceAspect.addListener(_onAspectRatioChanged);
  }

  @override
  void dispose() {
    _sourceAspect.removeListener(_onAspectRatioChanged);
    _sourceAspect.dispose();
    super.dispose();
  }

  /// Adopt a new source aspect ratio. Preserves the user's current
  /// width as a mental anchor and recomputes height. Clamped so a
  /// degenerate stream can't collapse the window.
  void _onAspectRatioChanged() {
    final reported = _sourceAspect.value;
    if (reported == null || reported <= 0) return;
    final clamped = reported.clamp(_minAspectRatio, _maxAspectRatio);
    if ((clamped - _aspectRatio).abs() < 0.01) return;
    if (!mounted) return;
    setState(() {
      _aspectRatio = clamped;
      _height = (_width / _aspectRatio).clamp(_minHeight, double.infinity);
    });
  }

  @override
  Widget build(BuildContext context) {
    // Stack requires Positioned children: wrap in Positioned.fill, then inner Stack for LayoutBuilder.
    return Positioned.fill(
      child: LayoutBuilder(
        builder: (ctx, constraints) {
          if (!_positioned) {
            // initialTop/initialRight null → centre. Otherwise anchor to
            // the requested top-right offset (legacy callers).
            _top = widget.initialTop ?? (constraints.maxHeight - _height) / 2;
            _left = widget.initialRight != null
                ? constraints.maxWidth - widget.initialRight! - _width
                : (constraints.maxWidth - _width) / 2;
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
                child: MouseRegion(
                  onEnter: (_) => setState(() => _hovered = true),
                  onExit: (_) => setState(() => _hovered = false),
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
                              (widget.isLocal
                                      ? EchoTheme.danger
                                      : context.accent)
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
                          Positioned.fill(
                            child:
                                widget.child ??
                                widget.childBuilder!(context, _sourceAspect),
                          ),
                          // Label badge — hover-only. The rounded chip used
                          // to overhang the (rounded) window corner; only
                          // showing it on hover keeps the screen view clean
                          // and avoids the corner-collision visual.
                          if (_hovered)
                            Positioned(
                              top: 8,
                              left: 8,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 6,
                                  vertical: 3,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.6),
                                  borderRadius: BorderRadius.circular(6),
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
                          // Resize handle (bottom-right corner). Locked to
                          // _aspectRatio so the underlying screen content
                          // never deforms — only the bounding window
                          // scales proportionally.
                          if (_hovered)
                            Positioned(
                              right: 0,
                              bottom: 0,
                              child: GestureDetector(
                                onPanUpdate: (d) {
                                  setState(() {
                                    // Use the larger of dx/dy so the gesture
                                    // feels uniform; derive height from the
                                    // locked aspect ratio.
                                    final nextW = (_width + d.delta.dx).clamp(
                                      _minWidth,
                                      constraints.maxWidth - _left,
                                    );
                                    final aspectH = nextW / _aspectRatio;
                                    final nextH = aspectH.clamp(
                                      _minHeight,
                                      constraints.maxHeight - _top,
                                    );
                                    _width = nextH * _aspectRatio;
                                    _height = nextH;
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
