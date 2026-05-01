import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

// ---------------------------------------------------------------------------
// VoiceSpeakingRing
// ---------------------------------------------------------------------------

/// Wraps [child] with a green pulsing ring when [audioLevel] exceeds
/// [threshold] (default 0.05).
///
/// Ring opacity is proportional to the audio level and, unless
/// [MediaQuery.disableAnimations] is set, pulses at 700 ms intervals so
/// active speakers are clearly visible at a glance.
///
/// Reduce-motion: when [MediaQuery.of(context).disableAnimations] is true a
/// static (non-pulsing) ring is rendered at full levelOpacity.
class VoiceSpeakingRing extends StatefulWidget {
  /// The avatar or tile content to decorate.
  final Widget child;

  /// Audio amplitude in the range [0.0, 1.0] polled from LiveKit.
  final double audioLevel;

  /// Threshold above which the ring becomes visible. Defaults to 0.05.
  final double threshold;

  /// Width of the ring border. Defaults to 2.5.
  final double ringWidth;

  /// Duration of one half-cycle of the pulse animation. Defaults to 700 ms.
  final Duration pulseDuration;

  const VoiceSpeakingRing({
    super.key,
    required this.child,
    required this.audioLevel,
    this.threshold = 0.05,
    this.ringWidth = 2.5,
    this.pulseDuration = const Duration(milliseconds: 700),
  });

  @override
  State<VoiceSpeakingRing> createState() => VoiceSpeakingRingState();
}

// Exposed for testing (state can be read via tester.state(find.byType(...))).
class VoiceSpeakingRingState extends State<VoiceSpeakingRing>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse;

  /// Whether the pulse animation is currently running. Used in tests.
  bool get isAnimating => _pulse.isAnimating;

  @override
  void initState() {
    super.initState();
    _pulse = AnimationController(vsync: this, duration: widget.pulseDuration)
      ..addStatusListener(_onStatus);
    // Defer the first start so MediaQuery (reduce-motion) is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (widget.audioLevel > widget.threshold &&
          !MediaQuery.of(context).disableAnimations) {
        _pulse.forward();
      }
    });
  }

  void _onStatus(AnimationStatus status) {
    if (status == AnimationStatus.completed) {
      _pulse.reverse();
    } else if (status == AnimationStatus.dismissed) {
      if (widget.audioLevel > widget.threshold) _pulse.forward();
    }
  }

  @override
  void didUpdateWidget(VoiceSpeakingRing oldWidget) {
    super.didUpdateWidget(oldWidget);
    final isSpeaking = widget.audioLevel > widget.threshold;
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    if (isSpeaking && !_pulse.isAnimating && !reduceMotion) {
      _pulse.forward();
    } else if (!isSpeaking && _pulse.isAnimating) {
      _pulse.stop();
      _pulse.value = 0;
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
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
      // Static green ring -- no animation.
      return _RingDecoration(
        ringOpacity: levelOpacity,
        ringWidth: widget.ringWidth,
        child: widget.child,
      );
    }

    // Animated pulsing ring -- opacity oscillates between 0.35 and levelOpacity.
    return AnimatedBuilder(
      animation: _pulse,
      builder: (context, child) {
        final ringOpacity = 0.35 + (_pulse.value * (levelOpacity - 0.35));
        return _RingDecoration(
          ringOpacity: ringOpacity,
          ringWidth: widget.ringWidth,
          child: child!,
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
