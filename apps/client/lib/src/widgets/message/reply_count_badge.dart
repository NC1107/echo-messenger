import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/chat_message.dart';
import '../../providers/threads_inbox_provider.dart';
import '../../theme/echo_theme.dart';

/// Tappable "X replies" pill shown beneath a message that has at least
/// one threaded reply.  Aligns to the bubble's own side (right for
/// "my" messages in bubbles layout, left otherwise).  Tapping fires
/// [onTap] -- typically opens the thread view.
///
/// Unread state comes from the threads inbox provider (M3): when the
/// most recent inbox snapshot has a matching entry with unreadCount > 0,
/// the badge renders an accent dot inline. Caller can still hard-force
/// the state via the [hasUnread] override prop for tests.
class ReplyCountBadge extends ConsumerWidget {
  final ChatMessage message;
  final bool isMine;
  final ValueChanged<ChatMessage>? onTap;

  /// When true, render as a subtle inline accent-coloured "N replies" link
  /// (no rounded pill). Used by the plain (Slack-style) layout where the
  /// chrome of a pill clashes with the surrounding text-only treatment.
  final bool inlineStyle;

  /// Forces the unread dot on regardless of inbox state. Default is to
  /// derive from the threads-inbox provider snapshot. Tests + the
  /// thread panel (where the parent is always "read") can override.
  final bool? hasUnread;

  const ReplyCountBadge({
    super.key,
    required this.message,
    required this.isMine,
    this.onTap,
    this.inlineStyle = false,
    this.hasUnread,
  });

  Widget _unreadDot(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Container(
        width: 6,
        height: 6,
        decoration: BoxDecoration(
          color: context.accent,
          shape: BoxShape.circle,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final count = message.replyCount;
    final label = count == 1 ? '1 reply' : '$count replies';
    final unread = hasUnread ?? _isUnreadFromInbox(ref);
    return inlineStyle
        ? _buildInline(context, label, unread)
        : _buildPill(context, label, unread);
  }

  /// True when the threads-inbox snapshot has a matching entry with
  /// unreadCount > 0. Falls back to false when the inbox hasn't been
  /// loaded yet (so we never falsely advertise unread state).
  bool _isUnreadFromInbox(WidgetRef ref) {
    final inbox = ref.watch(threadsInboxProvider);
    for (final entry in inbox.entries) {
      if (entry.threadRootId == message.id) {
        return entry.unreadCount > 0;
      }
    }
    return false;
  }

  EdgeInsets _topPadding(double topInset) =>
      EdgeInsets.only(top: topInset, left: isMine ? 0 : 36);

  Alignment get _alignment =>
      isMine ? Alignment.centerRight : Alignment.centerLeft;

  VoidCallback? get _onTapCallback =>
      onTap == null ? null : () => onTap!(message);

  Widget _buildInline(BuildContext context, String label, bool unread) {
    return Padding(
      padding: _topPadding(2),
      child: Align(
        alignment: _alignment,
        child: Semantics(
          label: unread ? 'View $label (new replies)' : 'View $label',
          button: true,
          child: InkWell(
            borderRadius: BorderRadius.circular(2),
            onTap: _onTapCallback,
            child: _buildInlineRow(context, label, unread),
          ),
        ),
      ),
    );
  }

  Widget _buildInlineRow(BuildContext context, String label, bool unread) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          label,
          style: GoogleFonts.inter(
            fontSize: 12,
            color: context.accent,
            fontWeight: FontWeight.w500,
            decoration: TextDecoration.underline,
            decorationColor: context.accent.withValues(alpha: 0.4),
          ),
        ),
        if (unread) _unreadDot(context),
      ],
    );
  }

  Widget _buildPill(BuildContext context, String label, bool unread) {
    return Padding(
      padding: _topPadding(4),
      child: Align(
        alignment: _alignment,
        child: Semantics(
          label: 'View $label',
          button: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: _onTapCallback,
              child: _buildPillContainer(context, label, unread),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildPillContainer(BuildContext context, String label, bool unread) {
    final repliers = message.recentReplierUsernames;
    final lastReplyAt = message.lastReplyAt;
    final hasFaces = repliers.isNotEmpty;

    return Container(
      padding: EdgeInsets.fromLTRB(hasFaces ? 4 : 8, 4, 8, 4),
      decoration: BoxDecoration(
        color: context.accent.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(14),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (hasFaces)
            _FaceStack(usernames: repliers)
          else
            Icon(Icons.forum_outlined, size: 12, color: context.accent),
          const SizedBox(width: 6),
          Text(
            label,
            style: GoogleFonts.inter(
              fontSize: 12,
              color: context.accent,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (lastReplyAt != null) ...[
            const SizedBox(width: 6),
            Text(
              _formatAgo(lastReplyAt),
              style: GoogleFonts.inter(fontSize: 11, color: context.textMuted),
            ),
          ],
          if (unread) _unreadDot(context),
        ],
      ),
    );
  }

  static String _formatAgo(DateTime when) {
    final delta = DateTime.now().toUtc().difference(when.toUtc());
    if (delta.inSeconds < 60) return 'just now';
    if (delta.inMinutes < 60) return '${delta.inMinutes}m ago';
    if (delta.inHours < 24) return '${delta.inHours}h ago';
    if (delta.inDays < 7) return '${delta.inDays}d ago';
    return '${(delta.inDays / 7).floor()}w ago';
  }
}

/// Up to 3 overlapping circular initials of the most-recent repliers.
/// Used as the leading affordance of the thread chip when reply
/// metadata is available — falls back to the forum icon otherwise.
class _FaceStack extends StatelessWidget {
  const _FaceStack({required this.usernames});

  final List<String> usernames;

  @override
  Widget build(BuildContext context) {
    final faces = usernames.take(3).toList();
    const faceSize = 18.0;
    const overlap = 6.0;
    final width = faceSize + (faces.length - 1) * (faceSize - overlap);
    return SizedBox(
      width: width,
      height: faceSize,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          for (int i = 0; i < faces.length; i++)
            Positioned(
              left: i * (faceSize - overlap),
              child: _FaceCircle(name: faces[i], size: faceSize),
            ),
        ],
      ),
    );
  }
}

class _FaceCircle extends StatelessWidget {
  const _FaceCircle({required this.name, required this.size});
  final String name;
  final double size;

  @override
  Widget build(BuildContext context) {
    final initial = name.isNotEmpty ? name[0].toUpperCase() : '?';
    final hue = (name.hashCode % 360).abs().toDouble();
    final bg = HSLColor.fromAHSL(1.0, hue, 0.55, 0.45).toColor();
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(
        color: bg,
        shape: BoxShape.circle,
        border: Border.all(color: context.surface, width: 1.5),
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: Colors.white,
          fontSize: size * 0.55,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
