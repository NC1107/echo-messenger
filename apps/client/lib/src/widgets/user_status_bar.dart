import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'conversation_item.dart' show presenceStatusDotColor;

/// Human-readable label for a presence status identifier.
String presenceStatusLabel(String status) {
  return switch (status) {
    'online' => 'Online',
    'away' => 'Away',
    'dnd' => 'Do Not Disturb',
    'invisible' => 'Invisible',
    _ => 'Online',
  };
}

/// Ordered list of selectable statuses for the quick picker.
const List<String> _kStatusOptions = ['online', 'away', 'dnd', 'invisible'];

class UserStatusBar extends ConsumerWidget {
  const UserStatusBar({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final username = authState.username ?? 'User';
    final initial = username.isNotEmpty ? username[0].toUpperCase() : '?';
    final status = authState.presenceStatus;
    final dotColor = presenceStatusDotColor(context, status, true);

    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: PopupMenuButton<String>(
              tooltip: 'Change status',
              position: PopupMenuPosition.over,
              color: context.surface,
              onSelected: (selected) async {
                await ref
                    .read(authProvider.notifier)
                    .setPresenceStatus(selected);
                if (context.mounted) {
                  ToastService.show(
                    context,
                    'Status set to ${presenceStatusLabel(selected)}',
                    type: ToastType.success,
                  );
                }
              },
              itemBuilder: (ctx) => _kStatusOptions
                  .map(
                    (s) => PopupMenuItem<String>(
                      value: s,
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: presenceStatusDotColor(ctx, s, true),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Text(
                            presenceStatusLabel(s),
                            style: TextStyle(color: ctx.textPrimary),
                          ),
                        ],
                      ),
                    ),
                  )
                  .toList(),
              child: Row(
                children: [
                  // Avatar with status indicator dot
                  Stack(
                    children: [
                      CircleAvatar(
                        radius: 16,
                        backgroundColor: context.accent,
                        child: Text(
                          initial,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Positioned(
                        bottom: 0,
                        right: 0,
                        child: Container(
                          width: 10,
                          height: 10,
                          decoration: BoxDecoration(
                            color: dotColor,
                            shape: BoxShape.circle,
                            border: Border.all(color: context.mainBg, width: 2),
                          ),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 10),
                  // Username and status
                  Expanded(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          username,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(
                          presenceStatusLabel(status),
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 11,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Settings gear
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 18),
            color: context.textSecondary,
            tooltip: 'Settings',
            onPressed: () {},
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          ),
        ],
      ),
    );
  }
}
