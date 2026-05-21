import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Animated shimmer effect that sweeps a gradient left-to-right across its
/// child. Uses a single [AnimationController] per instance with a 1.5 s
/// repeating cycle.
class _ShimmerEffect extends StatefulWidget {
  final Widget child;

  const _ShimmerEffect({required this.child});

  @override
  State<_ShimmerEffect> createState() => _ShimmerEffectState();
}

class _ShimmerEffectState extends State<_ShimmerEffect>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    // Respect the platform reduced-motion preference: hold the shimmer at
    // a still frame instead of repeating the sweep.
    if (MediaQuery.of(context).disableAnimations) {
      if (_controller.isAnimating) _controller.stop();
      _controller.value = 0.0;
    } else if (!_controller.isAnimating) {
      _controller.repeat();
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final surface = context.surface;
    final surfaceHover = context.surfaceHover;
    final disableAnimations = MediaQuery.of(context).disableAnimations;

    if (disableAnimations) {
      // Render the still surface tint without the animated gradient sweep.
      return widget.child;
    }

    return AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        // Sweep from -1 to 2 so the gradient band travels fully across.
        final value = _controller.value;
        final begin = Alignment(-1.0 + 3.0 * value, 0);
        final end = Alignment(-1.0 + 3.0 * value + 1.0, 0);

        return ShaderMask(
          blendMode: BlendMode.srcATop,
          shaderCallback: (bounds) {
            return LinearGradient(
              begin: begin,
              end: end,
              colors: [surface, surfaceHover, surface],
              stops: const [0.0, 0.5, 1.0],
            ).createShader(bounds);
          },
          child: child,
        );
      },
      child: widget.child,
    );
  }
}

/// A shimmer-effect skeleton loader that mimics content shape during loading.
class SkeletonLine extends StatelessWidget {
  final double width;
  final double height;
  final double borderRadius;

  const SkeletonLine({
    super.key,
    this.width = double.infinity,
    this.height = 14,
    this.borderRadius = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}

/// Skeleton placeholder for a conversation list item.
class ConversationSkeleton extends StatelessWidget {
  final int index;
  const ConversationSkeleton({super.key, this.index = 0});

  @override
  Widget build(BuildContext context) {
    return _ShimmerEffect(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: [
            // Avatar
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(
                color: context.surface,
                shape: BoxShape.circle,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  SkeletonLine(
                    width: 100 + (index * 37 % 60).toDouble(),
                    height: 14,
                  ),
                  const SizedBox(height: 6),
                  SkeletonLine(
                    width: 140 + (index * 53 % 80).toDouble(),
                    height: 11,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 8),
            const SkeletonLine(width: 32, height: 11),
          ],
        ),
      ),
    );
  }
}

/// Skeleton placeholder for a message bubble.
class MessageSkeleton extends StatelessWidget {
  final bool isMine;

  const MessageSkeleton({super.key, this.isMine = false});

  @override
  Widget build(BuildContext context) {
    return _ShimmerEffect(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Row(
          mainAxisAlignment: isMine
              ? MainAxisAlignment.end
              : MainAxisAlignment.start,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (!isMine) ...[
              Container(
                width: 32,
                height: 32,
                decoration: BoxDecoration(
                  color: context.surface,
                  shape: BoxShape.circle,
                ),
              ),
              const SizedBox(width: 8),
            ],
            Container(
              width: 120 + (hashCode % 100).toDouble(),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: context.surface,
                borderRadius: BorderRadius.circular(12),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  if (!isMine) const SkeletonLine(width: 60, height: 10),
                  if (!isMine) const SizedBox(height: 6),
                  const SkeletonLine(height: 12),
                  const SizedBox(height: 4),
                  SkeletonLine(
                    width: 60 + (hashCode % 40).toDouble(),
                    height: 12,
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// A list of skeleton conversation items for the sidebar loading state.
class ConversationListSkeleton extends StatelessWidget {
  final int count;

  const ConversationListSkeleton({super.key, this.count = 6});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (i) => ConversationSkeleton(key: ValueKey('skel-$i'), index: i),
      ),
    );
  }
}

/// Skeleton placeholder for a single stats card (admin dashboard etc.).
/// Mirrors the dimensions of the realtime/aggregate cards in
/// `admin_dashboard_screen.dart` so the layout doesn't reflow on load.
class StatCardSkeleton extends StatelessWidget {
  const StatCardSkeleton({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return _ShimmerEffect(
      child: Card(
        elevation: 0,
        color: scheme.surfaceContainerHigh,
        child: const Padding(
          padding: EdgeInsets.all(16),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SkeletonLine(width: 110, height: 11),
              SizedBox(height: 12),
              SkeletonLine(width: 64, height: 26),
            ],
          ),
        ),
      ),
    );
  }
}

/// Responsive grid of [count] [StatCardSkeleton]s — matches the column
/// breakpoints used by `_RealtimeGrid` / `_StatsGrid` so the loading
/// skeleton occupies the same footprint as the real content.
class StatCardGridSkeleton extends StatelessWidget {
  final int count;

  const StatCardGridSkeleton({super.key, this.count = 4});

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final cols = width >= 720 ? 4 : (width >= 480 ? 2 : 1);
        const spacing = 12.0;
        final cardWidth = (width - spacing * (cols - 1)) / cols;
        return Wrap(
          spacing: spacing,
          runSpacing: spacing,
          children: List.generate(
            count,
            (_) => SizedBox(width: cardWidth, child: const StatCardSkeleton()),
          ),
        );
      },
    );
  }
}

/// A list of skeleton message items for the chat loading state.
class MessageListSkeleton extends StatelessWidget {
  final int count;

  const MessageListSkeleton({super.key, this.count = 8});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: List.generate(
        count,
        (i) =>
            MessageSkeleton(key: ValueKey('msg-skel-$i'), isMine: i % 3 == 0),
      ),
    );
  }
}
