/// Pure mapping from a [MemberTarget] to a [ContextMenuModel].
///
/// v1 scope (locked before PR 4):
///   - Always-on: View Profile, Send Message, Copy User ID, Copy
///     Username.
///   - Contact actions: Add / Remove Contact, Block / Unblock —
///     wired only when the caller knows the local contact state.
///   - Admin-only danger zone: Kick from Group, Ban from Group.
///   - "Change Role" and "Voice Call" hidden — see MemberTarget
///     docs for the rationale.
///
/// Targeting self hides the entire destructive zone so the menu
/// can't be used to kick / ban / block oneself.
library;

import 'package:flutter/material.dart';

import '../echo_context_menu.dart';

ContextMenuModel buildMemberMenu(MemberTarget t) {
  return ContextMenuModel(
    sections: [
      _primarySection(t),
      if (_hasContactSection(t)) _contactSection(t),
      if (_hasAdminSection(t)) _adminSection(t),
      if (t.onCopyUserId != null || t.onCopyUsername != null) _footerSection(t),
    ].whereType<ContextMenuSection>().toList(),
  );
}

ContextMenuSection _primarySection(MemberTarget t) {
  return ContextMenuSection(
    actions: [
      if (t.onViewProfile != null)
        ContextMenuAction(
          label: 'View Profile',
          icon: Icons.person_outline,
          onTap: t.onViewProfile,
        ),
      if (t.onSendMessage != null && !t.isSelf)
        ContextMenuAction(
          label: 'Send Message',
          icon: Icons.mail_outline,
          onTap: t.onSendMessage,
        ),
    ],
  );
}

bool _hasContactSection(MemberTarget t) {
  if (t.isSelf) return false;
  return t.onAddContact != null ||
      t.onRemoveContact != null ||
      t.onBlock != null ||
      t.onUnblock != null;
}

ContextMenuSection _contactSection(MemberTarget t) {
  return ContextMenuSection(
    actions: [
      if (t.onAddContact != null)
        ContextMenuAction(
          label: 'Add Contact',
          icon: Icons.person_add_alt_1_outlined,
          onTap: t.onAddContact,
        ),
      if (t.onRemoveContact != null)
        ContextMenuAction(
          label: 'Remove Contact',
          icon: Icons.person_remove_outlined,
          onTap: t.onRemoveContact,
        ),
      if (t.onBlock != null)
        ContextMenuAction(
          label: 'Block',
          icon: Icons.block_outlined,
          isDanger: true,
          onTap: t.onBlock,
        ),
      if (t.onUnblock != null)
        ContextMenuAction(
          label: 'Unblock',
          icon: Icons.lock_open_outlined,
          onTap: t.onUnblock,
        ),
    ],
  );
}

bool _hasAdminSection(MemberTarget t) {
  if (t.isSelf || t.targetIsOwner || !t.viewerIsAdminOrOwner) return false;
  return t.onKick != null || t.onBan != null || t.onChangeRole != null;
}

ContextMenuSection _adminSection(MemberTarget t) {
  final changeRoleLabel = t.targetIsAdmin ? 'Remove admin' : 'Make admin';
  return ContextMenuSection(
    actions: [
      if (t.onChangeRole != null)
        ContextMenuAction(
          label: changeRoleLabel,
          icon: t.targetIsAdmin
              ? Icons.manage_accounts_outlined
              : Icons.admin_panel_settings_outlined,
          onTap: t.onChangeRole,
        ),
      if (t.onKick != null)
        ContextMenuAction(
          label: 'Kick from Group',
          icon: Icons.person_remove_outlined,
          isDanger: true,
          onTap: t.onKick,
        ),
      if (t.onBan != null)
        ContextMenuAction(
          label: 'Ban from Group',
          icon: Icons.gavel_outlined,
          isDanger: true,
          onTap: t.onBan,
        ),
    ],
  );
}

ContextMenuSection _footerSection(MemberTarget t) {
  return ContextMenuSection(
    actions: [
      if (t.onCopyUsername != null)
        ContextMenuAction(
          label: 'Copy Username',
          icon: Icons.alternate_email,
          onTap: t.onCopyUsername,
        ),
      if (t.onCopyUserId != null)
        ContextMenuAction(
          label: 'Copy User ID',
          icon: Icons.tag,
          onTap: t.onCopyUserId,
        ),
    ],
  );
}
