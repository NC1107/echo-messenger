import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import 'media_content.dart';

/// Displays a reply-to quote block with a colored left border, username, and
/// truncated content. When the original message was a media attachment, renders
/// a small thumbnail (image/GIF) or an icon + label (video, audio, file)
/// instead of the raw URL.
class ReplyQuote extends StatelessWidget {
  final String? replyToUsername;
  final String replyToContent;
  final bool isMine;
  final VoidCallback? onTap;

  const ReplyQuote({
    super.key,
    required this.replyToUsername,
    required this.replyToContent,
    required this.isMine,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final kind = replyAttachmentKind(replyToContent);
    final truncated = replyToContent.length > 100
        ? '${replyToContent.substring(0, 100)}...'
        : replyToContent;
    final semanticsLabel = _buildSemanticsLabel(kind, truncated);
    final (mineOverlay, mineBorder, mineFg) = _buildColorOverlays(context);

    return Semantics(
      label: semanticsLabel,
      child: MouseRegion(
        cursor: onTap != null ? SystemMouseCursors.click : MouseCursor.defer,
        child: GestureDetector(
          onTap: onTap,
          child: Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
            decoration: BoxDecoration(
              color: isMine
                  ? mineOverlay
                  : context.accent.withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border(
                left: BorderSide(
                  color: isMine ? mineBorder : context.accent,
                  width: 3,
                ),
              ),
            ),
            child: Column(
              crossAxisAlignment: isMine
                  ? CrossAxisAlignment.end
                  : CrossAxisAlignment.start,
              children: [
                Text(
                  replyToUsername ?? 'Unknown',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    color: isMine ? mineFg : context.accent,
                  ),
                ),
                const SizedBox(height: 2),
                _buildContentPreview(context, kind),
              ],
            ),
          ),
        ),
      ),
    );
  }

  String _buildSemanticsLabel(ReplyAttachmentKind kind, String truncated) {
    final username = replyToUsername ?? "Unknown";
    if (onTap != null) {
      return 'Jump to original message from $username';
    }
    return switch (kind) {
      ReplyAttachmentKind.image => 'In reply to $username: Image attachment',
      ReplyAttachmentKind.gif => 'In reply to $username: Image attachment',
      ReplyAttachmentKind.video => 'In reply to $username: Video attachment',
      ReplyAttachmentKind.audio => 'In reply to $username: Voice message',
      ReplyAttachmentKind.file => 'In reply to $username: File attachment',
      ReplyAttachmentKind.none => 'In reply to $username: $truncated',
    };
  }

  (Color, Color, Color) _buildColorOverlays(BuildContext context) {
    final mineFg = context.onSentBubble;
    // Base the overlay/border alpha on whether the sent-bubble BACKGROUND is
    // dark (not the foreground). This keeps Ember (amber bubble, high
    // luminance) from using higher-alpha overlays designed for dark bubbles
    // and ensures the reply quote tint is readable on all themes (#ember-reply).
    final bubbleBgIsDark = context.sentBubble.computeLuminance() < 0.3;
    final tint = context.sentBubbleTint;
    final mineOverlay = bubbleBgIsDark
        ? tint.withValues(alpha: 0.18)
        : tint.withValues(alpha: 0.12);
    final mineBorder = bubbleBgIsDark
        ? tint.withValues(alpha: 0.55)
        : tint.withValues(alpha: 0.5);
    return (mineOverlay, mineBorder, mineFg);
  }

  Widget _buildContentPreview(BuildContext context, ReplyAttachmentKind kind) {
    final textColor = isMine ? context.onSentBubble : context.textSecondary;

    switch (kind) {
      case ReplyAttachmentKind.image:
      case ReplyAttachmentKind.gif:
        final url = extractMediaUrl(replyToContent.trim());
        if (url != null) {
          return _ReplyImageThumbnail(
            url: url,
            isGif: kind == ReplyAttachmentKind.gif,
            textColor: textColor,
          );
        }
        return _ReplyMediaLabel(
          icon: Icons.image_outlined,
          label: kind == ReplyAttachmentKind.gif ? 'GIF' : 'Image',
          color: textColor,
        );

      case ReplyAttachmentKind.video:
        return _ReplyMediaLabel(
          icon: Icons.videocam_outlined,
          label: 'Video',
          color: textColor,
        );

      case ReplyAttachmentKind.audio:
        return _ReplyMediaLabel(
          icon: Icons.mic_outlined,
          label: 'Voice message',
          color: textColor,
        );

      case ReplyAttachmentKind.file:
        final url = extractMediaUrl(replyToContent.trim());
        final filename = url != null
            ? (Uri.tryParse(url)?.pathSegments.lastOrNull ?? 'File')
            : 'File';
        return _ReplyMediaLabel(
          icon: Icons.attach_file_outlined,
          label: filename,
          color: textColor,
        );

      case ReplyAttachmentKind.none:
        final truncated = replyToContent.length > 100
            ? '${replyToContent.substring(0, 100)}...'
            : replyToContent;
        return Text(
          truncated,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: textColor),
        );
    }
  }
}

/// Small inline icon + label row for media reply previews.
class _ReplyMediaLabel extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _ReplyMediaLabel({
    required this.icon,
    required this.label,
    required this.color,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(
          child: Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: color),
          ),
        ),
      ],
    );
  }
}

/// 32x32 thumbnail + type label for image/GIF replies.
class _ReplyImageThumbnail extends StatelessWidget {
  final String url;
  final bool isGif;
  final Color textColor;

  const _ReplyImageThumbnail({
    required this.url,
    required this.textColor,
    this.isGif = false,
  });

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        ClipRRect(
          borderRadius: BorderRadius.circular(4),
          child: Image.network(
            url,
            width: 32,
            height: 32,
            fit: BoxFit.cover,
            errorBuilder: (_, _, _) =>
                Icon(Icons.image_outlined, size: 20, color: textColor),
          ),
        ),
        const SizedBox(width: 6),
        Text(
          isGif ? 'GIF' : 'Image',
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: textColor),
        ),
      ],
    );
  }
}
