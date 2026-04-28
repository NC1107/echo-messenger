import 'dart:async';
import 'dart:typed_data';

import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;

import '../../theme/echo_theme.dart';

/// Number of waveform bars shown in the visualizer.
const _kBarCount = 36;

/// Minimum bar height fraction (0–1) relative to widget height.
const _kMinBarFraction = 0.15;

/// Widget that renders a voice message with a waveform visualizer and playback
/// controls. Accepts either a remote URL (for received/sent messages) or raw
/// audio bytes (for the just-recorded preview before the message is sent).
class VoiceMessageWidget extends StatefulWidget {
  /// URL of the audio file. Provide this for messages fetched from the server.
  final String? audioUrl;

  /// Pre-fetched audio bytes. When provided, plays from memory without a
  /// network request (used immediately after recording).
  final Uint8List? audioBytes;

  /// Optional waveform amplitude samples in the range [0.0, 1.0].
  /// When null the widget uses a default rounded-hill waveform shape.
  final List<double>? waveformSamples;

  /// HTTP headers to use when fetching the audio URL (e.g. Authorization).
  final Map<String, String> headers;

  /// Whether this message was sent by the local user (affects bar color).
  final bool isMine;

  const VoiceMessageWidget({
    super.key,
    this.audioUrl,
    this.audioBytes,
    this.waveformSamples,
    this.headers = const {},
    this.isMine = false,
  }) : assert(
         audioUrl != null || audioBytes != null,
         'Provide either audioUrl or audioBytes',
       );

  @override
  State<VoiceMessageWidget> createState() => _VoiceMessageWidgetState();
}

class _VoiceMessageWidgetState extends State<VoiceMessageWidget> {
  final _player = AudioPlayer();

  bool _isPlaying = false;
  bool _isLoading = false;

  /// Last playback / fetch error message. Surfaced inline below the
  /// waveform so the user knows tapping play didn't silently fail.
  String? _loadError;
  Duration _duration = Duration.zero;
  Duration _position = Duration.zero;

  /// Current playback speed. Cycles 1.0 -> 1.5 -> 2.0 -> 1.0 on tap.
  double _playbackRate = 1.0;

  /// Visual-only progress fraction during a drag gesture ([0, 1]).
  /// null means no drag is in progress — use [_progress] instead.
  double? _dragProgress;

  StreamSubscription<void>? _completeSub;
  StreamSubscription<Duration>? _durationSub;
  StreamSubscription<Duration>? _positionSub;
  StreamSubscription<PlayerState>? _stateSub;

  late List<double> _bars;

  @override
  void initState() {
    super.initState();
    _bars = _buildBars(widget.waveformSamples);
    _wirePlayerListeners();
  }

  @override
  void dispose() {
    _completeSub?.cancel();
    _durationSub?.cancel();
    _positionSub?.cancel();
    _stateSub?.cancel();
    _player.dispose();
    super.dispose();
  }

  // ---------------------------------------------------------------------------
  // Waveform helpers
  // ---------------------------------------------------------------------------

  /// Down-samples or up-samples the provided amplitude list to [_kBarCount]
  /// bars, each clamped to [_kMinBarFraction, 1.0].
  List<double> _buildBars(List<double>? samples) {
    if (samples == null || samples.isEmpty) {
      // Default: a pleasant rounded hill shape centred in the widget.
      return List.generate(_kBarCount, (i) {
        final t = i / (_kBarCount - 1);
        final curve = 0.5 - 0.5 * ((2 * t - 1).abs());
        return _kMinBarFraction + (1 - _kMinBarFraction) * (0.2 + curve * 0.6);
      });
    }

    return List.generate(_kBarCount, (i) {
      final srcIdx = (i / (_kBarCount - 1) * (samples.length - 1)).round();
      final v = samples[srcIdx.clamp(0, samples.length - 1)];
      return v.clamp(_kMinBarFraction, 1.0);
    });
  }

  // ---------------------------------------------------------------------------
  // Player setup
  // ---------------------------------------------------------------------------

