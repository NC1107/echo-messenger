import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';
import '../theme/motion_tokens.dart';

// ---------------------------------------------------------------------------
// VoiceSpeakingRing
// ---------------------------------------------------------------------------

/// Wraps [child] with a green pulsing ring when [audioLevel] exceeds
/// [threshold] (default 0.05).
///
/// Two layers run together while a participant is speaking:
///
/// - **Tight border ring** hugging the avatar — opacity is proportional
///   to the audio level and oscillates between ~0.55 and that level
///   peak so the ring stays visible during the breath.
/// - **Outward audio-radius rings** (Phase 3a of the UX roadmap) — two
///   concentric rings spawned at the avatar edge that expand outward
///   and fade as they go, staggered by half a cycle so a new pulse is
///   always visible. Painted via a single [CustomPainter] on top of
///   the tight ring layer; no per-frame allocations.
///
/// Reduce-motion: when [MediaQuery.of(context).disableAnimations] is
/// true, only the static tight ring is rendered (no pulse, no
/// expansion).
class VoiceSpeakingRing extends StatefulWidget {
  /// The avatar or tile content to decorate.
  final Widget child;

  /// Audio amplitude in the range [0.0, 1.0] polled from LiveKit.
  final double audioLevel;

  /// Threshold above which the ring becomes visible. Defaults to 0.05.
  final double threshold;

  /// Width of the tight border ring. Defaults to 2.5.
  final double ringWidth;

  /// Duration of one half-cycle of the tight-ring pulse animation.
  /// The audio-radius rings use the same value as the period of one
  /// outward expansion. Defaults to [MotionDurations.pulse].
  final Duration pulseDuration;

  /// How far each outer audio-radius ring expands beyond the tight
  /// ring before it fully fades. Defaults to 14 logical pixels.
  final double radiusReach;

  const VoiceSpeakingRing({
    super.key,
    required this.child,
    required this.audioLevel,
    this.threshold = 0.05,
    this.ringWidth = 2.5,
    this.pulseDuration = MotionDurations.pulse,
    this.radiusReach = 14,
  });

  @override
  State<VoiceSpeakingRing> createState() => VoiceSpeakingRingState();
}

// Exposed for testing (state can be read via tester.state(find.byType(...))).
class VoiceSpeakingRingState extends State<VoiceSpeakingRing>
    with TickerProviderStateMixin {
  /// Drives the tight ring's opacity oscillation. Forward / reverse
  /// pattern (preserves the existing 0→1→0 breath).
  late final AnimationController _pulse;

  /// Drives the audio-radius rings' outward expansion.  Repeats
  /// monotonically (no reverse) so the rings always grow outward
  /// rather than retracting back into the avatar.
  late final AnimationController _waves;

  /// Whether the tight-ring pulse animation is currently running.
  /// Used in tests.
  bool get isAnimating => _pulse.isAnimating;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: widget.pulseDuration)
      ..addStatusListener(_onPulseStatus);
    _waves = AnimationController(
      vsync: this,
      // Half-cycle stagger between two rings = continuous radar feel.
      duration: widget.pulseDuration,
    );

    // Defer the first start so MediaQuery (reduce-motion) is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _syncAnimations();
    });
  }

  void _onPulseStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _pulse.reverse();
    } else if (status == AnimationStatus.dismissed) {
      if (widget.audioLevel > widget.threshold) _pulse.forward();
    }
  }

  /// Start or stop both controllers based on the current speaking
  /// state and reduce-motion preference.
  void _syncAnimations() {
    final isSpeaking = widget.audioLevel > widget.threshold;
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    if (isSpeaking && !reduceMotion) {
      if (!_pulse.isAnimating) _pulse.forward();
      if (!_waves.isAnimating) _waves.repeat();
    } else {
      if (_pulse.isAnimating) {
        _pulse.stop();
        _pulse.value = 0;
      }
      if (_waves.isAnimating) {
        _waves.stop();
        _waves.value = 0;
      }
    }
  }

  @override
  void didUpdateWidget(VoiceSpeakingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.pulseDuration != oldWidget.pulseDuration) {
      // Duration setter applies on next tick; in-flight anim finishes its current cycle.
      _pulse.duration = widget.pulseDuration;
      _waves.duration = widget.pulseDuration;
    }
    _syncAnimations();
  }

  @override
  void dispose() {
    _pulse.dispose();
    _waves.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final isSpeaking = widget.audioLevel > widget.threshold;

    if (!isSpeaking) return widget.child;

    // Opacity scales linearly with level, clamped to [0.4, 1.0].
    final levelOpacity = (widget.audioLevel / 0.4).clamp(0.4, 1.0);
    final reduceMotion = MediaQuery.of(context).disableAnimations;

    if (reduceMotion) {
      // Static green tight ring — no pulse, no expansion.
      return _RingDecoration(
        ringOpacity: levelOpacity,
        ringWidth: widget.ringWidth,
        child: widget.child,
      );
    }

    // Collapse floor to level when quiet so pulse never exceeds the audio peak.
    final pulseFloor = math.min(0.55, levelOpacity);
    return AnimatedBuilder(
      animation: Listenable.merge([_pulse, _waves]),
      builder: (context, child) {
        final ringOpacity =
            pulseFloor + (_pulse.value * (levelOpacity - pulseFloor));
        return CustomPaint(
          // Behind the child + tight ring, so expanding rings appear to
          // emanate from the avatar's outer edge without obscuring it.
          painter: _AudioRadiusPainter(
            phase: _waves.value,
            level: levelOpacity,
            reach: widget.radiusReach,
            stroke: widget.ringWidth,
            color: EchoTheme.online,
          ),
          child: _RingDecoration(
            ringOpacity: ringOpacity,
            ringWidth: widget.ringWidth,
            child: child!,
          ),
        );
      },
      child: widget.child,
    );
  }
}

