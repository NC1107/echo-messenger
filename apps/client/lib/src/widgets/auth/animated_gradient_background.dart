import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/accessibility_provider.dart';
import '../../theme/echo_theme.dart';

/// Slow-cycling animated linear-gradient background for auth/splash screens.
///
/// Cycles between three low-saturation stops derived from the theme accent
/// colour over a 40-second loop. When [AccessibilityState.reducedMotion] is
/// true the animation is skipped and a static gradient is painted instead.
///
/// Constraints:
/// - Uses only built-in Flutter animation primitives (no packages).
/// - Never touches layout — caller wraps this in a [Positioned.fill] or
///   equivalent to keep it strictly behind other widgets.
class AnimatedGradientBackground extends ConsumerStatefulWidget {
  const AnimatedGradientBackground({super.key});

  @override
  ConsumerState<AnimatedGradientBackground> createState() =>
      _AnimatedGradientBackgroundState();
}

class _AnimatedGradientBackgroundState
    extends ConsumerState<AnimatedGradientBackground>
    with SingleTickerProviderStateMixin {
  AnimationController? _controller;

  // Three gradient colour pairs the animation cycles through.
  // Each entry is [begin-accent-stop, end-accent-stop]; the dark background
  // is always present as the dominant colour so saturation stays very low.
  static const _stops = [
    [Color(0xFF0D0D2B), Color(0xFF0A0A0B)], // blue-leaning -> mainBg
    [Color(0xFF0B0B1F), Color(0xFF0F0A1A)], // indigo-leaning -> purple tint
    [Color(0xFF0A0F1A), Color(0xFF0A0A0B)], // teal-leaning -> mainBg
  ];

  static const _period = Duration(seconds: 40);

  @override
  void initState() {
    super.initState();
    _maybeStartController();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _maybeStartController();
  }

  void _maybeStartController() {
    final reduceMotion = ref.read(accessibilityProvider).reducedMotion;
    if (reduceMotion) {
      _controller?.dispose();
      _controller = null;
      return;
    }

    if (_controller != null) return;
    _controller = AnimationController(vsync: this, duration: _period)..repeat();
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // Re-check reduce-motion at build time so live changes apply.
    final reduceMotion = ref.watch(accessibilityProvider).reducedMotion;

    // Capture the controller in a local so the AnimatedBuilder closure binds
    // to a non-null reference even if `_controller` is later nulled out by
    // `_maybeStartController` (e.g. user toggles reduce-motion while a tick
    // microtask is already in flight). Without this capture the builder body
    // re-read `_controller!.value` on every tick and threw
    // "Null check operator used on a null value" from inside the framework
    // microtask loop. See #915.
    final controller = _controller;
    if (reduceMotion || controller == null) {
      return const _StaticGradient();
    }

    return AnimatedBuilder(
      animation: controller,
      builder: (context, _) {
        final t = controller.value; // 0..1 cycling

        // Map t across the three stop pairs with smooth crossfade.
        final segmentCount = _stops.length;
        final scaled = t * segmentCount;
        final segIndex = scaled.floor() % segmentCount;
        final nextIndex = (segIndex + 1) % segmentCount;
        final segT = scaled - scaled.floor();

        final topColor = Color.lerp(
          _stops[segIndex][0],
          _stops[nextIndex][0],
          segT,
        )!;
        final bottomColor = Color.lerp(
          _stops[segIndex][1],
          _stops[nextIndex][1],
          segT,
        )!;

        return Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: [topColor, EchoTheme.mainBg, bottomColor],
                stops: const [0.0, 0.5, 1.0],
              ),
            ),
          ),
        );
      },
    );
  }
}

/// Static fallback used when reduce-motion is active or the controller is null.
class _StaticGradient extends StatelessWidget {
  const _StaticGradient();

  @override
  Widget build(BuildContext context) {
    return const Positioned.fill(
      child: DecoratedBox(
        decoration: BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
            colors: [Color(0xFF0D0D2B), EchoTheme.mainBg, EchoTheme.mainBg],
            stops: [0.0, 0.5, 1.0],
          ),
        ),
      ),
    );
  }
}