  void _wirePlayerListeners() {
    _durationSub = _player.onDurationChanged.listen((d) {
      if (mounted) setState(() => _duration = d);
    });
    _positionSub = _player.onPositionChanged.listen((p) {
      if (mounted) setState(() => _position = p);
    });
    _stateSub = _player.onPlayerStateChanged.listen((state) {
      if (mounted) setState(() => _isPlaying = state == PlayerState.playing);
    });
    _completeSub = _player.onPlayerComplete.listen((_) {
      if (mounted) {
        setState(() {
          _isPlaying = false;
          _position = Duration.zero;
        });
      }
    });
  }

  Future<void> _togglePlayback() async {
    if (_isLoading) return;

    if (_isPlaying) {
      await _player.pause();
      return;
    }

    // Resume from paused position.
    if (_position > Duration.zero &&
        _duration > Duration.zero &&
        _position < _duration) {
      await _player.resume();
      return;
    }

    setState(() {
      _isLoading = true;
      _loadError = null;
    });
    try {
      final bytes = widget.audioBytes;
      if (bytes != null) {
        await _player.play(BytesSource(bytes));
      } else {
        final url = widget.audioUrl!;
        if (widget.headers.isNotEmpty) {
          // Download with auth headers then play from memory.
          final response = await http.get(
            Uri.parse(url),
            headers: widget.headers,
          );
          if (response.statusCode >= 200 && response.statusCode < 300) {
            await _player.play(BytesSource(response.bodyBytes));
          } else {
            // Surface the failure to the user instead of silently no-op'ing.
            // Without this, mobile users tapped the play button and saw
            // nothing happen (#554).
            final reason = 'fetch failed (${response.statusCode})';
            debugPrint('[VoiceMsg] $reason');
            if (mounted) {
              setState(() => _loadError = reason);
            }
          }
        } else {
          await _player.play(UrlSource(url));
        }
      }
    } catch (e) {
      debugPrint('[VoiceMsg] play error: $e');
      if (mounted) {
        setState(() => _loadError = e.toString());
      }
    } finally {
      if (mounted) setState(() => _isLoading = false);
    }
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  Future<void> _cyclePlaybackRate() async {
    final next = switch (_playbackRate) {
      1.0 => 1.5,
      1.5 => 2.0,
      _ => 1.0,
    };
    setState(() => _playbackRate = next);
    try {
      await _player.setPlaybackRate(next);
    } catch (_) {
      // Best-effort; platform may not support playback rate.
    }
  }

  String _formatRateLabel(double rate) {
    final isInt = rate == rate.truncateToDouble();
    return isInt ? '${rate.toInt()}x' : '${rate.toStringAsFixed(1)}x';
  }

  String _formatDuration(Duration d) {
    final m = d.inMinutes.remainder(60);
    final s = d.inSeconds.remainder(60).toString().padLeft(2, '0');
    return '$m:$s';
  }

  /// Commit a seek to the player based on an x offset within the waveform width.
  void _seekToFraction(double dx, double totalWidth) {
    if (_duration.inMilliseconds == 0) return;
    final fraction = (dx / totalWidth).clamp(0.0, 1.0);
    final seekMs = (fraction * _duration.inMilliseconds).round();
    _player.seek(Duration(milliseconds: seekMs));
  }

  /// Update the visual-only drag progress without touching the player.
  void _updateDragProgress(double dx, double totalWidth) {
    setState(() {
      _dragProgress = (dx / totalWidth).clamp(0.0, 1.0);
    });
  }

  void _cancelDrag() {
    setState(() => _dragProgress = null);
  }

  /// Playback progress in [0, 1].
  double get _progress {
    if (_duration.inMilliseconds == 0) return 0;
    return (_position.inMilliseconds / _duration.inMilliseconds).clamp(
      0.0,
      1.0,
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final accentColor = widget.isMine ? context.textPrimary : context.accent;
    final mutedColor = context.textMuted;

    final showPosition = _position > Duration.zero;
    final showDuration = _duration > Duration.zero;
    final durationLabel = showPosition
        ? _formatDuration(_position)
        : (showDuration ? _formatDuration(_duration) : '0:00');

    return SizedBox(
      width: 272,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          // Play / pause button
          SizedBox(
            width: 36,
            height: 36,
            child: _isLoading
                ? Padding(
                    padding: const EdgeInsets.all(8),
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: accentColor,
                    ),
                  )
                : GestureDetector(
                    onTap: _togglePlayback,
                    child: Container(
                      decoration: BoxDecoration(
                        color: accentColor.withValues(alpha: 0.15),
                        shape: BoxShape.circle,
                      ),
                      child: Icon(
                        _isPlaying
                            ? Icons.pause_rounded
                            : Icons.play_arrow_rounded,
                        size: 20,
                        color: accentColor,
                      ),
                    ),
                  ),
          ),
          const SizedBox(width: 4),
          Tooltip(
            message: 'Playback speed',
            child: InkWell(
              onTap: _cyclePlaybackRate,
              borderRadius: BorderRadius.circular(10),
              child: Container(
                width: 32,
                height: 24,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: accentColor.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  _formatRateLabel(_playbackRate),
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: accentColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          // Waveform + duration label
          Expanded(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                LayoutBuilder(
                  builder: (context, constraints) {
                    return GestureDetector(
                      behavior: HitTestBehavior.opaque,
                      onTapDown: (details) => _seekToFraction(
                        details.localPosition.dx,
                        constraints.maxWidth,
                      ),
                      onHorizontalDragUpdate: (details) => _updateDragProgress(
                        details.localPosition.dx,
                        constraints.maxWidth,
                      ),
                      onHorizontalDragEnd: (details) {
                        // Recover last x from dragProgress to commit the seek.
                        final p = _dragProgress;
                        if (p != null && _duration.inMilliseconds > 0) {
                          final seekMs = (p * _duration.inMilliseconds).round();
                          _player.seek(Duration(milliseconds: seekMs));
                        }
                        setState(() => _dragProgress = null);
                      },
                      onHorizontalDragCancel: _cancelDrag,
                      child: _WaveformBars(
                        bars: _bars,
                        progress: _dragProgress ?? _progress,
                        activeColor: accentColor,
                        inactiveColor: mutedColor,
                        height: 28,
                      ),
                    );
                  },
                ),
                const SizedBox(height: 2),
                Text(
                  _loadError ?? durationLabel,
                  style: TextStyle(
                    fontSize: 10,
                    color: _loadError != null ? EchoTheme.danger : mutedColor,
                    fontFeatures: const [FontFeature.tabularFigures()],
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Paints a series of vertical bars representing audio amplitude. Bars whose
/// centre is to the left of [progress * width] are painted with [activeColor];
/// remaining bars use [inactiveColor].
class _WaveformBars extends StatelessWidget {
  final List<double> bars;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;
  final double height;

  const _WaveformBars({
    required this.bars,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
    required this.height,
  });

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      width: double.infinity,
      child: CustomPaint(
        painter: _WaveformPainter(
          bars: bars,
          progress: progress,
          activeColor: activeColor,
          inactiveColor: inactiveColor,
        ),
      ),
    );
  }
}

class _WaveformPainter extends CustomPainter {
  final List<double> bars;
  final double progress;
  final Color activeColor;
  final Color inactiveColor;

  const _WaveformPainter({
    required this.bars,
    required this.progress,
    required this.activeColor,
    required this.inactiveColor,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (bars.isEmpty) return;

    const barRadius = Radius.circular(2);
    const barGap = 2.0;
    final totalBars = bars.length;
    final barWidth = (size.width - barGap * (totalBars - 1)) / totalBars;
    final progressX = size.width * progress;

    final activePaint = Paint()
      ..color = activeColor
      ..style = PaintingStyle.fill;
    final inactivePaint = Paint()
      ..color = inactiveColor
      ..style = PaintingStyle.fill;

    for (var i = 0; i < totalBars; i++) {
      final barH = bars[i] * size.height;
      final left = i * (barWidth + barGap);
      final top = (size.height - barH) / 2;
      final rect = RRect.fromLTRBR(
        left,
        top,
        left + barWidth,
        top + barH,
        barRadius,
      );
      final isActive = (left + barWidth / 2) <= progressX;
      canvas.drawRRect(rect, isActive ? activePaint : inactivePaint);
    }
  }

  @override
  bool shouldRepaint(_WaveformPainter old) =>
      old.progress != progress ||
      old.activeColor != activeColor ||
      old.inactiveColor != inactiveColor ||
      old.bars != bars;
}
