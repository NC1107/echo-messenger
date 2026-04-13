import 'package:flutter/material.dart';

import '../../models/reaction.dart';
import '../../theme/echo_theme.dart';

/// Displays a compact pill showing all reaction emojis and a total count.
class ReactionBar extends StatelessWidget {
  final List<Reaction> reactions;
  final void Function(Offset globalPosition)? onTap;

  const ReactionBar({super.key, required this.reactions, this.onTap});

  @override
  Widget build(BuildContext context) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Collect unique emojis preserving order of first appearance.
    final seen = <String>{};
    final uniqueEmojis = <String>[];
    for (final r in reactions) {
      if (seen.add(r.emoji)) uniqueEmojis.add(r.emoji);
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
            '${uniqueEmojis.join(" ")}',
        button: true,
        child: GestureDetector(
          onTapUp: (details) => onTap?.call(details.globalPosition),
          child: Container(
            height: 24,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.border, width: 1),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                for (final emoji in uniqueEmojis)
                  Padding(
                    padding: const EdgeInsets.only(right: 2),
                    child: Text(
                      emoji,
                      style: const TextStyle(
                        fontSize: 14,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                if (totalCount > 1) ...[
                  const SizedBox(width: 2),
                  Text(
                    '$totalCount',
                    style: TextStyle(fontSize: 12, color: context.textMuted),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
