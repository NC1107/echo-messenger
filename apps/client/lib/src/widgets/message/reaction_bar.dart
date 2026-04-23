import 'package:flutter/material.dart';

import '../../models/reaction.dart';
import '../../theme/echo_theme.dart';

/// Displays per-emoji reaction pills, each showing the emoji and its count.
/// Pills where the current user has reacted are highlighted with accent color.
class ReactionBar extends StatelessWidget {
  final List<Reaction> reactions;
  final String? currentUserId;
  final void Function(Offset globalPosition)? onTap;

  const ReactionBar({
    super.key,
    required this.reactions,
    this.currentUserId,
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
                isHighlighted:
                    currentUserId != null &&
                    entry.value.any((r) => r.userId == currentUserId),
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
  final bool isHighlighted;
  final void Function(Offset globalPosition)? onTap;

  const _ReactionPill({
    required this.emoji,
    required this.count,
    required this.isHighlighted,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapUp: (details) => onTap?.call(details.globalPosition),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: isHighlighted
              ? context.accent.withValues(alpha: 0.15)
              : context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: isHighlighted ? context.accent : context.border,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              emoji,
              style: const TextStyle(
                fontSize: 14,
                decoration: TextDecoration.none,
              ),
            ),
            const SizedBox(width: 3),
            Text(
              '$count',
              style: TextStyle(
                fontSize: 12,
                color: isHighlighted ? context.accent : context.textMuted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
