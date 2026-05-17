import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../../services/media_cache_service.dart';
import '../../theme/echo_theme.dart';

/// Inline video player widget with play/pause controls and download
/// fallback. Initialises a [VideoPlayerController] on first build and
/// disposes it when removed from the tree.
class InlineVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String thumbUrl;
  final String rawUrl;
  final Map<String, String> headers;
  final Color surface;
  final Color mainBg;
  final Color border;

  /// Used as the "Open externally" callback in the fullscreen player when
  /// in-app playback fails (codec, auth, etc.). Tied to the chat's
  /// open-media launcher, which deep-links the system browser / app.
  final VoidCallback onOpen;

  const InlineVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.thumbUrl,
    required this.rawUrl,
    required this.headers,
    required this.surface,
    required this.mainBg,
    required this.border,
    required this.onOpen,
  });

  @override
  State<InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<InlineVideoPlayer> {
  Player? _player;
  VideoController? _videoController;
  bool _started = false;
  bool _initFailed = false;
  bool _isPlaying = false;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<String>? _errorSub;

  @override
  void dispose() {
    _playingSub?.cancel();
    _errorSub?.cancel();
    _player?.dispose();
    super.dispose();
  }

  /// Begin inline playback. Lazily constructs the [Player] so a chat with
  /// many videos doesn't hold N libmpv instances open at once — only the
  /// videos the user actually plays get a live controller. Falls back to
  /// the fullscreen dialog if init throws or the codec rejects the source.
  Future<void> _startInline() async {
    if (_started || _initFailed) return;
    setState(() => _started = true);
    try {
      final player = Player();
      final controller = VideoController(player);
      _playingSub = player.stream.playing.listen((v) {
        if (mounted) setState(() => _isPlaying = v);
      });
      _errorSub = player.stream.error.listen((e) {
        if (!mounted || e.isEmpty) return;
        debugPrint('[InlineVideoPlayer] error: $e');
        setState(() => _initFailed = true);
      });
      await player.open(
        Media(widget.videoUrl, httpHeaders: widget.headers),
        play: true,
      );
      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _videoController = controller;
      });
    } catch (e) {
      debugPrint('[InlineVideoPlayer] init failed: $e');
      if (mounted) setState(() => _initFailed = true);
    }
  }

  void _togglePlayPause() {
    final p = _player;
    if (p == null) return;
    _isPlaying ? p.pause() : p.play();
  }

  /// Opens the standalone fullscreen player. The fullscreen view owns its
  /// own [Player] so the inline session keeps its position and audio when
  /// the user dismisses the dialog.
  void _openFullscreen() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black,
      useSafeArea: false,
      builder: (dialogContext) => FullscreenVideoPlayer(
        videoUrl: widget.videoUrl,
        rawUrl: widget.rawUrl,
        headers: widget.headers,
        accent: context.accent,
        textMuted: context.textMuted,
        onLaunchExternal: widget.onOpen,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: widget.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.border),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: AspectRatio(aspectRatio: 16 / 9, child: _buildVideoArea()),
      ),
    );
  }

  /// Renders one of three states:
  ///   1. Pre-play: static thumbnail with a big play button (no controller
  ///      constructed yet — cheap).
  ///   2. Init failed: static thumbnail again, with an "Open in fullscreen"
  ///      tap target so the user can still try the standalone player.
  ///   3. Playing: live [Video] surface; single-tap toggles play/pause,
  ///      double-tap opens fullscreen, and a small fullscreen icon in the
  ///      corner is the explicit entry point for users who don't discover
  ///      the gesture.
  Widget _buildVideoArea() {
    // Server generates a JPEG first-frame thumbnail at upload time (#561).
    // If that endpoint 404s (older upload, ffmpeg missing, etc.), the
    // CachedNetworkImage's errorWidget falls back to the previous solid tile.
    // Use the pre-resolved thumbUrl from the widget so that query params
    // (e.g. ?ticket= on web) appear after /thumb, not before it (#411).
    final thumbUrl = widget.thumbUrl;
    // Inline thumbnail is 170px tall; cap decode height at 170 * DPR so
    // we don't hold a 4K still-frame in RAM for a thumbnail (#639).
    final dpr = MediaQuery.devicePixelRatioOf(context);
    final thumb = CachedNetworkImage(
      imageUrl: thumbUrl,
      cacheKey: stableMediaCacheKey(thumbUrl),
      cacheManager: chatMediaCacheManager,
      httpHeaders: widget.headers,
      fit: BoxFit.cover,
      width: double.infinity,
      height: 170,
      memCacheHeight: (170 * dpr).round(),
      placeholder: (_, _) => Container(color: widget.mainBg),
      errorWidget: (_, _, _) => Container(color: widget.mainBg),
    );

    final controller = _videoController;
    if (_started && !_initFailed && controller != null) {
      // State 3: live playback. Single tap = play/pause, double tap =
      // open fullscreen, the corner icon is an explicit fullscreen affordance.
      return Semantics(
        label: 'video player, double tap to open fullscreen',
        child: GestureDetector(
          onTap: _togglePlayPause,
          onDoubleTap: _openFullscreen,
          child: Stack(
            fit: StackFit.expand,
            children: [
              Video(controller: controller, controls: NoVideoControls),
              if (!_isPlaying)
                Center(child: _PlayOverlay(onTap: _togglePlayPause)),
              Positioned(
                top: 6,
                right: 6,
                child: Material(
                  color: Colors.black.withValues(alpha: 0.55),
                  shape: const CircleBorder(),
                  child: IconButton(
                    icon: const Icon(
                      Icons.fullscreen,
                      color: Colors.white,
                      size: 18,
                    ),
                    tooltip: 'Open fullscreen',
                    onPressed: _openFullscreen,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 32,
                      minHeight: 32,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    // States 1 + 2: thumbnail with a play button. Tapping starts inline
    // playback; if init has already failed once we route to the standalone
    // fullscreen player which renders a richer error UI.
    return Semantics(
      label: 'play video',
      button: true,
      child: GestureDetector(
        onTap: _initFailed ? _openFullscreen : _startInline,
        child: Stack(
          fit: StackFit.expand,
          children: [
            thumb,
            Center(child: _PlayOverlay(onTap: _startInline)),
          ],
        ),
      ),
    );
  }
}

/// Circular play button used both on the pre-play thumbnail and as the
/// "tap to resume" affordance over a paused inline video.
class _PlayOverlay extends StatelessWidget {
  final VoidCallback onTap;
  const _PlayOverlay({required this.onTap});

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 56,
        height: 56,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: Colors.black.withValues(alpha: 0.55),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.15),
            width: 1,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.4),
              blurRadius: 16,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        alignment: Alignment.center,
        child: const Padding(
          // Optical centering: the play triangle's mass sits left of its
          // bounding box, so nudge it right by 2px.
          padding: EdgeInsets.only(left: 2),
          child: Icon(Icons.play_arrow_rounded, color: Colors.white, size: 32),
        ),
      ),
    );
  }
}

/// Self-contained fullscreen video player. Owns its own [Player] +
/// [VideoController] so it doesn't depend on the inline bubble's init
/// succeeding first. Renders three states: loading, playing, and error
/// (with a clear "Open externally" affordance for codec / auth failures).
///
/// Backed by media_kit (libmpv) so the same code path works on every
/// platform — including Linux desktop, where the previous video_player
/// stack had no backend (#727).
class FullscreenVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String rawUrl;
  final Map<String, String> headers;
  final Color accent;
  final Color textMuted;

  /// Called from the error state's "Open externally" button. Typically
  /// wired to the same launcher the bubble's Download button uses.
  final VoidCallback onLaunchExternal;

  const FullscreenVideoPlayer({
    super.key,
    required this.videoUrl,
    required this.rawUrl,
    required this.headers,
    required this.accent,
    required this.textMuted,
    required this.onLaunchExternal,
  });

  @override
  State<FullscreenVideoPlayer> createState() => _FullscreenVideoPlayerState();
}

class _FullscreenVideoPlayerState extends State<FullscreenVideoPlayer> {
  Player? _player;
  VideoController? _videoController;
  final List<StreamSubscription<dynamic>> _subs = [];

  bool _initFailed = false;
  String? _errorMessage;

  // Mirrored player state — kept in sync via stream listeners so the build
  // method can stay synchronous.
  bool _isPlaying = false;
  Duration _position = Duration.zero;
  Duration _duration = Duration.zero;
  int _videoWidth = 0;
  int _videoHeight = 0;

  @override
  void initState() {
    super.initState();
    _init();
  }

  Future<void> _init() async {
    try {
      final player = Player();
      final controller = VideoController(player);

      _wireStreamListeners(player);

      await player.open(
        Media(widget.videoUrl, httpHeaders: widget.headers),
        play: true,
      );

      if (!mounted) {
        await player.dispose();
        return;
      }
      setState(() {
        _player = player;
        _videoController = controller;
      });
    } catch (e) {
      debugPrint(
        '[FullscreenVideoPlayer] init failed for ${widget.rawUrl}: $e',
      );
      if (mounted) {
        setState(() {
          _initFailed = true;
          _errorMessage = e.toString();
        });
      }
    }
  }

  void _wireStreamListeners(Player player) {
    _subs.add(
      player.stream.playing.listen((v) {
        if (mounted) setState(() => _isPlaying = v);
      }),
    );
    _subs.add(
      player.stream.position.listen((v) {
        if (mounted) setState(() => _position = v);
      }),
    );
    _subs.add(
      player.stream.duration.listen((v) {
        if (mounted) setState(() => _duration = v);
      }),
    );
    _subs.add(
      player.stream.width.listen((v) {
        if (mounted && v != null) setState(() => _videoWidth = v);
      }),
    );
    _subs.add(
      player.stream.height.listen((v) {
        if (mounted && v != null) setState(() => _videoHeight = v);
      }),
    );
    _subs.add(
      player.stream.error.listen((e) {
        if (!mounted || e.isEmpty) return;
        debugPrint('[FullscreenVideoPlayer] player error: $e');
        setState(() {
          _initFailed = true;
          _errorMessage = e;
        });
      }),
    );
  }

  @override
  void dispose() {
    for (final sub in _subs) {
      sub.cancel();
    }
    _player?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    final p = _player;
    if (p == null) return;
    _isPlaying ? p.pause() : p.play();
  }

  String _formatDuration(Duration d) =>
      '${d.inMinutes}:${(d.inSeconds % 60).toString().padLeft(2, '0')}';

  @override
  Widget build(BuildContext context) {
    final controller = _videoController;

    Widget body;
    if (_initFailed) {
      body = _buildErrorState();
    } else if (controller == null) {
      body = _buildLoadingState();
    } else {
      body = _buildPlayer(controller);
    }

    return Dialog.fullscreen(
      backgroundColor: Colors.black,
      child: Stack(
        children: [
          body,
          Positioned(
            top: 0,
            left: 0,
            right: 0,
            child: SafeArea(
              child: Align(
                alignment: Alignment.topRight,
                child: SizedBox(
                  width: 44,
                  height: 44,
                  child: IconButton(
                    padding: EdgeInsets.zero,
                    icon: const Icon(Icons.close, color: Colors.white),
                    tooltip: 'Close fullscreen',
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoadingState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: 32,
            height: 32,
            child: CircularProgressIndicator(
              strokeWidth: 2.5,
              color: widget.accent,
            ),
          ),
          const SizedBox(height: 16),
          const Text(
            'Loading video…',
            style: TextStyle(color: Colors.white70, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _buildErrorState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.center,
          children: [
            const Icon(
              Icons.videocam_off_outlined,
              color: Colors.white54,
              size: 48,
            ),
            const SizedBox(height: 16),
            const Text(
              "Couldn't play this video in app",
              textAlign: TextAlign.center,
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage ?? 'Unknown player error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.white54, fontSize: 12),
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 24),
            FilledButton.icon(
              onPressed: () {
                Navigator.of(context).pop();
                widget.onLaunchExternal();
              },
              icon: const Icon(Icons.open_in_new, size: 16),
              label: const Text('Open externally'),
              style: FilledButton.styleFrom(
                backgroundColor: widget.accent,
                foregroundColor: Colors.white,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildPlayer(VideoController controller) {
    final progress = (_duration.inMilliseconds > 0)
        ? (_position.inMilliseconds / _duration.inMilliseconds).clamp(0.0, 1.0)
        : 0.0;
    // Fall back to 16:9 until the codec reports real dimensions. Clamp wide
    // so a portrait phone clip doesn't take over the screen vertically.
    final aspectRatio = (_videoWidth > 0 && _videoHeight > 0)
        ? (_videoWidth / _videoHeight).clamp(0.3, 5.0)
        : 16 / 9;

    return Stack(
      children: [
        Center(
          child: GestureDetector(
            onTap: _togglePlayPause,
            child: AspectRatio(
              aspectRatio: aspectRatio,
              child: Video(controller: controller, controls: NoVideoControls),
            ),
          ),
        ),
        Positioned(
          left: 0,
          right: 0,
          bottom: 0,
          child: SafeArea(
            child: Container(
              decoration: const BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.bottomCenter,
                  end: Alignment.topCenter,
                  colors: [Colors.black87, Colors.transparent],
                ),
              ),
              padding: const EdgeInsets.fromLTRB(4, 16, 4, 4),
              child: Row(
                children: [
                  SizedBox(
                    width: 44,
                    height: 44,
                    child: IconButton(
                      padding: EdgeInsets.zero,
                      icon: Icon(
                        _isPlaying ? Icons.pause : Icons.play_arrow,
                        color: Colors.white,
                        size: 28,
                      ),
                      onPressed: _togglePlayPause,
                    ),
                  ),
                  Expanded(
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 6,
                        ),
                        overlayShape: const RoundSliderOverlayShape(
                          overlayRadius: 14,
                        ),
                        activeTrackColor: widget.accent,
                        inactiveTrackColor: widget.textMuted.withValues(
                          alpha: 0.3,
                        ),
                        thumbColor: widget.accent,
                      ),
                      child: Slider(
                        value: progress,
                        onChanged: (v) {
                          final ms = (v * _duration.inMilliseconds).round();
                          _player?.seek(Duration(milliseconds: ms));
                        },
                      ),
                    ),
                  ),
                  Padding(
                    padding: const EdgeInsets.only(right: 12),
                    child: Text(
                      '${_formatDuration(_position)} / ${_formatDuration(_duration)}',
                      style: const TextStyle(color: Colors.white, fontSize: 11),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// Centered error card shown when a GIF fails to load. Mirrors the look of
/// the "image failed to load" placeholder so failures don't visually jar.
