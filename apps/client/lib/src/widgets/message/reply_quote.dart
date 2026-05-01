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

    final String semanticsLabel;
    switch (kind) {
      case ReplyAttachmentKind.image:
      case ReplyAttachmentKind.gif:
        semanticsLabel = onTap != null
            ? 'Jump to original message from ${replyToUsername ?? "Unknown"}'
            : 'In reply to ${replyToUsername ?? "Unknown"}: Image attachment';
      case ReplyAttachmentKind.video:
        semanticsLabel = onTap != null
            ? 'Jump to original message from ${replyToUsername ?? "Unknown"}'
            : 'In reply to ${replyToUsername ?? "Unknown"}: Video attachment';
      case ReplyAttachmentKind.audio:
        semanticsLabel = onTap != null
            ? 'Jump to original message from ${replyToUsername ?? "Unknown"}'
            : 'In reply to ${replyToUsername ?? "Unknown"}: Voice message';
      case ReplyAttachmentKind.file:
        semanticsLabel = onTap != null
            ? 'Jump to original message from ${replyToUsername ?? "Unknown"}'
            : 'In reply to ${replyToUsername ?? "Unknown"}: File attachment';
      case ReplyAttachmentKind.none:
        semanticsLabel = onTap != null
            ? 'Jump to original message from ${replyToUsername ?? "Unknown"}'
            : 'In reply to ${replyToUsername ?? "Unknown"}: $truncated';
    }

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
              color: (isMine ? Colors.white : context.accent).withValues(
                alpha: 0.12,
              ),
              borderRadius: BorderRadius.circular(8),
              border: Border(
                left: BorderSide(
                  color: isMine
                      ? Colors.white.withValues(alpha: 0.5)
                      : context.accent,
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
                    color: isMine
                        ? Colors.white.withValues(alpha: 0.8)
                        : context.accent,
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

  Widget _buildContentPreview(BuildContext context, ReplyAttachmentKind kind) {
    final textColor = isMine
        ? Colors.white.withValues(alpha: 0.7)
        : context.textSecondary;

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
