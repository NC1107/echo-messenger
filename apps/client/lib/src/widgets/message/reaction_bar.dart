import 'package:flutter/material.dart';

import '../../models/reaction.dart';
import '../../providers/theme_provider.dart' show UIDensity;
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';

/// Displays per-emoji reaction pills, each showing the emoji and its count.
/// The chip background matches the parent bubble color (sent or received) with
/// a halo border in the chat background color to visually separate it from
/// the bubble edge.
///
/// Sizing scales with [density] (cozy / normal / compact) so reactions
/// match the surrounding message-stream density. Phase 2 follow-up.
class ReactionBar extends StatelessWidget {
  final List<Reaction> reactions;
  final String? currentUserId;

  /// Whether the message belongs to the current user. Controls which bubble
  /// color is used as the chip background.
  final bool isMine;

  /// The chat panel background color, used as the halo border on each chip.
  final Color chatBgColor;

  final void Function(Offset globalPosition)? onTap;

  /// UI density tier; defaults to compact (today's behavior) when omitted.
  final UIDensity density;

  const ReactionBar({
    super.key,
    required this.reactions,
    this.currentUserId,
    required this.isMine,
    required this.chatBgColor,
    this.onTap,
    this.density = UIDensity.compact,
  });

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Group reactions by emoji, preserving order of first appearance.
    final grouped = <String, List<Reaction>>{};
    for (final r in reactions) {
      grouped.putIfAbsent(r.emoji, () => []).add(r);
    }

    final totalCount = reactions.length;

    return DefaultTextStyle(
      style: TextStyle(
        decoration: TextDecoration.none,
        color: context.textPrimary,
      ),
      child: Semantics(
        label:
            '$totalCount ${totalCount == 1 ? 'reaction' : 'reactions'}: '
            '${grouped.keys.join(" ")}',
        button: true,
        child: Wrap(
          spacing: 4,
          runSpacing: 4,
          children: [
            for (final entry in grouped.entries)
              _ReactionPill(
                // Stable key so reordering this list doesn't let Flutter
                // recycle a different emoji's _ReactionPillState (whose
                // entry-scale animation has already played).
                key: ValueKey('reaction-${entry.key}'),
                emoji: entry.key,
                count: entry.value.length,
                isMine: isMine,
                chatBgColor: chatBgColor,
                onTap: onTap,
                density: density,
              ),
          ],
        ),
      ),
    );
  }
}

class _ReactionMetrics {
  final double height;
  final double hPadding;
  final double radius;
  final double emojiSize;
  final double countSize;
  final double gap;

  const _ReactionMetrics({
    required this.height,
    required this.hPadding,
    required this.radius,
    required this.emojiSize,
    required this.countSize,
    required this.gap,
  });

  static const cozy = _ReactionMetrics(
    height: 26,
    hPadding: 10,
    radius: 13,
    emojiSize: 15,
    countSize: 13,
    gap: 4,
  );
  static const normal = _ReactionMetrics(
    height: 24,
    hPadding: 9,
    radius: 12,
    emojiSize: 14,
    countSize: 12,
    gap: 3,
  );
  static const compact = _ReactionMetrics(
    height: 22,
    hPadding: 8,
    radius: 11,
    emojiSize: 13,
    countSize: 11,
    gap: 3,
  );

  static _ReactionMetrics forDensity(UIDensity d) {
    switch (d) {
      case UIDensity.cozy:
        return cozy;
      case UIDensity.normal:
        return normal;
      case UIDensity.compact:
        return compact;
    }
  }
}

/// Reaction pill with a one-shot scale-in on first mount.
///
/// AnimationController fires once on initState, with a soft overshoot
/// (`MotionCurves.expressiveBounce`) so a newly-added reaction reads as
/// "celebratory" without crossing into cartoon territory.  Reduce-motion
/// users skip the animation entirely.
class _ReactionPill extends StatefulWidget {
  final String emoji;
  final int count;
  final bool isMine;
  final Color chatBgColor;
  final void Function(Offset globalPosition)? onTap;
  final UIDensity density;

  const _ReactionPill({
    super.key,
    required this.emoji,
    required this.count,
    required this.isMine,
    required this.chatBgColor,
    this.onTap,
    required this.density,
  });

  @override
  State<_ReactionPill> createState() => _ReactionPillState();
}

class _ReactionPillState extends State<_ReactionPill>
    with SingleTickerProviderStateMixin {
  late final AnimationController _entry;
  late final Animation<double> _scale;

  @override
  void initState() {
    super.initState();
    _entry = AnimationController(vsync: this, duration: MotionDurations.quick);
    _scale = CurvedAnimation(
      parent: _entry,
      curve: MotionCurves.expressiveBounce,
    );
    // Defer to post-frame so MediaQuery (reduce-motion) is available.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (MediaQuery.of(context).disableAnimations) {
        _entry.value = 1.0;
      } else {
        _entry.forward(from: 0);
      }
    });
  }

  @override
  void dispose() {
    _entry.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bgColor = widget.isMine ? context.sentBubble : context.recvBubble;
    final textColor = widget.isMine
        ? context.onSentBubble
        : context.textPrimary;
    final m = _ReactionMetrics.forDensity(widget.density);

    return GestureDetector(
      onTapUp: (details) => widget.onTap?.call(details.globalPosition),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          height: m.height,
          padding: EdgeInsets.symmetric(horizontal: m.hPadding),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(m.radius),
            border: Border.all(color: widget.chatBgColor, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.emoji,
                style: TextStyle(
                  fontSize: m.emojiSize,
                  decoration: TextDecoration.none,
                ),
              ),
              SizedBox(width: m.gap),
              Text(
                '${widget.count}',
                style: TextStyle(
                  fontSize: m.countSize,
                  fontWeight: FontWeight.w600,
                  color: textColor.withValues(alpha: 0.75),
                  decoration: TextDecoration.none,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