class _RingDecoration extends StatelessWidget {
  final double ringOpacity;
  final double ringWidth;
  final Widget child;

  const _RingDecoration({
    required this.ringOpacity,
    required this.ringWidth,
    required this.child,
  });

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        shape: BoxShape.circle,
        border: Border.all(
          color: EchoTheme.online.withValues(alpha: ringOpacity),
          width: ringWidth,
        ),
      ),
      child: child,
    );
  }
}

/// Paints the expanding audio-radius rings around a circular avatar.
///
/// Two ring "phases" share the same controller via a half-cycle
/// offset so a new wave is always being born while the previous one
/// fades out.  Opacity scales with [level] (the speaker's amplitude)
/// and falls linearly with progress; radius grows linearly from the
/// child's edge to `edge + reach`.
class _AudioRadiusPainter extends CustomPainter {
  final double phase; // [0, 1)
  final double level; // current peak opacity
  final double reach; // px to grow beyond the tight ring
  final double stroke; // line width of each ring
  final Color color;

  _AudioRadiusPainter({
    required this.phase,
    required this.level,
    required this.reach,
    required this.stroke,
    required this.color,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    // Tight ring sits on the child's outer edge; expansion starts there.
    final innerRadius = math.min(size.width, size.height) / 2;

    // Reuse one Paint across both waves to honour the no-per-frame-allocs guarantee.
    final paint = Paint()
      ..style = PaintingStyle.stroke
      ..strokeWidth = stroke * 0.65;

    void paintWave(double t) {
      // Skip near-invisible rings to keep the canvas cheap.
      if (t <= 0 || t >= 1) return;
      final opacity = (level * (1.0 - t)).clamp(0.0, 1.0);
      if (opacity < 0.04) return;
      final radius = innerRadius + reach * t;
      paint.color = color.withValues(alpha: opacity);
      canvas.drawCircle(center, radius, paint);
    }

    paintWave(phase);
    // Second ring, half a cycle out of phase.
    paintWave((phase + 0.5) % 1.0);
  }

  @override
  bool shouldRepaint(covariant _AudioRadiusPainter old) =>
      old.phase != phase ||
      old.level != level ||
      old.reach != reach ||
      old.stroke != stroke ||
      old.color != color;
}
