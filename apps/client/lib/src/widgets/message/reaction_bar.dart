import 'package:flutter/material.dart';

import '../../models/reaction.dart';
import '../../theme/echo_theme.dart';
import '../../theme/motion_tokens.dart';

/// Displays per-emoji reaction pills, each showing the emoji and its count.
/// The chip background matches the parent bubble color (sent or received) with
/// a halo border in the chat background color to visually separate it from
/// the bubble edge.
class ReactionBar extends StatelessWidget {
  final List<Reaction> reactions;
  final String? currentUserId;

  /// Whether the message belongs to the current user. Controls which bubble
  /// color is used as the chip background.
  final bool isMine;

  /// The chat panel background color, used as the halo border on each chip.
  final Color chatBgColor;

  final void Function(Offset globalPosition)? onTap;

  const ReactionBar({
    super.key,
    required this.reactions,
    this.currentUserId,
    required this.isMine,
    required this.chatBgColor,
    this.onTap,
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
              ),
          ],
        ),
      ),
    );
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

  const _ReactionPill({
    super.key,
    required this.emoji,
    required this.count,
    required this.isMine,
    required this.chatBgColor,
    this.onTap,
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
    final textColor = widget.isMine ? Colors.white : context.textPrimary;

    return GestureDetector(
      onTapUp: (details) => widget.onTap?.call(details.globalPosition),
      child: ScaleTransition(
        scale: _scale,
        child: Container(
          height: 22,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: BoxDecoration(
            color: bgColor,
            borderRadius: BorderRadius.circular(11),
            border: Border.all(color: widget.chatBgColor, width: 1.5),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                widget.emoji,
                style: const TextStyle(
                  fontSize: 13,
                  decoration: TextDecoration.none,
                ),
              ),
              const SizedBox(width: 3),
              Text(
                '${widget.count}',
                style: TextStyle(
                  fontSize: 11,
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
