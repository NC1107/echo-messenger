// Empty-state shown when no conversation is selected in the chat panel.
import 'package:flutter/material.dart';
import 'package:go_router/go_router.dart';

import '../../router/routes.dart';
import '../../theme/echo_theme.dart';

class NoConversationPlaceholder extends StatelessWidget {
  const NoConversationPlaceholder({super.key});

  @override
  Widget build(BuildContext context) {
    final gradient = context.chatBgGradient;
    return DecoratedBox(
      decoration: gradient != null
          ? BoxDecoration(gradient: gradient)
          : BoxDecoration(color: context.chatBg),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_rounded,
              size: 56,
              color: context.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: EchoSpacing.xl),
            Text(
              'No conversation selected',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: EchoSpacing.sm),
            Text(
              'Choose a conversation from the sidebar or start a new one',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
            const SizedBox(height: EchoSpacing.xl),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: () => context.push(routeContacts),
                  icon: const Icon(Icons.person_add_outlined, size: 18),
                  label: const Text('Add Contact'),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.accent,
                    foregroundColor: context.onAccent,
                    padding: const EdgeInsets.symmetric(
                      horizontal: EchoSpacing.xl,
                      vertical: EchoSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(EchoRadii.md),
                    ),
                  ),
                ),
                const SizedBox(width: EchoSpacing.md),
                OutlinedButton.icon(
                  onPressed: () => context.push(routeDiscoverGroups),
                  icon: const Icon(Icons.explore_outlined, size: 18),
                  label: const Text('Browse Groups'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: EchoSpacing.xl,
                      vertical: EchoSpacing.md,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(EchoRadii.md),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
