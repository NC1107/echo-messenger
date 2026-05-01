import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';
import '../message/media_content.dart';

/// Shows a reply-to preview bar above the input field.
///
/// Displays the original message author, a truncated preview of their message,
/// and a dismiss button. When the original message was a media attachment,
/// shows an icon + label instead of the raw URL.
class ReplyPreviewBar extends StatelessWidget {
  final ChatMessage replyToMessage;
  final VoidCallback onDismiss;

  const ReplyPreviewBar({
    super.key,
    required this.replyToMessage,
    required this.onDismiss,
  });

  @override
  Widget build(BuildContext context) {
    final content = replyToMessage.content;
    final kind = replyAttachmentKind(content);

    final String semanticPreview;
    switch (kind) {
      case ReplyAttachmentKind.image:
        semanticPreview = 'Image attachment';
      case ReplyAttachmentKind.gif:
        semanticPreview = 'GIF attachment';
      case ReplyAttachmentKind.video:
        semanticPreview = 'Video attachment';
      case ReplyAttachmentKind.audio:
        semanticPreview = 'Voice message';
      case ReplyAttachmentKind.file:
        final url = extractMediaUrl(content.trim());
        semanticPreview = url != null
            ? (Uri.tryParse(url)?.pathSegments.lastOrNull ?? 'File attachment')
            : 'File attachment';
      case ReplyAttachmentKind.none:
        final truncated = content.length > 120
            ? '${content.substring(0, 120)}...'
            : content;
        semanticPreview = truncated;
    }

    return Semantics(
      label: 'Replying to ${replyToMessage.fromUsername}: $semanticPreview',
      container: true,
      child: Container(
        width: double.infinity,
        margin: const EdgeInsets.only(bottom: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        decoration: BoxDecoration(
          color: context.accent.withValues(alpha: 0.08),
          borderRadius: BorderRadius.circular(8),
          border: Border(left: BorderSide(color: context.accent, width: 3)),
        ),
        child: Row(
          children: [
            Icon(Icons.reply_outlined, size: 14, color: context.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    'Replying to ${replyToMessage.fromUsername}',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: context.accent,
                    ),
                  ),
                  const SizedBox(height: 2),
                  _buildContentPreview(context, kind, content),
                ],
              ),
            ),
            const SizedBox(width: 8),
            Semantics(
              label: 'dismiss reply preview',
              button: true,
              child: GestureDetector(
                onTap: onDismiss,
                child: Icon(Icons.close, size: 14, color: context.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildContentPreview(
    BuildContext context,
    ReplyAttachmentKind kind,
    String content,
  ) {
    final textColor = context.textSecondary;
    switch (kind) {
      case ReplyAttachmentKind.image:
        return _ReplyBarMediaRow(
          icon: Icons.image_outlined,
          label: 'Image',
          color: textColor,
        );
      case ReplyAttachmentKind.gif:
        return _ReplyBarMediaRow(
          icon: Icons.image_outlined,
          label: 'GIF',
          color: textColor,
        );
      case ReplyAttachmentKind.video:
        return _ReplyBarMediaRow(
          icon: Icons.videocam_outlined,
          label: 'Video',
          color: textColor,
        );
      case ReplyAttachmentKind.audio:
        return _ReplyBarMediaRow(
          icon: Icons.mic_outlined,
          label: 'Voice message',
          color: textColor,
        );
      case ReplyAttachmentKind.file:
        final url = extractMediaUrl(content.trim());
        final filename = url != null
            ? (Uri.tryParse(url)?.pathSegments.lastOrNull ?? 'File')
            : 'File';
        return _ReplyBarMediaRow(
          icon: Icons.attach_file_outlined,
          label: filename,
          color: textColor,
        );
      case ReplyAttachmentKind.none:
        final truncated = content.length > 120
            ? '${content.substring(0, 120)}...'
            : content;
        return Text(
          truncated,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: textColor),
        );
    }
  }
}

/// Icon + label row for the compose reply bar media previews.
class _ReplyBarMediaRow extends StatelessWidget {
  final IconData icon;
  final String label;
  final Color color;

  const _ReplyBarMediaRow({
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
        Text(
          label,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 12, color: color),
        ),
      ],
    );
  }
}
