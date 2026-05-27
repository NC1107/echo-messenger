/// Centralised right-click / long-press context menu, Discord-style,
/// themed to Echo's design system.
///
/// PR 1 of 4 — foundation only. No existing call sites are migrated;
/// the testbed at `/dev/context-menu` is the only consumer.
///
/// Usage from a call site:
///
/// ```dart
/// GestureDetector(
///   onSecondaryTapDown: (d) => EchoContextMenu.open(
///     context: context,
///     ref: ref,
///     target: MessageTarget(/* ... */),
///     anchor: d.globalPosition,
///   ),
///   onLongPressStart: (d) => EchoContextMenu.open(
///     context: context,
///     ref: ref,
///     target: MessageTarget(/* ... */),
///     anchor: d.globalPosition,
///   ),
///   child: child,
/// );
/// ```
///
/// The [open] entry point picks the desktop overlay or the mobile
/// bottom-sheet layout based on viewport short side, both rendered from
/// the same [ContextMenuModel] tree so action wiring lives in one place.
library;

import 'package:flutter/material.dart';

import 'context_menu_overlay.dart';
import 'context_menu_sheet.dart';

/// One row inside a context menu. The icon renders right-aligned to
/// match the Discord screenshot the design is anchored to.
///
/// `submenu` is mutually exclusive with `onTap` — a row either fires
/// an action or slides the overlay into a nested section stack. The
/// overlay enforces this at draw time by hiding the chevron when
/// `onTap` is non-null.
class ContextMenuAction {
  const ContextMenuAction({
    required this.label,
    required this.icon,
    this.onTap,
    this.submenu,
    this.isDanger = false,
    this.shortcut,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onTap;

  /// When non-null, tapping this row replaces the visible menu with
  /// `submenu` (rendered as a "Back ← Title" header + nested sections).
  /// Used for "Add Reaction →" full picker and "Apps →" entry points.
  final List<ContextMenuSection>? submenu;

  /// Tints label + icon with [EchoTheme.danger]. Apply to destructive
  /// rows (Delete, Kick, Ban, Report).
  final bool isDanger;

  /// Optional keyboard hint shown as muted mono text right of the
  /// label (e.g. `⌘C`). Purely decorative in PR 1 — actual keyboard
  /// dispatch is deferred to a follow-up.
  final String? shortcut;
}

/// A divider-separated group of rows. The overlay paints a 1px
/// `context.border` line between consecutive sections and skips it
/// for the first section.
class ContextMenuSection {
  const ContextMenuSection({required this.actions});
  final List<ContextMenuAction> actions;
}

/// Optional header rendered above all sections. PR 1 ships only the
/// "inline reactions row" variant (the four-emoji strip in the
/// Discord screenshot); future variants (message preview, member
/// avatar header) plug in here without touching the layout widgets.
sealed class ContextMenuHeader {
  const ContextMenuHeader();
}

/// Four-emoji recent-reactions strip + "Add Reaction →" chevron.
/// The emojis come from the bundled NotoColorEmoji set; in PR 2 we
/// pull them from `emoji_picker_flutter`'s recent-tab storage so the
/// list reflects the user's actual usage instead of a static curation.
class InlineReactionsHeader extends ContextMenuHeader {
  const InlineReactionsHeader({
    required this.emojis,
    required this.onPick,
    required this.onOpenFullPicker,
  });

  final List<String> emojis;
  final void Function(String emoji) onPick;
  final VoidCallback onOpenFullPicker;
}

/// Per-participant volume slider header used by the voice-lounge member
/// context menu. Shows the participant's display name, current percent,
/// and a draggable 0–200% slider. `onChanged` fires on drag (cheap UI
/// update); `onChangeEnd` commits the value to the WebRTC track.
class VolumeSliderHeader extends ContextMenuHeader {
  const VolumeSliderHeader({
    required this.title,
    required this.initialValue,
    required this.onChanged,
    required this.onChangeEnd,
    this.enabled = true,
    this.disabledTooltip,
  });

  /// Display name shown above the slider.
  final String title;

  /// Initial value in [0.0, 2.0] — 1.0 is 100% (system default).
  final double initialValue;

  /// Called continuously while dragging. Visual-only.
  final ValueChanged<double> onChanged;

  /// Called once when the user releases the thumb. Commit point.
  final ValueChanged<double> onChangeEnd;

  /// When false the slider greys out and shows [disabledTooltip].
  final bool enabled;
  final String? disabledTooltip;
}

/// Resolved menu tree for one target. Built from a target by the
/// per-target registries (see `actions/*_actions_registry.dart`,
/// added in PRs 2-4).
class ContextMenuModel {
  const ContextMenuModel({this.header, required this.sections, this.title});

  /// Optional Discord-style header (inline reactions, etc.).
  final ContextMenuHeader? header;

  /// Action sections, painted top-to-bottom with dividers between.
  final List<ContextMenuSection> sections;

  /// Optional short title shown above the sections — used by submenus
  /// for the "← Back" affordance ("Add Reaction"). Null on the root
  /// menu (the inline-reactions header acts as the implicit title).
  final String? title;
}

/// Tagged target classes. Each PR 2-4 introduces one concrete target
/// + its registry. They are sealed here so the registry switch is
/// exhaustive at compile time.
sealed class ContextMenuTarget {
  const ContextMenuTarget();

  /// Short, stable identifier used for telemetry and debug logging.
  String get analyticsName;
}

/// Placeholder target type for the PR-1 testbed. PRs 2-4 add
/// MessageTarget / ConversationTarget / MemberTarget alongside this
/// and migrate real call sites.
class DebugTarget extends ContextMenuTarget {
  const DebugTarget(this.label);
  final String label;
  @override
  String get analyticsName => 'debug:$label';
}

/// Message context menu (PR 2). Carries the message itself plus the
/// per-callsite callbacks `MessageItem` already wires up — by holding
/// references to the existing handlers we keep state-management in
/// `chat_provider` and only swap the *surface*, not the action
/// logic. Callbacks left null cause their corresponding row to be
/// hidden by the registry.
///
/// `isEncryptedUnreadable` short-circuits the inline reactions row
/// in encrypted groups where the local client can't decrypt the
/// message — there's no point picking a reaction on a bubble that
/// reads "[Could not decrypt…]".
class MessageTarget extends ContextMenuTarget {
  const MessageTarget({
    required this.message,
    required this.isMine,
    required this.isSaved,
    required this.isEncryptedUnreadable,
    required this.mediaUrl,
    required this.isImageMedia,
    this.onReply,
    this.onReplyInThread,
    this.onForward,
    this.onRetry,
    this.onCopyText,
    this.onPin,
    this.onUnpin,
    this.onSave,
    this.onUnsave,
    this.onEdit,
    this.onViewGallery,
    this.onDelete,
    this.onCopyId,
    this.onPickReaction,
    this.onOpenFullPicker,
    this.recentReactions = const ['👍', '❤️', '😂', '🎉'],
  });

  final dynamic message; // ChatMessage — kept dynamic here to avoid
  // a cyclic import with chat_provider's model file.
  final bool isMine;
  final bool isSaved;
  final bool isEncryptedUnreadable;
  final String? mediaUrl;
  final bool isImageMedia;

  // Action handlers — null = row hidden.
  final VoidCallback? onReply;

  /// Distinct from [onReply]: anchors the new reply to the thread root
  /// so it filters out of the main timeline (Slack-style). null = row
  /// hidden (e.g. failed-message bubbles).
  final VoidCallback? onReplyInThread;
  final VoidCallback? onForward;
  final VoidCallback? onRetry;
  final VoidCallback? onCopyText;
  final VoidCallback? onPin;
  final VoidCallback? onUnpin;
  final VoidCallback? onSave;
  final VoidCallback? onUnsave;
  final VoidCallback? onEdit;
  final VoidCallback? onViewGallery;
  final VoidCallback? onDelete;
  final VoidCallback? onCopyId;

  // Null disables header even when !isEncryptedUnreadable (e.g. forwarded bubbles reject reactions).
  final void Function(String emoji)? onPickReaction;
  final VoidCallback? onOpenFullPicker;
  final List<String> recentReactions;

  @override
  String get analyticsName => 'message';
}

/// Conversation context menu (PR 3). The registry switches action
/// visibility on the conversation kind (`isGroup`), the user's role
/// inside it (admin / owner / member), and current pin / mute /
/// unread state. The caller wires whichever callbacks it can support
/// — nulls are pruned from the rendered tree.
///
/// Owner-of-a-group-with-other-members is *not* allowed to leave
/// (server enforces this). The decision in PR-1 prep was to hide
/// the row entirely rather than render it disabled.
class ConversationTarget extends ContextMenuTarget {
  const ConversationTarget({
    required this.conversationId,
    required this.isGroup,
    required this.isPinned,
    required this.isMuted,
    required this.hasUnread,
    required this.isAdminOrOwner,
    this.onMarkAsRead,
    this.onMarkAsUnread,
    this.onToggleMute,
    this.onTogglePin,
    this.onOpenInfo,
    this.onInvitePeople,
    this.onOpenEncryptionActivity,
    this.onViewSafetyNumber,
    this.onCopyId,
    this.onLeave,
    this.onDelete,
  });

  final String conversationId;
  final bool isGroup;
  final bool isPinned;
  final bool isMuted;
  final bool hasUnread;
  final bool isAdminOrOwner;

  // Action handlers — null = row hidden.
  final VoidCallback? onMarkAsRead;
  final VoidCallback? onMarkAsUnread;
  final VoidCallback? onToggleMute;
  final VoidCallback? onTogglePin;
  final VoidCallback? onOpenInfo;
  final VoidCallback? onInvitePeople;
  final VoidCallback? onOpenEncryptionActivity;
  final VoidCallback? onViewSafetyNumber;
  final VoidCallback? onCopyId;
  final VoidCallback? onLeave; // group member
  final VoidCallback? onDelete; // DM delete OR group owner delete

  @override
  String get analyticsName => isGroup ? 'group' : 'dm';
}

/// Member context menu (PR 4). Used inside a group's member roster
/// — typically by right-click or long-press on a member row, plus
/// the discoverable "..." button next to each row. Carries enough
/// state to gate admin actions (kick / ban) without re-fetching the
/// group's role table.
///
/// "Change Role" and "Voice Call" are intentionally absent — the
/// server endpoint for the former doesn't exist yet, and the 1:1
/// ring/start flow for the latter has only the active-call surface.
/// Both are tracked as v1.5.
class MemberTarget extends ContextMenuTarget {
  const MemberTarget({
    required this.userId,
    required this.username,
    required this.isSelf,
    required this.targetIsOwner,
    required this.viewerIsAdminOrOwner,
    this.onViewProfile,
    this.onSendMessage,
    this.onAddContact,
    this.onRemoveContact,
    this.onBlock,
    this.onUnblock,
    this.onCopyUserId,
    this.onCopyUsername,
    this.onKick,
    this.onBan,
  });

  final String userId;
  final String username;

  /// True when the target is the current user. Hides destructive
  /// rows so the menu can't be used to kick / ban / block oneself.
  final bool isSelf;

  /// True when the target's role is `owner`. Even an admin viewer
  /// can't kick or ban the owner; the rows hide.
  final bool targetIsOwner;

  /// True when the *viewer* is admin or owner. Gates the admin-only
  /// section (kick / ban).
  final bool viewerIsAdminOrOwner;

  final VoidCallback? onViewProfile;
  final VoidCallback? onSendMessage;
  final VoidCallback? onAddContact;
  final VoidCallback? onRemoveContact;
  final VoidCallback? onBlock;
  final VoidCallback? onUnblock;
  final VoidCallback? onCopyUserId;
  final VoidCallback? onCopyUsername;
  final VoidCallback? onKick;
  final VoidCallback? onBan;

  @override
  String get analyticsName => 'member';
}

/// Single public entry point. Picks desktop overlay vs mobile bottom
/// sheet based on viewport short side; the breakpoint matches the
/// rest of the app (see chat_panel responsive logic).
class EchoContextMenu {
  EchoContextMenu._();

  /// Mobile threshold in logical pixels. Below this we render the
  /// bottom-sheet variant; at or above we render the anchored
  /// overlay. Matches the existing app-wide tablet breakpoint.
  static const double _mobileBreakpoint = 600;

  static Future<void> open({
    required BuildContext context,
    required ContextMenuTarget target,
    required Offset anchor,
    required ContextMenuModel model,
  }) {
    final shortest = MediaQuery.sizeOf(context).shortestSide;
    if (shortest < _mobileBreakpoint) {
      return showContextMenuSheet(context: context, model: model);
    }
    return showContextMenuOverlay(
      context: context,
      anchor: anchor,
      model: model,
    );
  }
}
