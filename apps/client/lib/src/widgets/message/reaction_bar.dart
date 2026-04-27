import 'package:flutter/material.dart';

import '../../models/reaction.dart';
import '../../theme/echo_theme.dart';

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

class _ReactionPill extends StatelessWidget {
  final String emoji;
  final int count;
  final bool isMine;
  final Color chatBgColor;
  final void Function(Offset globalPosition)? onTap;

  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.isMine,
    required this.chatBgColor,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final bgColor = isMine ? context.sentBubble : context.recvBubble;
    final textColor = isMine ? Colors.white : context.textPrimary;

    return GestureDetector(
      onTapUp: (details) => onTap?.call(details.globalPosition),
      child: Container(
        height: 22,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        decoration: BoxDecoration(
          color: bgColor,
          borderRadius: BorderRadius.circular(11),
          border: Border.all(color: chatBgColor, width: 1.5),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              emoji,
              style: const TextStyle(
                fontSize: 13,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$count',
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
    );
  }
}
