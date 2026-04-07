import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Displays a Discord-style attachment preview bar above the input field.
///
/// Shows a thumbnail, filename, upload status, and a remove button.
class AttachmentPreview extends StatelessWidget {
  final Uint8List? attachmentBytes;
  final String? fileName;
  final String? mimeType;
  final String? uploadedUrl;
  final bool isUploading;
  final VoidCallback onClear;

  const AttachmentPreview({
    super.key,
    required this.attachmentBytes,
    this.fileName,
    this.mimeType,
    this.uploadedUrl,
    this.isUploading = false,
    required this.onClear,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.border, width: 1),
      ),
      child: Row(
        children: [
          // Thumbnail
          ClipRRect(
            borderRadius: BorderRadius.circular(6),
            child: _buildThumbnail(context),
          ),
          const SizedBox(width: 10),
          // Filename + status
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: [
                Text(
                  fileName ?? 'Attachment',
                  style: TextStyle(
                    fontSize: 13,
                    color: context.textPrimary,
                    fontWeight: FontWeight.w500,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 2),
                _buildStatusText(context),
              ],
            ),
          ),
          _buildTrailingWidgets(context),
        ],
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context) {
    if (attachmentBytes != null) {
      return Image.memory(
        attachmentBytes!,
        width: 48,
        height: 48,
        fit: BoxFit.cover,
        errorBuilder: (_, e, st) => Container(
          width: 48,
          height: 48,
          color: context.mainBg,
          child: Icon(
            Icons.insert_drive_file_outlined,
            color: context.textMuted,
            size: 24,
          ),
        ),
      );
    }
    return Container(
      width: 48,
      height: 48,
      color: context.mainBg,
      child: Icon(Icons.gif_box_outlined, color: context.accent, size: 24),
    );
  }

  Widget _buildStatusText(BuildContext context) {
    final String statusLabel;
    final Color statusColor;

    if (isUploading) {
      statusLabel = 'Uploading...';
      statusColor = context.textMuted;
    } else if (uploadedUrl != null) {
      statusLabel = 'Ready to send';
      statusColor = EchoTheme.online;
    } else {
      statusLabel = 'Preparing...';
      statusColor = context.textMuted;
    }

    return Text(
      statusLabel,
      style: TextStyle(fontSize: 11, color: statusColor),
    );
  }

  Widget _buildTrailingWidgets(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (isUploading)
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: context.accent,
            ),
          )
        else if (uploadedUrl != null)
          const Icon(
            Icons.check_circle_outline,
            size: 16,
            color: EchoTheme.online,
          ),
        const SizedBox(width: 6),
        // Remove button
        GestureDetector(
          onTap: onClear,
          child: Icon(Icons.close, size: 16, color: context.textMuted),
        ),
      ],
    );
  }
}
