import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';
import '../message_item.dart' show reactionEmojis;

/// Build the quick-react bar overlay shown when a user long-presses a
/// message. The caller inserts and later removes the returned [OverlayEntry].
OverlayEntry buildReactionPickerOverlay({
  required BuildContext context,
  required ChatMessage message,
  required String myUserId,
  required Offset tapPosition,
  required VoidCallback onDismiss,
  required void Function(String emoji, bool alreadyReacted) onToggleReaction,
  required VoidCallback onPickFromFull,
}) {
  // 5 emojis × 40 (36 button + 4 margin) + 40 for "+" + 16 padding ≈ 256.
  const pickerWidth = 280.0;
  const pickerHeight = 44.0;
  final screenWidth = MediaQuery.of(context).size.width;

  final left = (tapPosition.dx - pickerWidth / 2).clamp(
    12.0,
    screenWidth - pickerWidth - 12,
  );
  final top = (tapPosition.dy - pickerHeight - 12).clamp(12.0, double.infinity);

  return OverlayEntry(
    builder: (_) => Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: () {
              onDismiss();
              FocusManager.instance.primaryFocus?.unfocus();
            },
            behavior: HitTestBehavior.opaque,
            child: Container(color: Colors.black.withValues(alpha: 0.15)),
          ),
        ),
        Positioned(
          left: left,
          top: top,
          child: TweenAnimationBuilder<double>(
            tween: Tween(begin: 0, end: 1),
            duration: const Duration(milliseconds: 200),
            curve: Curves.easeOutCubic,
            builder: (_, value, child) => Opacity(
              opacity: value,
              child: Transform.translate(
                offset: Offset(0, 8 * (1 - value)),
                child: child,
              ),
            ),
            child: Container(
              height: pickerHeight,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              decoration: BoxDecoration(
                color: context.surface.withValues(alpha: 0.95),
                borderRadius: BorderRadius.circular(22),
                border: Border.all(color: context.border),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ...reactionEmojis.map((emoji) {
                    final alreadyReacted = message.reactions.any(
                      (r) => r.emoji == emoji && r.userId == myUserId,
                    );
                    return GestureDetector(
                      onTap: () {
                        onDismiss();
                        onToggleReaction(emoji, alreadyReacted);
                        FocusManager.instance.primaryFocus?.unfocus();
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        margin: const EdgeInsets.symmetric(horizontal: 2),
                        decoration: BoxDecoration(
                          color: alreadyReacted
                              ? context.accent.withValues(alpha: 0.2)
                              : null,
                          borderRadius: BorderRadius.circular(8),
                          border: alreadyReacted
                              ? Border.all(color: context.accent, width: 2)
                              : null,
                        ),
                        alignment: Alignment.center,
                        child: Text(
                          emoji,
                          style: const TextStyle(
                            fontSize: 22,
                            decoration: TextDecoration.none,
                          ),
                        ),
                      ),
                    );
                  }),
                  // Full emoji picker button
                  GestureDetector(
                    onTap: () {
                      onDismiss();
                      onPickFromFull();
                    },
                    child: Container(
                      width: 36,
                      height: 36,
                      margin: const EdgeInsets.only(left: 4, right: 2),
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: context.border, width: 1),
                      ),
                      alignment: Alignment.center,
                      child: Icon(
                        Icons.add,
                        size: 18,
                        color: context.textSecondary,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ],
    ),
  );
}
