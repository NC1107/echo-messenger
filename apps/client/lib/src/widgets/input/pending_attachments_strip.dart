import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// State for a single attachment staged for sending.
///
/// Carries the bytes (or `null` for external-URL attachments like GIFs) plus
/// the metadata the multipart upload needs, the resolved URL once the upload
/// finishes, and a [ValueNotifier] for per-file progress so individual chips
/// rebuild without thrashing the rest of the input bar.
class PendingAttachment {
  /// Local bytes to upload. `null` for external-URL attachments (GIF picker)
  /// where [uploadedUrl] is set up-front and no upload is needed.
  final Uint8List? bytes;
  final String fileName;
  final String mimeType;
  final String ext;
  final int sizeBytes;
  final ValueNotifier<double> progress;
  String? uploadedUrl;
  bool isUploading;
  bool cancelled;
  String? error;

  PendingAttachment({
    required this.bytes,
    required this.fileName,
    required this.mimeType,
    required this.ext,
    required this.sizeBytes,
    this.uploadedUrl,
  }) : progress = ValueNotifier<double>(uploadedUrl == null ? 0.0 : 1.0),
       isUploading = uploadedUrl == null,
       cancelled = false,
       error = null;

  /// True when staged with an external URL (no local upload needed).
  bool get isExternalUrl => bytes == null;

  void dispose() {
    progress.dispose();
  }
}

/// Horizontal-scrolling row of staged attachment chips rendered above the
/// chat input. Each chip shows a thumbnail (or generic icon), filename,
/// human-readable size, an upload progress bar, and a cancel button.
class PendingAttachmentsStrip extends StatelessWidget {
  final List<PendingAttachment> attachments;
  final void Function(PendingAttachment) onCancel;

  const PendingAttachmentsStrip({
    super.key,
    required this.attachments,
    required this.onCancel,
  });

  @override
  Widget build(BuildContext context) {
    if (attachments.isEmpty) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      height: 88,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
        itemCount: attachments.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (ctx, i) =>
            _AttachmentChip(attachment: attachments[i], onCancel: onCancel),
      ),
    );
  }
}

class _AttachmentChip extends StatelessWidget {
  final PendingAttachment attachment;
  final void Function(PendingAttachment) onCancel;

  const _AttachmentChip({required this.attachment, required this.onCancel});

  @override
  Widget build(BuildContext context) {
    final isImage =
        attachment.mimeType.startsWith('image/') ||
        attachment.isExternalUrl; // GIFs are external URLs we treat as image
    return Semantics(
      label: 'Attached file: ${attachment.fileName}',
      container: true,
      child: Container(
        width: 220,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: context.border, width: 1),
        ),
        child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: _buildThumbnail(context, isImage),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    attachment.fileName,
                    style: TextStyle(
                      fontSize: 12,
                      color: context.textPrimary,
                      fontWeight: FontWeight.w500,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                  const SizedBox(height: 2),
                  Text(
                    attachment.isExternalUrl
                        ? 'GIF'
                        : _formatBytes(attachment.sizeBytes),
                    style: TextStyle(fontSize: 10, color: context.textMuted),
                  ),
                  const SizedBox(height: 4),
                  _buildProgress(context),
                ],
              ),
            ),
            const SizedBox(width: 4),
            Semantics(
              label: 'remove ${attachment.fileName}',
              button: true,
              child: GestureDetector(
                onTap: () => onCancel(attachment),
                child: Icon(Icons.close, size: 16, color: context.textMuted),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildThumbnail(BuildContext context, bool isImage) {
    final isAudio = attachment.mimeType.startsWith('audio/');
    if (isAudio) {
      return Container(
        width: 56,
        height: 56,
        color: context.mainBg,
        alignment: Alignment.center,
        child: Icon(Icons.mic, color: context.accent, size: 24),
      );
    }
    if (attachment.isExternalUrl && attachment.uploadedUrl != null) {
      // External GIF — render via network.
      return Image.network(
        attachment.uploadedUrl!,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _genericThumb(context),
      );
    }
    if (isImage && attachment.bytes != null) {
      return Image.memory(
        attachment.bytes!,
        width: 56,
        height: 56,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _genericThumb(context),
      );
    }
    return _genericThumb(context);
  }

  Widget _genericThumb(BuildContext context) {
    return Container(
      width: 56,
      height: 56,
      color: context.mainBg,
      alignment: Alignment.center,
      child: Icon(
        Icons.insert_drive_file_outlined,
        color: context.textMuted,
        size: 24,
      ),
    );
  }

  Widget _buildProgress(BuildContext context) {
    if (attachment.uploadedUrl != null) {
      return Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.check_circle, size: 12, color: EchoTheme.online),
          const SizedBox(width: 4),
          Text(
            'Ready',
            style: TextStyle(fontSize: 10, color: context.textMuted),
          ),
        ],
      );
    }
    return ValueListenableBuilder<double>(
      valueListenable: attachment.progress,
      builder: (context, value, _) {
        return Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: value,
                  minHeight: 3,
                  backgroundColor: context.border,
                  valueColor: AlwaysStoppedAnimation<Color>(context.accent),
                ),
              ),
            ),
            const SizedBox(width: 6),
            Text(
              '${(value * 100).round()}%',
              style: TextStyle(fontSize: 10, color: context.textMuted),
            ),
          ],
        );
      },
    );
  }
}

/// Format a byte count as a human-readable string (1024-based, 1 decimal).
String _formatBytes(int bytes) {
  if (bytes < 1024) return '$bytes B';
  const units = ['KB', 'MB', 'GB'];
  var v = bytes / 1024.0;
  var i = 0;
  while (v >= 1024 && i < units.length - 1) {
    v /= 1024;
    i++;
  }
  return '${v.toStringAsFixed(1)} ${units[i]}';
}
