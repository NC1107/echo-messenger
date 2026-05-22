/// Pure mapping from a [MessageTarget] to a [ContextMenuModel].
///
/// Living in its own file (no widget imports) keeps it trivial to
/// unit-test action visibility under different role / state combos
/// without spinning up a full Flutter test harness.
///
/// v1 scope (per the cross-cutting decisions agreed before PR 2):
///   - Encrypted-unreadable messages → no inline reactions row.
///   - "Create Thread", "Report", "Mark Unread", "Copy Link" are
///     deferred (server endpoints don't exist yet).
///   - Copy Message ID always visible in the footer section.
///   - Owner-only / mine-only / media-only rows hide entirely when
///     they don't apply, rather than rendering disabled.
library;

import 'package:flutter/material.dart';

import '../echo_context_menu.dart';

ContextMenuModel buildMessageMenu(MessageTarget t) {
  return ContextMenuModel(
    header: _buildHeader(t),
    sections: [
      _primarySection(t),
      _utilitySection(t),
      if (_hasDanger(t)) _dangerSection(t),
      if (t.onCopyId != null) _footerSection(t),
    ].whereType<ContextMenuSection>().toList(),
  );
}

ContextMenuHeader? _buildHeader(MessageTarget t) {
  if (t.isEncryptedUnreadable) return null;
  if (t.onPickReaction == null || t.onOpenFullPicker == null) return null;
  return InlineReactionsHeader(
    emojis: t.recentReactions,
    onPick: t.onPickReaction!,
    onOpenFullPicker: t.onOpenFullPicker!,
  );
}

ContextMenuSection _primarySection(MessageTarget t) {
  final actions = <ContextMenuAction>[
    if (t.onRetry != null)
      ContextMenuAction(label: 'Retry', icon: Icons.refresh, onTap: t.onRetry),
    if (t.onReply != null)
      ContextMenuAction(
        label: 'Reply',
        icon: Icons.reply_outlined,
        onTap: t.onReply,
      ),
    if (t.onForward != null)
      ContextMenuAction(
        label: 'Forward',
        icon: Icons.forward_outlined,
        onTap: t.onForward,
      ),
    // Discoverable "Add reaction" entry for right-click. The four-emoji
    // inline header is fast for power users but isn't labeled, so casual
    // users miss it entirely (validated on prod). Keeping the inline
    // header *and* this row gives both audiences a path:
    //   - inline header: one-click pick of the four most-recent emojis
    //   - this row:      jumps straight into the full picker
    // Hidden when the message is encrypted-unreadable (no reactions on
    // a "[Could not decrypt…]" bubble) or when the parent didn't wire
    // a reactions callback.
    if (!t.isEncryptedUnreadable && t.onOpenFullPicker != null)
      ContextMenuAction(
        label: 'Add reaction',
        icon: Icons.add_reaction_outlined,
        onTap: t.onOpenFullPicker,
      ),
  ];
  return ContextMenuSection(actions: actions);
}

ContextMenuSection _utilitySection(MessageTarget t) {
  // Pin/unpin and save/unsave are mutually exclusive — only one
  // variant is wired at any moment, so we just expose whichever
  // callback the caller provided.
  final pinRow = _pinRow(t);
  final saveRow = _saveRow(t);

  return ContextMenuSection(
    actions: [
      if (t.onCopyText != null)
        ContextMenuAction(
          label: t.mediaUrl != null ? 'Copy link' : 'Copy text',
          icon: Icons.copy_outlined,
          onTap: t.onCopyText,
        ),
      if (t.onViewGallery != null && t.isImageMedia)
        ContextMenuAction(
          label: 'View in Gallery',
          icon: Icons.image_outlined,
          onTap: t.onViewGallery,
        ),
      ?pinRow,
      ?saveRow,
      if (t.isMine && t.onEdit != null)
        ContextMenuAction(
          label: 'Edit',
          icon: Icons.edit_outlined,
          onTap: t.onEdit,
        ),
    ],
  );
}

ContextMenuAction? _pinRow(MessageTarget t) {
  if (t.onPin != null) {
    return ContextMenuAction(
      label: 'Pin Message',
      icon: Icons.push_pin_outlined,
      onTap: t.onPin,
    );
  }
  if (t.onUnpin != null) {
    return ContextMenuAction(
      label: 'Unpin Message',
      icon: Icons.push_pin,
      onTap: t.onUnpin,
    );
  }
  return null;
}

ContextMenuAction? _saveRow(MessageTarget t) {
  if (t.onSave != null && !t.isSaved) {
    return ContextMenuAction(
      label: 'Save',
      icon: Icons.bookmark_border_outlined,
      onTap: t.onSave,
    );
  }
  if (t.onUnsave != null && t.isSaved) {
    return ContextMenuAction(
      label: 'Unsave',
      icon: Icons.bookmark_remove_outlined,
      onTap: t.onUnsave,
    );
  }
  return null;
}

bool _hasDanger(MessageTarget t) => t.onDelete != null;

ContextMenuSection _dangerSection(MessageTarget t) {
  return ContextMenuSection(
    actions: [
      ContextMenuAction(
        label: t.isMine ? 'Delete Message' : 'Delete for Me',
        icon: Icons.delete_outline,
        isDanger: t.isMine,
        onTap: t.onDelete,
      ),
    ],
  );
}

ContextMenuSection _footerSection(MessageTarget t) {
  return ContextMenuSection(
    actions: [
      ContextMenuAction(
        label: 'Copy Message ID',
        icon: Icons.tag,
        onTap: t.onCopyId,
      ),
    ],
  );
}
