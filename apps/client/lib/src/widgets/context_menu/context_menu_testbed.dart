/// Visual testbed for the centralised context menu. Reachable only
/// via the `/dev/context-menu` route in debug builds (the router
/// strips the route in release). Three demo targets are anchored on
/// the page — right-click (desktop) or long-press (mobile) to open
/// the menu. No real call sites use this code path yet; that lands
/// in the per-target migration PRs.
library;

import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import 'echo_context_menu.dart';

/// Toast label used by every "Copy *ID" demo action in the testbed.
const String _kCopyIdToast = 'Copy ID';

class ContextMenuTestbed extends ConsumerWidget {
  const ContextMenuTestbed({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    assert(kDebugMode, 'ContextMenuTestbed must not ship in release builds');

    return Scaffold(
      backgroundColor: context.mainBg,
      appBar: AppBar(
        title: const Text('Context menu testbed'),
        backgroundColor: context.sidebarBg,
        foregroundColor: context.textPrimary,
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 520),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  'Right-click (desktop) or long-press (mobile) each card.',
                  style: TextStyle(fontSize: 13, color: context.textSecondary),
                ),
                const SizedBox(height: 24),
                _DemoCard(
                  label: 'Message',
                  preview: 'hey, are you free at 3?',
                  buildModel: () => _demoMessageModel(context),
                ),
                const SizedBox(height: 16),
                _DemoCard(
                  label: 'Conversation',
                  preview: '# general',
                  buildModel: () => _demoConversationModel(context),
                ),
                const SizedBox(height: 16),
                _DemoCard(
                  label: 'Member',
                  preview: '@npc',
                  buildModel: () => _demoMemberModel(context),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _DemoCard extends ConsumerWidget {
  const _DemoCard({
    required this.label,
    required this.preview,
    required this.buildModel,
  });

  final String label;
  final String preview;
  final ContextMenuModel Function() buildModel;

  void _open(BuildContext context, Offset anchor) {
    EchoContextMenu.open(
      context: context,
      target: DebugTarget(label),
      anchor: anchor,
      model: buildModel(),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    return GestureDetector(
      onSecondaryTapDown: (d) => _open(context, d.globalPosition),
      onLongPressStart: (d) => _open(context, d.globalPosition),
      behavior: HitTestBehavior.opaque,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.border),
        ),
        child: Row(
          children: [
            Container(
              width: 56,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: context.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
              ),
              alignment: Alignment.center,
              child: Text(
                label.toLowerCase(),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w600,
                  color: context.accent,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Text(
                preview,
                style: TextStyle(fontSize: 14, color: context.textPrimary),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Demo model for the Message target. Mirrors the action set from the
/// Discord screenshot the design is anchored to so the testbed
/// surfaces the real layout choices (inline reactions, primary,
/// secondary, danger zone, footer).
ContextMenuModel _demoMessageModel(BuildContext context) {
  return ContextMenuModel(
    header: InlineReactionsHeader(
      emojis: const ['👍', '❤️', '😂', '🎉'],
      onPick: (e) => _toast(context, 'Pick reaction: $e'),
      onOpenFullPicker: () => _toast(context, 'Open full picker'),
    ),
    sections: [
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Reply',
            icon: Icons.reply,
            onTap: () => _toast(context, 'Reply'),
          ),
          ContextMenuAction(
            label: 'Forward',
            icon: Icons.shortcut,
            onTap: () => _toast(context, 'Forward'),
          ),
          ContextMenuAction(
            label: 'Create Thread',
            icon: Icons.forum_outlined,
            onTap: () => _toast(context, 'Create thread'),
          ),
        ],
      ),
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Copy Text',
            icon: Icons.copy,
            shortcut: '⌘C',
            onTap: () => _toast(context, 'Copy text'),
          ),
          ContextMenuAction(
            label: 'Pin Message',
            icon: Icons.push_pin_outlined,
            onTap: () => _toast(context, 'Pin'),
          ),
          ContextMenuAction(
            label: 'Mark Unread',
            icon: Icons.mark_email_unread_outlined,
            onTap: () => _toast(context, 'Mark unread'),
          ),
          ContextMenuAction(
            label: 'Copy Message Link',
            icon: Icons.link,
            onTap: () => _toast(context, 'Copy link'),
          ),
        ],
      ),
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Delete Message',
            icon: Icons.delete_outline,
            isDanger: true,
            onTap: () => _toast(context, 'Delete'),
          ),
          ContextMenuAction(
            label: 'Report Message',
            icon: Icons.flag_outlined,
            isDanger: true,
            onTap: () => _toast(context, 'Report'),
          ),
        ],
      ),
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Copy Message ID',
            icon: Icons.tag,
            onTap: () => _toast(context, _kCopyIdToast),
          ),
        ],
      ),
    ],
  );
}

