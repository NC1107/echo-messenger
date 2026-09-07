import 'package:flutter/widgets.dart';

import '../../models/chat_message.dart';

/// Grouped action + navigation callbacks for a [MessageItem].
///
/// Collapses the ~18 individual `on*` callbacks the message row used to take as
/// separate constructor parameters into one object, so the widget signature
/// stays legible (S107) and adding a new action doesn't widen every call site.
/// All callbacks are optional; a null one simply hides/disables that
/// affordance (e.g. `onEdit: null` removes Edit from the menu).
@immutable
class MessageActions {
  const MessageActions({
    this.onReactionTap,
    this.onReactionSelect,
    this.onMoreReactions,
    this.onDelete,
    this.onEdit,
    this.onReply,
    this.onReplyInThread,
    this.onViewThread,
    this.onAvatarTap,
    this.onPin,
    this.onUnpin,
    this.onRetry,
    this.onSave,
    this.onUnsave,
    this.onForward,
    this.onTapReplyQuote,
    this.onVerifyIdentity,
    this.onImageTap,
  });

  /// Long-press / right-click a reaction chip (carries the tap position).
  final void Function(ChatMessage message, Offset globalPosition)?
  onReactionTap;

  /// Pick one of the quick-react emojis.
  final void Function(ChatMessage message, String emoji)? onReactionSelect;

  /// Open the full emoji picker ("More emojis…").
  final void Function(ChatMessage message)? onMoreReactions;

  final void Function(ChatMessage message)? onDelete;
  final void Function(ChatMessage message)? onEdit;
  final void Function(ChatMessage message)? onReply;

  /// Reply stamped with the thread root (Slack-style "Reply in thread").
  final void Function(ChatMessage message)? onReplyInThread;
  final void Function(ChatMessage message)? onViewThread;

  /// Tap the sender's avatar — opens their profile.
  final void Function(String userId)? onAvatarTap;

  final void Function(ChatMessage message)? onPin;
  final void Function(ChatMessage message)? onUnpin;
  final void Function(ChatMessage message)? onRetry;
  final void Function(ChatMessage message)? onSave;
  final void Function(ChatMessage message)? onUnsave;
  final void Function(ChatMessage message)? onForward;

  /// Tap a reply quote — scrolls to the referenced message.
  final void Function(String replyToId)? onTapReplyQuote;

  /// Tap the received-message lock icon to verify the sender's identity.
  /// When null, the lock icon is non-interactive.
  final void Function(ChatMessage message)? onVerifyIdentity;

  /// Tap an image in this message, with the resolved URL — opens the parent's
  /// gallery viewer instead of the single-image dialog.
  final void Function(String resolvedUrl)? onImageTap;
}
