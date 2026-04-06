import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:url_launcher/url_launcher.dart';
import 'package:video_player/video_player.dart';

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

/// Regex for detecting fenced code blocks: ```\n...\n``` (multiline).
final _codeBlockRegex = RegExp(r'```\n?([\s\S]*?)```', multiLine: true);

/// Regex for detecting inline code: `...` (single backtick, no nesting).
final _inlineCodeRegex = RegExp(r'`([^`\n]+)`');

/// Regex for detecting bold text: **...**
final _boldRegex = RegExp(r'\*\*(.+?)\*\*');

/// Regex for detecting italic text: *...*
/// Negative lookahead/lookbehind to avoid matching ** (bold delimiters).
final _italicRegex = RegExp(r'(?<!\*)\*([^*]+?)\*(?!\*)');

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
  final void Function(ChatMessage message)? onPin;
  final void Function(ChatMessage message)? onUnpin;

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
    this.onPin,
    this.onUnpin,
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
      barrierColor: Colors.black.withValues(alpha: 0.85),
      builder: (dialogContext) {
        final screenSize = MediaQuery.of(dialogContext).size;
        final maxWidth = screenSize.width * 0.8;
        final maxHeight = screenSize.height * 0.8;
        return GestureDetector(
          onTap: () => Navigator.of(dialogContext).pop(),
          behavior: HitTestBehavior.opaque,
          child: Center(
            child: GestureDetector(
              onTap: () {}, // absorb taps on the image itself
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: maxWidth,
                  maxHeight: maxHeight,
                ),
                child: Stack(
                  children: [
                    InteractiveViewer(
                      minScale: 0.8,
                      maxScale: 4,
                      child: Center(
                        child: CachedNetworkImage(
                          imageUrl: imageUrl,
                          httpHeaders: headers,
                          fit: BoxFit.contain,
                          placeholder: (_, _) => const Center(
                            child: CircularProgressIndicator(
                              color: Colors.white,
                            ),
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
            ),
          ),
        );
      },
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
      return _InlineVideoPlayer(
        videoUrl: _resolveMediaUrl(rawUrl),
        rawUrl: rawUrl,
        headers: _mediaHeaders(),
        surface: context.surface,
        mainBg: context.mainBg,
        border: context.border,
        textPrimary: context.textPrimary,
        textMuted: context.textMuted,
        onOpen: () => _openMedia(rawUrl),
        onDownload: () => _downloadMedia(rawUrl),
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
          if (msg.pinnedAt == null && widget.onPin != null)
            _HoverActionButton(
              icon: Icons.push_pin_outlined,
              tooltip: 'Pin',
              onPressed: () => widget.onPin?.call(msg),
            ),
          if (msg.pinnedAt != null && widget.onUnpin != null)
            _HoverActionButton(
              icon: Icons.push_pin,
              tooltip: 'Unpin',
              onPressed: () => widget.onUnpin?.call(msg),
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

  /// Base text style used throughout message rendering.
  TextStyle _baseStyle({required Color textColor}) =>
      TextStyle(fontSize: 15, color: textColor, height: 1.47);

  /// Build spans for plain text that may contain @mentions.
  /// Called for segments that have already been stripped of URLs, code, bold,
  /// and italic markers.
  List<InlineSpan> _buildMentionSpans(String text, {required Color textColor}) {
    final mentionMatches = _mentionRegex.allMatches(text).toList();
    if (mentionMatches.isEmpty) {
      return [
        TextSpan(
          text: text,
          style: _baseStyle(textColor: textColor),
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
            style: _baseStyle(textColor: textColor),
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
          style: _baseStyle(textColor: textColor),
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

  /// Build spans for a segment that may contain bold, italic, URLs, and
  /// mentions (but NOT code -- code is stripped before this is called).
  List<InlineSpan> _buildFormattedSpans(
    String text, {
    required Color textColor,
  }) {
    // Collect all matches for bold, italic, and URLs with a tag so we can
    // process them in document order.
    final entries = <({int start, int end, String tag, RegExpMatch match})>[];

    for (final m in _boldRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'bold', match: m));
    }
    for (final m in _italicRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'italic', match: m));
    }
    for (final m in _urlRegex.allMatches(text)) {
      entries.add((start: m.start, end: m.end, tag: 'url', match: m));
    }

    // Sort by start position; break ties by preferring longer matches.
    entries.sort((a, b) {
      final cmp = a.start.compareTo(b.start);
      if (cmp != 0) return cmp;
      return b.end.compareTo(a.end);
    });

    // Remove overlapping entries (first match wins).
    final filtered = <({int start, int end, String tag, RegExpMatch match})>[];
    int cursor = 0;
    for (final e in entries) {
      if (e.start < cursor) continue; // overlaps with a previous match
      filtered.add(e);
      cursor = e.end;
    }

    if (filtered.isEmpty) {
      return _buildMentionSpans(text, textColor: textColor);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final e in filtered) {
      // Gap before this match -- may contain mentions
      if (e.start > lastEnd) {
        spans.addAll(
          _buildMentionSpans(
            text.substring(lastEnd, e.start),
            textColor: textColor,
          ),
        );
      }

      switch (e.tag) {
        case 'bold':
          final inner = e.match.group(1)!;
          spans.add(
            TextSpan(
              text: inner,
              style: _baseStyle(
                textColor: textColor,
              ).copyWith(fontWeight: FontWeight.bold),
            ),
          );
        case 'italic':
          final inner = e.match.group(1)!;
          spans.add(
            TextSpan(
              text: inner,
              style: _baseStyle(
                textColor: textColor,
              ).copyWith(fontStyle: FontStyle.italic),
            ),
          );
        case 'url':
          final url = e.match.group(0)!;
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
      }

      lastEnd = e.end;
    }

    // Remaining text after last match
    if (lastEnd < text.length) {
      spans.addAll(
        _buildMentionSpans(text.substring(lastEnd), textColor: textColor),
      );
    }

    return spans;
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

  /// Build spans for a segment that may contain inline code, bold, italic,
  /// URLs, and mentions (but NOT fenced code blocks).
  List<InlineSpan> _buildInlineCodeAndFormatting(
    String text, {
    required Color textColor,
  }) {
    final inlineCodeMatches = _inlineCodeRegex.allMatches(text).toList();
    if (inlineCodeMatches.isEmpty) {
      return _buildFormattedSpans(text, textColor: textColor);
    }

    final spans = <InlineSpan>[];
    int lastEnd = 0;

    for (final match in inlineCodeMatches) {
      // Gap before inline code -- process for bold/italic/URL/mention
      if (match.start > lastEnd) {
        spans.addAll(
          _buildFormattedSpans(
            text.substring(lastEnd, match.start),
            textColor: textColor,
          ),
        );
      }

      // Inline code span with monospace + subtle background
      final code = match.group(1)!;
      spans.add(
        WidgetSpan(
          alignment: PlaceholderAlignment.baseline,
          baseline: TextBaseline.alphabetic,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
            decoration: BoxDecoration(
              color: context.textSecondary.withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              code,
              style: TextStyle(
                fontSize: 14,
                fontFamily: 'monospace',
                color: textColor,
                height: 1.47,
              ),
            ),
          ),
        ),
      );

      lastEnd = match.end;
    }

    // Remaining text after last inline code
    if (lastEnd < text.length) {
      spans.addAll(
        _buildFormattedSpans(text.substring(lastEnd), textColor: textColor),
      );
    }

    return spans;
  }

  /// Build a RichText widget that renders markdown formatting, URLs as tappable
  /// links, and @mentions with accent color + bold weight.
  ///
  /// Precedence: code blocks > inline code > bold > italic > URLs > mentions.
  Widget _buildMessageText(String text, {required Color textColor}) {
    // Dispose old recognizers on each rebuild
    for (final r in _linkRecognizers) {
      r.dispose();
    }
    _linkRecognizers.clear();

    // Check for fenced code blocks first (highest precedence).
    final codeBlockMatches = _codeBlockRegex.allMatches(text).toList();

    if (codeBlockMatches.isEmpty) {
      // No code blocks -- check if any formatting exists at all.
      final hasUrl = _urlRegex.hasMatch(text);
      final hasMention = _mentionRegex.hasMatch(text);
      final hasBold = _boldRegex.hasMatch(text);
      final hasItalic = _italicRegex.hasMatch(text);
      final hasInlineCode = _inlineCodeRegex.hasMatch(text);

      if (!hasUrl && !hasMention && !hasBold && !hasItalic && !hasInlineCode) {
        return Text(text, style: _baseStyle(textColor: textColor));
      }

      return RichText(
        text: TextSpan(
          children: _buildInlineCodeAndFormatting(text, textColor: textColor),
        ),
      );
    }

    // Has code blocks -- build a Column with interleaved text and code blocks.
    final children = <Widget>[];
    int lastEnd = 0;

    for (final match in codeBlockMatches) {
      // Text segment before the code block
      if (match.start > lastEnd) {
        final segment = text.substring(lastEnd, match.start);
        if (segment.trim().isNotEmpty) {
          children.add(
            RichText(
              text: TextSpan(
                children: _buildInlineCodeAndFormatting(
                  segment.trim(),
                  textColor: textColor,
                ),
              ),
            ),
          );
        }
      }

      // The code block itself
      final code = match.group(1) ?? '';
      children.add(
        Container(
          width: double.infinity,
          margin: const EdgeInsets.symmetric(vertical: 4),
          padding: const EdgeInsets.all(10),
          decoration: BoxDecoration(
            color: context.textSecondary.withValues(alpha: 0.12),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(
            code.trimRight(),
            style: TextStyle(
              fontSize: 13,
              fontFamily: 'monospace',
              color: textColor,
              height: 1.5,
            ),
          ),
        ),
      );

      lastEnd = match.end;
    }

    // Remaining text after the last code block
    if (lastEnd < text.length) {
      final segment = text.substring(lastEnd);
      if (segment.trim().isNotEmpty) {
        children.add(
          RichText(
            text: TextSpan(
              children: _buildInlineCodeAndFormatting(
                segment.trim(),
                textColor: textColor,
              ),
            ),
          ),
        );
      }
    }

    if (children.length == 1) return children.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: children,
    );
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
  /// In compact mode all messages are left-aligned, so the flat corner is
  /// always on the bottom-left regardless of sender.
  BorderRadius _bubbleBorderRadius({required bool isMine}) {
    final isRight = isMine && !widget.compactLayout;
    return BorderRadius.only(
      topLeft: const Radius.circular(16),
      topRight: const Radius.circular(16),
      bottomLeft: Radius.circular(isRight ? 16 : 4),
      bottomRight: Radius.circular(isRight ? 4 : 16),
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

  /// Regex for image extensions in URLs (used for inline embed detection).
  static final _imageUrlEmbedRegex = RegExp(
    r'https?://[^\s]+\.(?:gif|png|jpe?g|webp)',
    caseSensitive: false,
  );

  /// Extract image URLs embedded within text (not standalone).
  List<String> _extractEmbeddedImageUrls(String content) {
    // Skip standalone media URLs -- those are handled by _buildMediaContent.
    if (_isStandaloneMediaUrl(content)) return [];
    if (_imgRegex.hasMatch(content)) return [];
    return _imageUrlEmbedRegex
        .allMatches(content)
        .map((m) => m.group(0)!)
        .toList();
  }

  /// Select and build the primary message content (media, decrypt error, or
  /// rich text). When the text contains embedded image URLs mixed with
  /// regular text, image previews are appended below the text.
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

    final textColor = _contentTextColor(isMine: isMine, isFailed: isFailed);
    final textWidget = _buildMessageText(msg.content, textColor: textColor);

    final embeddedImages = _extractEmbeddedImageUrls(msg.content);
    if (embeddedImages.isEmpty) return textWidget;

    final headers = _mediaHeaders();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        textWidget,
        for (final imgUrl in embeddedImages) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: GestureDetector(
              onTap: () => _showImageViewer(imageUrl: imgUrl, isMine: isMine),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: imgUrl.endsWith('.gif')
                    ? Image.network(
                        imgUrl,
                        fit: BoxFit.cover,
                        gaplessPlayback: true,
                        errorBuilder: (_, _, _) => const SizedBox.shrink(),
                      )
                    : CachedNetworkImage(
                        imageUrl: imgUrl,
                        fit: BoxFit.cover,
                        httpHeaders: headers,
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
                        placeholder: (_, _) => SizedBox(
                          height: 60,
                          child: Center(
                            child: SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: context.textMuted,
                              ),
                            ),
                          ),
                        ),
                      ),
              ),
            ),
          ),
        ],
      ],
    );
  }

  /// Resolve text color for message content.
  Color _contentTextColor({required bool isMine, required bool isFailed}) {
    if (isFailed) return EchoTheme.danger;
    if (isMine) return Colors.white;
    return context.textPrimary;
  }

  /// Build a small pinned indicator shown inside the bubble.
  Widget _buildPinnedIndicator({required bool isMine}) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.push_pin,
            size: 11,
            color: isMine
                ? Colors.white.withValues(alpha: 0.7)
                : context.accent,
          ),
          const SizedBox(width: 3),
          Text(
            'Pinned',
            style: TextStyle(
              fontSize: 10,
              fontWeight: FontWeight.w500,
              color: isMine
                  ? Colors.white.withValues(alpha: 0.7)
                  : context.accent,
            ),
          ),
        ],
      ),
    );
  }

  /// Assemble the children of the bubble Column.
  List<Widget> _bubbleChildren({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required Widget? mediaWidget,
  }) {
    return [
      if (msg.pinnedAt != null) _buildPinnedIndicator(isMine: isMine),
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
          if (msg.pinnedAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Icon(Icons.push_pin, size: 10, color: context.accent),
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

/// Inline video player widget with play/pause controls and download
/// fallback. Initialises a [VideoPlayerController] on first build and
/// disposes it when removed from the tree.
class _InlineVideoPlayer extends StatefulWidget {
  final String videoUrl;
  final String rawUrl;
  final Map<String, String> headers;
  final Color surface;
  final Color mainBg;
  final Color border;
  final Color textPrimary;
  final Color textMuted;
  final VoidCallback onOpen;
  final VoidCallback onDownload;

  const _InlineVideoPlayer({
    required this.videoUrl,
    required this.rawUrl,
    required this.headers,
    required this.surface,
    required this.mainBg,
    required this.border,
    required this.textPrimary,
    required this.textMuted,
    required this.onOpen,
    required this.onDownload,
  });

  @override
  State<_InlineVideoPlayer> createState() => _InlineVideoPlayerState();
}

class _InlineVideoPlayerState extends State<_InlineVideoPlayer> {
  VideoPlayerController? _controller;
  bool _initFailed = false;

  @override
  void initState() {
    super.initState();
    _initVideo();
  }

  Future<void> _initVideo() async {
    try {
      final controller = VideoPlayerController.networkUrl(
        Uri.parse(widget.videoUrl),
        httpHeaders: widget.headers,
      );
      await controller.initialize();
      if (!mounted) {
        controller.dispose();
        return;
      }
      setState(() => _controller = controller);
    } catch (_) {
      if (mounted) setState(() => _initFailed = true);
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  void _togglePlayPause() {
    final c = _controller;
    if (c == null) return;
    setState(() {
      c.value.isPlaying ? c.pause() : c.play();
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 300,
      padding: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        color: widget.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: widget.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: _buildVideoArea(),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Wrap(
              spacing: 8,
              children: [
                OutlinedButton.icon(
                  onPressed: widget.onOpen,
                  icon: const Icon(Icons.open_in_new, size: 14),
                  label: const Text('Open'),
                ),
                OutlinedButton.icon(
                  onPressed: widget.onDownload,
                  icon: const Icon(Icons.download_outlined, size: 14),
                  label: const Text('Download'),
                ),
              ],
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }

  Widget _buildVideoArea() {
    final c = _controller;

    // Still loading
    if (c == null && !_initFailed) {
      return Container(
        height: 170,
        color: widget.mainBg,
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: widget.textMuted,
            ),
          ),
        ),
      );
    }

    // Init failed -- show static placeholder
    if (_initFailed || c == null) {
      return GestureDetector(
        onTap: widget.onOpen,
        child: Container(
          height: 170,
          color: widget.mainBg,
          child: Center(
            child: Icon(
              Icons.play_circle_outline,
              size: 44,
              color: widget.textMuted,
            ),
          ),
        ),
      );
    }

    // Initialised -- show player with controls
    return GestureDetector(
      onTap: _togglePlayPause,
      child: Stack(
        alignment: Alignment.center,
        children: [
          AspectRatio(
            aspectRatio: c.value.aspectRatio.clamp(0.5, 3.0),
            child: VideoPlayer(c),
          ),
          if (!c.value.isPlaying)
            Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.5),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.play_arrow,
                size: 32,
                color: Colors.white,
              ),
            ),
        ],
      ),
    );
  }
}