ContextMenuModel _demoConversationModel(BuildContext context) {
  return ContextMenuModel(
    sections: [
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Mark As Read',
            icon: Icons.mark_chat_read_outlined,
            onTap: () => _toast(context, 'Mark as read'),
          ),
          ContextMenuAction(
            label: 'Mute',
            icon: Icons.notifications_off_outlined,
            onTap: () => _toast(context, 'Mute'),
          ),
          ContextMenuAction(
            label: 'Pin Conversation',
            icon: Icons.push_pin_outlined,
            onTap: () => _toast(context, 'Pin'),
          ),
        ],
      ),
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Invite People',
            icon: Icons.person_add_outlined,
            onTap: () => _toast(context, 'Invite'),
          ),
          ContextMenuAction(
            label: 'Copy Channel ID',
            icon: Icons.tag,
            onTap: () => _toast(context, _kCopyIdToast),
          ),
        ],
      ),
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Leave Group',
            icon: Icons.logout,
            isDanger: true,
            onTap: () => _toast(context, 'Leave'),
          ),
        ],
      ),
    ],
  );
}

ContextMenuModel _demoMemberModel(BuildContext context) {
  return ContextMenuModel(
    sections: [
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'View Profile',
            icon: Icons.person_outline,
            onTap: () => _toast(context, 'View profile'),
          ),
          ContextMenuAction(
            label: 'Send Message',
            icon: Icons.mail_outline,
            onTap: () => _toast(context, 'Send message'),
          ),
          ContextMenuAction(
            label: 'Voice Call',
            icon: Icons.call_outlined,
            onTap: () => _toast(context, 'Call'),
          ),
        ],
      ),
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Change Role',
            icon: Icons.admin_panel_settings_outlined,
            submenu: [
              ContextMenuSection(
                actions: [
                  ContextMenuAction(
                    label: 'Owner',
                    icon: Icons.star_outline,
                    onTap: () => _toast(context, 'Role: owner'),
                  ),
                  ContextMenuAction(
                    label: 'Admin',
                    icon: Icons.shield_outlined,
                    onTap: () => _toast(context, 'Role: admin'),
                  ),
                  ContextMenuAction(
                    label: 'Member',
                    icon: Icons.person_outline,
                    onTap: () => _toast(context, 'Role: member'),
                  ),
                ],
              ),
            ],
          ),
          ContextMenuAction(
            label: 'Copy User ID',
            icon: Icons.tag,
            onTap: () => _toast(context, _kCopyIdToast),
          ),
        ],
      ),
      ContextMenuSection(
        actions: [
          ContextMenuAction(
            label: 'Kick',
            icon: Icons.person_remove_outlined,
            isDanger: true,
            onTap: () => _toast(context, 'Kick'),
          ),
          ContextMenuAction(
            label: 'Ban',
            icon: Icons.block,
            isDanger: true,
            onTap: () => _toast(context, 'Ban'),
          ),
        ],
      ),
    ],
  );
}

void _toast(BuildContext context, String msg) {
  if (!context.mounted) return;
  ToastService.show(
    context,
    msg,
    type: ToastType.info,
    duration: const Duration(seconds: 1),
  );
}
