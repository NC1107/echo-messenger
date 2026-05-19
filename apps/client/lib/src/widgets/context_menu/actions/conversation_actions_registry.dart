/// Pure mapping from a [ConversationTarget] to a [ContextMenuModel].
///
/// v1 scope (per the cross-cutting decisions agreed before PR 3):
///   - Mark As Read shows only when there's at least one unread;
///     Mark As Unread shows only when fully read.
///   - "Notification settings" submenu was rejected — encryption
///     activity / safety number / group info all link out to their
///     dedicated screens instead of inlining nested submenus.
///   - Owner-of-a-group-with-other-members can't leave; row is
///     hidden entirely (not disabled), matching the cross-cutting
///     decision.
///   - Copy Conversation ID is always visible in the footer.
library;

import 'package:flutter/material.dart';

import '../echo_context_menu.dart';

ContextMenuModel buildConversationMenu(ConversationTarget t) {
  return ContextMenuModel(
    sections: [
      _readPinMuteSection(t),
      if (_hasNavSection(t)) _navSection(t),
      if (_hasDanger(t)) _dangerSection(t),
      if (t.onCopyId != null) _footerSection(t),
    ].whereType<ContextMenuSection>().toList(),
  );
}

ContextMenuSection _readPinMuteSection(ConversationTarget t) {
  return ContextMenuSection(
    actions: [
      if (t.onMarkAsRead != null && t.hasUnread)
        ContextMenuAction(
          label: 'Mark As Read',
          icon: Icons.mark_chat_read_outlined,
          onTap: t.onMarkAsRead,
        ),
      if (t.onMarkAsUnread != null && !t.hasUnread)
        ContextMenuAction(
          label: 'Mark As Unread',
          icon: Icons.mark_email_unread_outlined,
          onTap: t.onMarkAsUnread,
        ),
      if (t.onToggleMute != null)
        ContextMenuAction(
          label: t.isMuted ? 'Unmute' : 'Mute',
          icon: t.isMuted
              ? Icons.notifications_outlined
              : Icons.notifications_off_outlined,
          onTap: t.onToggleMute,
        ),
      if (t.onTogglePin != null)
        ContextMenuAction(
          label: t.isPinned ? 'Unpin' : 'Pin to Top',
          icon: t.isPinned ? Icons.push_pin : Icons.push_pin_outlined,
          onTap: t.onTogglePin,
        ),
    ],
  );
}

bool _hasNavSection(ConversationTarget t) {
  return t.onOpenInfo != null ||
      t.onInvitePeople != null ||
      t.onOpenEncryptionActivity != null ||
      t.onViewSafetyNumber != null;
}

ContextMenuSection _navSection(ConversationTarget t) {
  return ContextMenuSection(
    actions: [
      if (t.onOpenInfo != null && t.isGroup)
        ContextMenuAction(
          label: 'Group Info',
          icon: Icons.info_outline,
          onTap: t.onOpenInfo,
        ),
      if (t.onInvitePeople != null && t.isGroup)
        ContextMenuAction(
          label: 'Invite People',
          icon: Icons.person_add_outlined,
          onTap: t.onInvitePeople,
        ),
      if (t.onViewSafetyNumber != null && !t.isGroup)
        ContextMenuAction(
          label: 'View Safety Number',
          icon: Icons.shield_outlined,
          onTap: t.onViewSafetyNumber,
        ),
      if (t.onOpenEncryptionActivity != null && t.isGroup && t.isAdminOrOwner)
        ContextMenuAction(
          label: 'Encryption Activity',
          icon: Icons.history,
          onTap: t.onOpenEncryptionActivity,
        ),
    ],
  );
}

bool _hasDanger(ConversationTarget t) =>
    t.onLeave != null || t.onDelete != null;

ContextMenuSection _dangerSection(ConversationTarget t) {
  return ContextMenuSection(
    actions: [
      if (t.onLeave != null)
        ContextMenuAction(
          label: 'Leave Group',
          icon: Icons.exit_to_app,
          isDanger: true,
          onTap: t.onLeave,
        ),
      if (t.onDelete != null)
        ContextMenuAction(
          label: t.isGroup ? 'Delete Group' : 'Delete Conversation',
          icon: Icons.delete_outline,
          isDanger: true,
          onTap: t.onDelete,
        ),
    ],
  );
}

ContextMenuSection _footerSection(ConversationTarget t) {
  return ContextMenuSection(
    actions: [
      ContextMenuAction(
        label: 'Copy Conversation ID',
        icon: Icons.tag,
        onTap: t.onCopyId,
      ),
    ],
  );
}
