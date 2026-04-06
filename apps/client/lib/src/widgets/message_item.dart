import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';

import '../models/chat_message.dart';
import '../models/reaction.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/download_helper.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart' show buildAvatar, avatarColor;

/// Common emojis for the reaction picker.
const reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👎', '🎉'];

/// Regex for detecting URLs in message text.
final _urlRegex = RegExp(r'https?://[^\s]+');

/// Regex for detecting standalone URL messages.
final _standaloneUrlRegex = RegExp(r'^https?://[^\s]+$', caseSensitive: false);

/// Regex for detecting @mentions in message text.
final _mentionRegex = RegExp(r'@(\w+)');

/// Regex for detecting image markers: [img:URL]
final _imgRegex = RegExp(r'^\[img:(.+)\]$');

/// Regex for detecting video markers: [video:URL]
final _videoRegex = RegExp(r'^\[video:(.+)\]$');

/// Regex for detecting generic file markers: [file:URL]
final _fileRegex = RegExp(r'^\[file:(.+)\]$');

const _imageExtensions = {'jpg', 'jpeg', 'png', 'gif', 'webp'};
const _videoExtensions = {'mp4', 'webm', 'mov'};
const _fileExtensions = {'pdf'};

class MessageItem extends StatefulWidget {
  final ChatMessage message;
  final bool showHeader;
  final bool isLastInGroup;
  final String myUserId;
  final void Function(ChatMessage message, Offset globalPosition)?
  onReactionTap;
  final void Function(ChatMessage message, String emoji)? onReactionSelect;
  final void Function(ChatMessage message)? onDelete;
  final void Function(ChatMessage message)? onEdit;
  final void Function(ChatMessage message)? onReply;
  final void Function(String userId)? onAvatarTap;

  /// Server URL for resolving relative image paths.
  final String? serverUrl;

  /// Auth token for authenticated image requests.
  final String? authToken;

  /// Avatar URL path for the message sender (relative, e.g. /api/users/.../avatar).
  final String? senderAvatarUrl;

  /// When true, uses Discord-style compact layout (all left-aligned, colored usernames).
  final bool compactLayout;

  const MessageItem({
    super.key,
    required this.message,
    required this.showHeader,
    required this.isLastInGroup,
    required this.myUserId,
    this.onReactionTap,
    this.onReactionSelect,
    this.onDelete,
    this.onEdit,
    this.onReply,
    this.onAvatarTap,
    this.serverUrl,
    this.authToken,
    this.senderAvatarUrl,
    this.compactLayout = false,
  });

  @override
  State<MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<MessageItem> {
  bool _isHovered = false;
  final List<TapGestureRecognizer> _linkRecognizers = [];

  @override
  void dispose() {
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    super.dispose();
  }

  String _resolveMediaUrl(String url) {
    if (url.startsWith('http')) return url; // external URLs (GIFs)
    final base = widget.serverUrl ?? '';
    final token = widget.authToken ?? '';
    // Append token as query param -- web <img> elements can't set headers
    return token.isNotEmpty ? '$base$url?token=$token' : '$base$url';
  }

  Map<String, String> _mediaHeaders() {
    final headers = <String, String>{};
    if (widget.authToken != null && widget.authToken!.isNotEmpty) {
      headers['Authorization'] = 'Bearer ${widget.authToken}';
    }
    return headers;
  }

  String _urlExtension(String url) {
    final uri = Uri.tryParse(url);
    final path = uri?.path ?? '';
    if (path.isEmpty || !path.contains('.')) return '';
    return path.split('.').last.toLowerCase();
  }

  bool _isStandaloneMediaUrl(String content) {
    final trimmed = content.trim();
    if (!_standaloneUrlRegex.hasMatch(trimmed)) return false;

    final ext = _urlExtension(trimmed);
    return _imageExtensions.contains(ext) ||
        _videoExtensions.contains(ext) ||
        _fileExtensions.contains(ext);
  }

  bool _isImageUrl(String url) => _imageExtensions.contains(_urlExtension(url));

  bool _isVideoUrl(String url) => _videoExtensions.contains(_urlExtension(url));

  bool _isFileUrl(String url) => _fileExtensions.contains(_urlExtension(url));

  String? _extractMediaUrl(String content) {
    final imageMatch = _imgRegex.firstMatch(content);
    if (imageMatch != null) return imageMatch.group(1);

    final videoMatch = _videoRegex.firstMatch(content);
    if (videoMatch != null) return videoMatch.group(1);

    final fileMatch = _fileRegex.firstMatch(content);
    if (fileMatch != null) return fileMatch.group(1);

    if (_isStandaloneMediaUrl(content)) {
      return content.trim();
    }

    return null;
  }

  String _filenameFromUrl(String url) {
    final parsed = Uri.tryParse(url);
    final lastSegment = (parsed?.pathSegments.isNotEmpty ?? false)
        ? parsed!.pathSegments.last
        : '';
    if (lastSegment.isEmpty) {
      return 'media.bin';
    }
    return lastSegment;
  }

  Future<void> _openMedia(String rawUrl) async {
    final uri = Uri.tryParse(_resolveMediaUrl(rawUrl));
    if (uri != null) {
      await launchUrl(uri, mode: LaunchMode.externalApplication);
    }
  }

  Future<void> _downloadMedia(String rawUrl) async {
    final mediaUrl = _resolveMediaUrl(rawUrl);
    try {
      final response = await http.get(
        Uri.parse(mediaUrl),
        headers: _mediaHeaders(),
      );
      if (!mounted) return;

      if (response.statusCode < 200 || response.statusCode >= 300) {
        ToastService.show(
          context,
          'Download failed (${response.statusCode})',
          type: ToastType.error,
        );
        return;
      }

      final contentType =
          response.headers['content-type'] ?? 'application/octet-stream';
      final downloaded = await saveBytesAsFile(
        fileName: _filenameFromUrl(mediaUrl),
        bytes: response.bodyBytes,
        mimeType: contentType,
      );

      if (!mounted) return;
      if (downloaded) {
        ToastService.show(context, 'Download started', type: ToastType.success);
        return;
      }

      await Clipboard.setData(ClipboardData(text: mediaUrl));
      if (!mounted) return;
      ToastService.show(
        context,
        'Save not supported here yet. Link copied.',
        type: ToastType.info,
      );
    } catch (_) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not download media',
        type: ToastType.error,
      );
    }
  }

  void _showImageViewer({required String imageUrl, required bool isMine}) {
    final headers = _mediaHeaders();
    showDialog<void>(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.black.withValues(alpha: 0.85),
        insetPadding: const EdgeInsets.all(20),
        child: Stack(
          children: [
            Positioned.fill(
              child: InteractiveViewer(
                minScale: 0.8,
                maxScale: 4,
                child: Center(
                  child: CachedNetworkImage(
                    imageUrl: imageUrl,
                    httpHeaders: headers,
                    fit: BoxFit.contain,
                    placeholder: (_, _) => const Center(
                      child: CircularProgressIndicator(color: Colors.white),
                    ),
                    errorWidget: (_, _, _) => const Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Colors.white54,
                        size: 48,
                      ),
                    ),
                  ),
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: const Icon(Icons.download_outlined),
                    color: Colors.white,
                    tooltip: 'Download',
                    onPressed: () => _downloadMedia(imageUrl),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: Colors.white,
                    tooltip: 'Close',
                    onPressed: () => Navigator.of(dialogContext).pop(),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatusIcon(MessageStatus? status) {
    if (status == null) return const SizedBox.shrink();
    IconData icon;
    Color color;
    switch (status) {
      case MessageStatus.sending:
        icon = Icons.schedule_outlined;
        color = context.textMuted;
      case MessageStatus.sent:
        icon = Icons.check_outlined;
        color = context.textMuted;
      case MessageStatus.delivered:
        icon = Icons.done_all_outlined;
        color = context.textMuted;
      case MessageStatus.read:
        icon = Icons.done_all_outlined;
        color = EchoTheme.online;
      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = EchoTheme.danger;
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Icon(icon, size: 12, color: color),
    );
  }

  /// Consistent color for a username -- matches sidebar avatar colors.
  Color _getUserColor(String userId) {
    final name = widget.message.fromUsername;
    return avatarColor(name);
  }

  /// Check if the message content is an image marker and build the image widget.
  Widget? _buildMediaContent(String content, {required bool isMine}) {
    final headers = _mediaHeaders();
    final imageMatch = _imgRegex.firstMatch(content);
    final standaloneUrl = _isStandaloneMediaUrl(content)
        ? content.trim()
        : null;
    final imageUrl =
        imageMatch?.group(1) ??
        (standaloneUrl != null && _isImageUrl(standaloneUrl)
            ? standaloneUrl
            : null);
    if (imageUrl != null) {
      final rawUrl = imageUrl;
      final fullUrl = _resolveMediaUrl(rawUrl);

      return Semantics(
        label: 'Image attachment. Tap to view full size.',
        image: true,
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: GestureDetector(
            onTap: () => _showImageViewer(imageUrl: fullUrl, isMine: isMine),
            child: Stack(
              children: [
                // Use Image.network for external GIFs to preserve animation
                fullUrl.startsWith('http') && _urlExtension(rawUrl) == 'gif'
                    ? Image.network(
                        fullUrl,
                        width: 300,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, e, st) => Container(
                          width: 300,
                          height: 80,
                          decoration: BoxDecoration(
                            color: context.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              '[GIF failed to load]',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      )
                    : CachedNetworkImage(
                        imageUrl: fullUrl,
                        width: 300,
                        fit: BoxFit.cover,
                        httpHeaders: headers,
                        errorWidget: (_, e, st) => Container(
                          width: 300,
                          height: 80,
                          decoration: BoxDecoration(
                            color: context.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: Text(
                              '[Image failed to load]',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                        placeholder: (_, _) => Container(
                          width: 300,
                          height: 80,
                          decoration: BoxDecoration(
                            color: context.surface,
                            borderRadius: BorderRadius.circular(12),
                          ),
                          child: Center(
                            child: SizedBox(
                              width: 20,
                              height: 20,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: context.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
                Positioned(
                  right: 8,
                  bottom: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.5),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: const Icon(
                      Icons.open_in_full,
                      size: 14,
                      color: Colors.white,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final videoMatch = _videoRegex.firstMatch(content);
    final videoUrl =
        videoMatch?.group(1) ??
        (standaloneUrl != null && _isVideoUrl(standaloneUrl)
            ? standaloneUrl
            : null);
    if (videoUrl != null) {
      final rawUrl = videoUrl;
      return Container(
        width: 300,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              height: 140,
              decoration: BoxDecoration(
                color: context.mainBg,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Center(
                child: Icon(
                  Icons.play_circle_outline,
                  size: 44,
                  color: context.textMuted,
                ),
              ),
            ),
            const SizedBox(height: 10),
            Text(
              'Video attachment',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _openMedia(rawUrl),
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('Open'),
                ),
                OutlinedButton.icon(
                  onPressed: () => _downloadMedia(rawUrl),
                  icon: const Icon(Icons.download_outlined, size: 14),
                  label: const Text('Download'),
                ),
              ],
            ),
          ],
        ),
      );
    }

    final fileMatch = _fileRegex.firstMatch(content);
    final fileUrl =
        fileMatch?.group(1) ??
        (standaloneUrl != null && _isFileUrl(standaloneUrl)
            ? standaloneUrl
            : null);
    if (fileUrl != null) {
      final rawUrl = fileUrl;
      final displayName = _filenameFromUrl(rawUrl);
      return Container(
        width: 300,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border),
        ),
        child: Row(
          children: [
            Container(
              width: 36,
              height: 36,
              decoration: BoxDecoration(
                color: context.mainBg,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Icon(
                Icons.insert_drive_file_outlined,
                color: context.textMuted,
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                displayName,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.download_outlined, size: 18),
              onPressed: () => _downloadMedia(rawUrl),
              tooltip: 'Download',
            ),
          ],
        ),
      );
    }

    return null;
  }

  Widget _buildHoverActions(ChatMessage msg, bool isMine, {String? mediaUrl}) {
    return Container(
      decoration: BoxDecoration(
        color: context.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _HoverActionButton(
            icon: Icons.copy_outlined,
            tooltip: 'Copy',
            onPressed: () {
              final copyText = mediaUrl != null
                  ? _resolveMediaUrl(mediaUrl)
                  : msg.content;
              Clipboard.setData(ClipboardData(text: copyText));
              ToastService.show(
                context,
                mediaUrl != null ? 'Media URL copied' : 'Copied to clipboard',
                type: ToastType.success,
              );
            },
          ),
          if (mediaUrl != null)
            _HoverActionButton(
              icon: Icons.download_outlined,
              tooltip: 'Download',
              onPressed: () => _downloadMedia(mediaUrl),
            ),
          if (widget.onReply != null)
            Semantics(
              label: 'Reply to message',
              button: true,
              child: _HoverActionButton(
                icon: Icons.reply_outlined,
                tooltip: 'Reply',
                onPressed: () => widget.onReply?.call(msg),
              ),
            ),
          _HoverActionButton(
            icon: Icons.add_reaction_outlined,
            tooltip: 'React',
            onPressed: () {
              final box = context.findRenderObject() as RenderBox?;
              final pos = box?.localToGlobal(Offset.zero) ?? Offset.zero;
              widget.onReactionTap?.call(msg, pos);
            },
          ),
          if (isMine && widget.onEdit != null)
            _HoverActionButton(
              icon: Icons.edit_outlined,
              tooltip: 'Edit',
              onPressed: () => widget.onEdit?.call(msg),
            ),
          if (isMine && widget.onDelete != null)
            _HoverActionButton(
              icon: Icons.delete_outlined,
              tooltip: 'Delete',
              onPressed: () => widget.onDelete?.call(msg),
            ),
        ],
      ),
    );
  }

  /// Build spans for a plain text segment (no URLs), highlighting @mentions.
  List<InlineSpan> _buildMentionSpans(String text, {required Color textColor}) {
    final mentionMatches = _mentionRegex.allMatches(text).toList();
    if (mentionMatches.isEmpty) {
      return [
        TextSpan(
          text: text,
          style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
        ),
      ];
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;
    for (final match in mentionMatches) {
      if (match.start > lastEnd) {
        spans.add(
          TextSpan(
            text: text.substring(lastEnd, match.start),
            style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
          ),
        );
      }
      spans.add(
        TextSpan(
          text: match.group(0),
          style: TextStyle(
            fontSize: 15,
            color: context.accentHover,
            fontWeight: FontWeight.w600,
            height: 1.47,
          ),
        ),
      );
      lastEnd = match.end;
    }
    if (lastEnd < text.length) {
      spans.add(
        TextSpan(
          text: text.substring(lastEnd),
          style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
        ),
      );
    }
    return spans;
  }

  TapGestureRecognizer _createLinkRecognizer(String url) {
    final recognizer = TapGestureRecognizer()
      ..onTap = () async {
        final uri = Uri.tryParse(url);
        if (uri != null && await canLaunchUrl(uri)) {
          await launchUrl(uri, mode: LaunchMode.externalApplication);
        }
      };
    _linkRecognizers.add(recognizer);
    return recognizer;
  }

  /// Build a friendly decryption failure message with a recovery action.
  Widget _buildDecryptionFailure() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.lock_open, size: 14, color: EchoTheme.danger),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Unable to decrypt this message',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: EchoTheme.danger.withValues(alpha: 0.8),
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        GestureDetector(
          onTap: () => context.push('/settings'),
          child: Text(
            'Reset encryption keys in Settings',
            style: TextStyle(
              color: context.accent,
              fontSize: 12,
              decoration: TextDecoration.underline,
              decorationColor: context.accent,
            ),
          ),
        ),
      ],
    );
  }

  /// Build a RichText widget that renders URLs as tappable links and @mentions
  /// with accent color + bold weight.
  Widget _buildMessageText(String text, {required Color textColor}) {
    // Dispose old recognizers on each rebuild
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();
    final urlMatches = _urlRegex.allMatches(text).toList();
    final mentionMatches = _mentionRegex.allMatches(text).toList();

    if (urlMatches.isEmpty && mentionMatches.isEmpty) {
      return Text(
        text,
        style: TextStyle(fontSize: 15, color: textColor, height: 1.47),
      );
    }

    // If no URLs, just handle mentions.
    if (urlMatches.isEmpty) {
      return RichText(
        text: TextSpan(
          children: _buildMentionSpans(text, textColor: textColor),
        ),
      );
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in urlMatches) {
      // Text before the URL -- may contain mentions
      if (match.start > lastEnd) {
        spans.addAll(
          _buildMentionSpans(
            text.substring(lastEnd, match.start),
            textColor: textColor,
          ),
        );
      }

      // The URL itself
      final url = match.group(0)!;
      spans.add(
        TextSpan(
          text: url,
          style: TextStyle(
            fontSize: 15,
            color: context.accentHover,
            decoration: TextDecoration.underline,
            decorationColor: context.accentHover,
            height: 1.47,
          ),
          recognizer: _createLinkRecognizer(url),
        ),
      );

      lastEnd = match.end;
    }

    // Remaining text after last URL -- may contain mentions
    if (lastEnd < text.length) {
      spans.addAll(
        _buildMentionSpans(text.substring(lastEnd), textColor: textColor),
      );
    }

    return RichText(text: TextSpan(children: spans));
  }

  Widget _buildReactionPill(List<Reaction> reactions, bool isMine) {
    if (reactions.isEmpty) return const SizedBox.shrink();

    // Collect unique emojis preserving order of first appearance.
    final seen = <String>{};
    final uniqueEmojis = <String>[];
    for (final r in reactions) {
      if (seen.add(r.emoji)) uniqueEmojis.add(r.emoji);
    }

    final totalCount = reactions.length;

    return GestureDetector(
      onTapUp: (details) =>
          widget.onReactionTap?.call(widget.message, details.globalPosition),
      child: Container(
        height: 24,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: context.border, width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            for (final emoji in uniqueEmojis)
              Padding(
                padding: const EdgeInsets.only(right: 2),
                child: Text(emoji, style: const TextStyle(fontSize: 14)),
              ),
            if (totalCount > 1) ...[
              const SizedBox(width: 2),
              Text(
                '$totalCount',
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          ],
        ),
      ),
    );
  }

  /// Resolve the bubble background color based on message state.
  Color _bubbleColor({required bool isMine, required bool isFailed}) {
    if (isFailed) return EchoTheme.danger.withValues(alpha: 0.2);
    if (isMine) return context.sentBubble;
    return context.recvBubble;
  }

  /// Resolve the bubble border radius with a flat corner on the sender's side.
  BorderRadius _bubbleBorderRadius({required bool isMine}) {
    return BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isMine ? 16 : 4),
      bottomRight: Radius.circular(isMine ? 4 : 16),
    );
  }

  /// Build the sender name label shown above the message bubble.
  Widget _buildSenderNameLabel({
    required ChatMessage msg,
    required bool hasMedia,
  }) {
    return Padding(
      padding: EdgeInsets.only(bottom: 4, left: hasMedia ? 8 : 0),
      child: Text(
        msg.fromUsername,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: _getUserColor(msg.fromUserId),
        ),
      ),
    );
  }

  /// Build the reply-to quote block shown above the message content.
  Widget _buildReplyQuote({required ChatMessage msg, required bool isMine}) {
    final replyContent = msg.replyToContent!;
    final truncated = replyContent.length > 100
        ? '${replyContent.substring(0, 100)}...'
        : replyContent;

    return Container(
      margin: const EdgeInsets.only(bottom: 6),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: (isMine ? Colors.white : context.accent).withValues(alpha: 0.12),
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
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            msg.replyToUsername ?? 'Unknown',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: isMine
                  ? Colors.white.withValues(alpha: 0.8)
                  : context.accent,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            truncated,
            maxLines: 2,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 12,
              color: isMine
                  ? Colors.white.withValues(alpha: 0.7)
                  : context.textSecondary,
            ),
          ),
        ],
      ),
    );
  }

  /// Select and build the primary message content (media, decrypt error, or
  /// rich text).
  Widget _buildBubbleContent({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required Widget? mediaWidget,
  }) {
    if (mediaWidget != null) return mediaWidget;
    if (msg.content.startsWith('[Could not decrypt')) {
      return _buildDecryptionFailure();
    }
    return _buildMessageText(
      msg.content,
      textColor: _contentTextColor(isMine: isMine, isFailed: isFailed),
    );
  }

  /// Resolve text color for message content.
  Color _contentTextColor({required bool isMine, required bool isFailed}) {
    if (isFailed) return EchoTheme.danger;
    if (isMine) return Colors.white;
    return context.textPrimary;
  }

  /// Assemble the children of the bubble Column.
  List<Widget> _bubbleChildren({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required Widget? mediaWidget,
  }) {
    return [
      if (widget.showHeader && (!isMine || widget.compactLayout))
        _buildSenderNameLabel(msg: msg, hasMedia: mediaWidget != null),
      if (msg.replyToContent != null)
        _buildReplyQuote(msg: msg, isMine: isMine),
      _buildBubbleContent(
        msg: msg,
        isMine: isMine,
        isFailed: isFailed,
        mediaWidget: mediaWidget,
      ),
    ];
  }

  /// Build the full message bubble container.
  Widget _buildBubble({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required Widget? mediaWidget,
  }) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: mediaWidget != null
          ? const EdgeInsets.all(4)
          : const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: _bubbleColor(isMine: isMine, isFailed: isFailed),
        borderRadius: _bubbleBorderRadius(isMine: isMine),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: _bubbleChildren(
          msg: msg,
          isMine: isMine,
          isFailed: isFailed,
          mediaWidget: mediaWidget,
        ),
      ),
    );
  }

  /// Wrap the bubble with a reaction pill overlay when reactions exist.
  Widget _buildBubbleWithReactions({
    required Widget bubble,
    required bool isMine,
    required bool hasReactions,
    required Widget reactionPill,
  }) {
    if (!hasReactions) return bubble;
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 14), child: bubble),
        Positioned(
          bottom: 0,
          left: isMine ? null : 8,
          right: isMine ? 8 : null,
          child: reactionPill,
        ),
      ],
    );
  }

  /// Build the avatar section shown to the left of received messages.
  Widget _buildAvatarSection({required ChatMessage msg}) {
    final avatarImageUrl = widget.senderAvatarUrl != null
        ? '${widget.serverUrl ?? ""}${widget.senderAvatarUrl}'
        : null;

    return Semantics(
      label: 'View profile of ${msg.fromUsername}',
      button: true,
      child: GestureDetector(
        onTap: widget.onAvatarTap != null
            ? () => widget.onAvatarTap!(msg.fromUserId)
            : null,
        child: SizedBox(
          width: 28,
          child: widget.showHeader
              ? buildAvatar(
                  name: msg.fromUsername,
                  radius: 14,
                  bgColor: _getUserColor(msg.fromUserId),
                  imageUrl: avatarImageUrl,
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  /// Build the timestamp row shown below the last message in a group.
  Widget _buildTimestampRow({required ChatMessage msg, required bool isMine}) {
    return Padding(
      padding: EdgeInsets.only(top: 4, left: isMine ? 0 : 36),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: isMine
            ? MainAxisAlignment.end
            : MainAxisAlignment.start,
        children: [
          Text(
            formatMessageTimestamp(msg.timestamp),
            style: TextStyle(fontSize: 11, color: context.textMuted),
          ),
          if (msg.isEncrypted)
            const Padding(
              padding: EdgeInsets.only(left: 3),
              child: Icon(Icons.lock, size: 10, color: EchoTheme.online),
            ),
          if (msg.editedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Text(
                '(edited)',
                style: TextStyle(
                  fontSize: 10,
                  fontStyle: FontStyle.italic,
                  color: context.textMuted,
                ),
              ),
            ),
          if (isMine) _buildStatusIcon(msg.status),
        ],
      ),
    );
  }

  /// Build the hover-actions overlay that appears above the bubble.
  Widget _buildHoverOverlay({
    required ChatMessage msg,
    required bool isMine,
    required String? mediaUrl,
  }) {
    return Positioned(
      top: -12,
      left: isMine ? null : 36,
      right: isMine ? 0 : null,
      child: IgnorePointer(
        ignoring: !_isHovered,
        child: AnimatedOpacity(
          opacity: _isHovered ? 1 : 0,
          duration: const Duration(milliseconds: 140),
          curve: Curves.easeOut,
          child: AnimatedSlide(
            offset: _isHovered ? Offset.zero : const Offset(0, -0.12),
            duration: const Duration(milliseconds: 140),
            curve: Curves.easeOut,
            child: _buildHoverActions(msg, isMine, mediaUrl: mediaUrl),
          ),
        ),
      ),
    );
  }

  /// Build the main message row containing the avatar and bubble.
  List<Widget> _buildMessageRowChildren({
    required ChatMessage msg,
    required bool isMine,
    required Widget bubbleWithReactions,
  }) {
    return [
      if (!isMine || widget.compactLayout) ...[
        _buildAvatarSection(msg: msg),
        const SizedBox(width: 8),
      ],
      Flexible(child: bubbleWithReactions),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isMine = msg.isMine;
    final isFailed = msg.status == MessageStatus.failed;

    final mediaWidget = _buildMediaContent(msg.content, isMine: isMine);
    final mediaUrl = _extractMediaUrl(msg.content);

    final hasReactions = msg.reactions.isNotEmpty;
    final reactionPill = _buildReactionPill(msg.reactions, isMine);

    final bubble = _buildBubble(
      msg: msg,
      isMine: isMine,
      isFailed: isFailed,
      mediaWidget: mediaWidget,
    );

    final bubbleWithReactions = _buildBubbleWithReactions(
      bubble: bubble,
      isMine: isMine,
      hasReactions: hasReactions,
      reactionPill: reactionPill,
    );

    final isAlignedEnd = isMine && !widget.compactLayout;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Semantics(
        label: 'Message from ${msg.fromUsername}. Long press for actions.',
        child: GestureDetector(
          onLongPressStart: !hasReactions
              ? (details) =>
                    widget.onReactionTap?.call(msg, details.globalPosition)
              : null,
          child: Container(
            padding: EdgeInsets.only(
              left: 24,
              right: 24,
              top: widget.showHeader ? 8 : 2,
              bottom: hasReactions ? 4 : 2,
            ),
            child: Stack(
              clipBehavior: Clip.none,
              children: [
                Column(
                  crossAxisAlignment: isAlignedEnd
                      ? CrossAxisAlignment.end
                      : CrossAxisAlignment.start,
                  children: [
                    Row(
                      mainAxisAlignment: isAlignedEnd
                          ? MainAxisAlignment.end
                          : MainAxisAlignment.start,
                      crossAxisAlignment: CrossAxisAlignment.end,
                      children: _buildMessageRowChildren(
                        msg: msg,
                        isMine: isMine,
                        bubbleWithReactions: bubbleWithReactions,
                      ),
                    ),
                    if (widget.isLastInGroup)
                      _buildTimestampRow(msg: msg, isMine: isMine),
                  ],
                ),
                if (!hasReactions)
                  _buildHoverOverlay(
                    msg: msg,
                    isMine: isMine,
                    mediaUrl: mediaUrl,
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _HoverActionButton extends StatelessWidget {
  final IconData icon;
  final String tooltip;
  final VoidCallback onPressed;

  const _HoverActionButton({
    required this.icon,
    required this.tooltip,
    required this.onPressed,
  });

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onPressed,
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Opacity(
            opacity: 0.75,
            child: Icon(icon, size: 14, color: context.textSecondary),
          ),
        ),
      ),
    );
  }
}
