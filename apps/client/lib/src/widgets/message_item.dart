import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;

import '../models/chat_message.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/download_helper.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart' show buildAvatar, avatarColor;
import 'message/media_content.dart';
import 'message/message_status_icon.dart';
import 'message/reaction_bar.dart';
import 'message/reply_quote.dart';
import 'message/rich_text_content.dart';

/// Common emojis for the reaction picker.
const reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👎', '🎉'];

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
  final void Function(ChatMessage message)? onRetry;

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
    this.onRetry,
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
  double _swipeDx = 0;
  bool _swipeTriggered = false;

  /// Consistent color for a username -- matches sidebar avatar colors.
  Color _getUserColor(String userId) {
    final name = widget.message.fromUsername;
    return avatarColor(name);
  }

  Map<String, String> _mediaHeaders() =>
      mediaHeaders(authToken: widget.authToken);

  String _resolveUrl(String url) => resolveMediaUrl(
    url,
    serverUrl: widget.serverUrl,
    authToken: widget.authToken,
  );

  Future<void> _downloadMedia(String rawUrl) async {
    final url = _resolveUrl(rawUrl);
    try {
      final response = await http.get(Uri.parse(url), headers: _mediaHeaders());
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
      final filename =
          Uri.tryParse(url)?.pathSegments.lastOrNull ?? 'media.bin';
      final downloaded = await saveBytesAsFile(
        fileName: filename,
        bytes: response.bodyBytes,
        mimeType: contentType,
      );

      if (!mounted) return;
      if (downloaded) {
        ToastService.show(context, 'Download started', type: ToastType.success);
        return;
      }

      await Clipboard.setData(ClipboardData(text: url));
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

  /// Shows a bottom action sheet for mobile users (replaces hover actions).
  void _showMobileActionSheet(
    BuildContext context,
    ChatMessage msg,
    bool isMine,
    String? mediaUrl,
  ) {
    HapticFeedback.mediumImpact();
    showModalBottomSheet<void>(
      context: context,
      backgroundColor: Colors.transparent,
      isScrollControlled: true,
      builder: (sheetContext) {
        return SafeArea(
          child: Container(
            margin: const EdgeInsets.fromLTRB(8, 0, 8, 8),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                // Handle
                Container(
                  width: 40,
                  height: 4,
                  margin: const EdgeInsets.only(top: 10, bottom: 4),
                  decoration: BoxDecoration(
                    color: context.textMuted.withValues(alpha: 0.4),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
                // Quick reaction row
                Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                    children: reactionEmojis.map((emoji) {
                      final alreadyReacted = msg.reactions.any(
                        (r) => r.emoji == emoji && r.userId == widget.myUserId,
                      );
                      return GestureDetector(
                        onTap: () {
                          Navigator.pop(sheetContext);
                          widget.onReactionSelect?.call(msg, emoji);
                        },
                        child: Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: alreadyReacted
                                ? context.accent.withValues(alpha: 0.2)
                                : null,
                            borderRadius: BorderRadius.circular(8),
                            border: alreadyReacted
                                ? Border.all(color: context.accent, width: 2)
                                : null,
                          ),
                          alignment: Alignment.center,
                          child: Text(
                            emoji,
                            style: const TextStyle(fontSize: 24),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
                Divider(height: 1, color: context.border),
                // Action list
                if (widget.onReply != null)
                  _actionTile(
                    sheetContext: sheetContext,
                    icon: Icons.reply_outlined,
                    label: 'Reply',
                    onTap: () => widget.onReply?.call(msg),
                  ),
                _actionTile(
                  sheetContext: sheetContext,
                  icon: Icons.copy_outlined,
                  label: mediaUrl != null ? 'Copy link' : 'Copy text',
                  onTap: () {
                    final copyText = mediaUrl != null
                        ? _resolveUrl(mediaUrl)
                        : msg.content;
                    Clipboard.setData(ClipboardData(text: copyText));
                    ToastService.show(
                      context,
                      'Copied to clipboard',
                      type: ToastType.success,
                    );
                  },
                ),
                if (mediaUrl != null)
                  _actionTile(
                    sheetContext: sheetContext,
                    icon: Icons.download_outlined,
                    label: 'Download',
                    onTap: () => _downloadMedia(mediaUrl),
                  ),
                if (isMine && widget.onEdit != null)
                  _actionTile(
                    sheetContext: sheetContext,
                    icon: Icons.edit_outlined,
                    label: 'Edit',
                    onTap: () => widget.onEdit?.call(msg),
                  ),
                if (msg.pinnedAt == null && widget.onPin != null)
                  _actionTile(
                    sheetContext: sheetContext,
                    icon: Icons.push_pin_outlined,
                    label: 'Pin',
                    onTap: () => widget.onPin?.call(msg),
                  ),
                if (msg.pinnedAt != null && widget.onUnpin != null)
                  _actionTile(
                    sheetContext: sheetContext,
                    icon: Icons.push_pin,
                    label: 'Unpin',
                    onTap: () => widget.onUnpin?.call(msg),
                  ),
                if (isMine && widget.onDelete != null)
                  _actionTile(
                    sheetContext: sheetContext,
                    icon: Icons.delete_outlined,
                    label: 'Delete',
                    color: EchoTheme.danger,
                    onTap: () => widget.onDelete?.call(msg),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _actionTile({
    required BuildContext sheetContext,
    required IconData icon,
    required String label,
    required VoidCallback onTap,
    Color? color,
  }) {
    return InkWell(
      onTap: () {
        Navigator.pop(sheetContext);
        onTap();
      },
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
        child: Row(
          children: [
            Icon(icon, size: 20, color: color ?? context.textSecondary),
            const SizedBox(width: 14),
            Text(
              label,
              style: TextStyle(
                color: color ?? context.textPrimary,
                fontSize: 15,
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showImageViewer({required String imageUrl}) {
    final headers = _mediaHeaders();
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Colors.black.withValues(alpha: 0.9),
      builder: (dialogContext) {
        return Stack(
          children: [
            // Dismiss layer — covers entire screen. Tapping anywhere outside
            // the image closes the viewer.
            Positioned.fill(
              child: GestureDetector(
                onTap: () => Navigator.of(dialogContext).pop(),
                behavior: HitTestBehavior.opaque,
                child: const SizedBox.expand(),
              ),
            ),
            // Image content — centered, constrained, does NOT fill screen
            Center(
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: MediaQuery.of(dialogContext).size.width * 0.85,
                  maxHeight: MediaQuery.of(dialogContext).size.height * 0.85,
                ),
                child: InteractiveViewer(
                  minScale: 0.8,
                  maxScale: 4,
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
            // Action buttons
            Positioned(
              top: 16,
              right: 16,
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
        );
      },
    );
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
                  ? _resolveUrl(mediaUrl)
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

  /// Build a friendly decryption failure message with a recovery action.
  Widget _buildDecryptionFailure() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(
              Icons.lock_clock_outlined,
              size: 14,
              color: EchoTheme.danger,
            ),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Secured message',
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
        Text(
          'This message will be readable when your connection syncs.',
          style: TextStyle(color: context.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  /// Build the retry/delete row shown below a failed outbound message.
  Widget _buildRetryRow({required ChatMessage msg}) {
    return Padding(
      padding: const EdgeInsets.only(top: 2, right: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          Icon(
            Icons.error_outline,
            size: 11,
            color: EchoTheme.danger.withValues(alpha: 0.7),
          ),
          const SizedBox(width: 4),
          Text(
            'Failed to send',
            style: TextStyle(fontSize: 11, color: context.textMuted),
          ),
          if (widget.onRetry != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => widget.onRetry?.call(msg),
              child: Text(
                'Retry',
                style: TextStyle(
                  fontSize: 11,
                  color: context.accent,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
          if (widget.onDelete != null) ...[
            const SizedBox(width: 8),
            GestureDetector(
              onTap: () => widget.onDelete?.call(msg),
              child: Text(
                'Delete',
                style: TextStyle(
                  fontSize: 11,
                  color: EchoTheme.danger,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ],
        ],
      ),
    );
  }

  /// Resolve text color for message content.
  Color _contentTextColor({required bool isMine, required bool isFailed}) {
    if (isFailed) return EchoTheme.danger;
    if (isMine) return Colors.white;
    return context.textPrimary;
  }

  /// Select and build the primary message content (media, decrypt error, or
  /// rich text). When the text contains embedded image URLs mixed with
  /// regular text, image previews are appended below the text.
  Widget _buildBubbleContent({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required bool hasMedia,
  }) {
    if (hasMedia) {
      return MediaContent(
        content: msg.content,
        isMine: isMine,
        serverUrl: widget.serverUrl,
        authToken: widget.authToken,
      );
    }
    if (msg.content.startsWith('[Could not decrypt')) {
      return _buildDecryptionFailure();
    }

    final textColor = _contentTextColor(isMine: isMine, isFailed: isFailed);
    final textWidget = RichTextContent(
      text: msg.content,
      textColor: textColor,
      accentHoverColor: context.accentHover,
      textSecondaryColor: context.textSecondary,
    );

    final embeddedImages = extractEmbeddedImageUrls(msg.content);
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
              onTap: () => _showImageViewer(imageUrl: imgUrl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: imgUrl.endsWith('.gif')
                    ? Image.network(
                        imgUrl,
                        headers: _mediaHeaders(),
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
    required bool hasMedia,
  }) {
    return [
      if (msg.pinnedAt != null) _buildPinnedIndicator(isMine: isMine),
      if (widget.showHeader && (!isMine || widget.compactLayout))
        _buildSenderNameLabel(msg: msg, hasMedia: hasMedia),
      if (msg.replyToContent != null)
        ReplyQuote(
          replyToUsername: msg.replyToUsername,
          replyToContent: msg.replyToContent!,
          isMine: isMine,
        ),
      _buildBubbleContent(
        msg: msg,
        isMine: isMine,
        isFailed: isFailed,
        hasMedia: hasMedia,
      ),
    ];
  }

  /// Build the full message bubble container.
  Widget _buildBubble({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required bool hasMedia,
  }) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: hasMedia
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
          hasMedia: hasMedia,
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
          if (isMine) MessageStatusIcon(status: msg.status),
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
    final isSending = msg.status == MessageStatus.sending;

    // System events render as centered, borderless pills (like date separators)
    if (msg.isSystemEvent) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
        child: Center(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.border),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _systemEventIcon(msg.content),
                  size: 14,
                  color: context.textMuted,
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    msg.content,
                    style: TextStyle(
                      color: context.textMuted,
                      fontSize: 12,
                      fontStyle: FontStyle.italic,
                    ),
                    textAlign: TextAlign.center,
                  ),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final mediaUrl = extractMediaUrl(msg.content);
    final hasMedia = mediaUrl != null;

    final hasReactions = msg.reactions.isNotEmpty;
    final reactionPill = ReactionBar(
      reactions: msg.reactions,
      onTap: (pos) => widget.onReactionTap?.call(msg, pos),
    );

    final bubble = _buildBubble(
      msg: msg,
      isMine: isMine,
      isFailed: isFailed,
      hasMedia: hasMedia,
    );

    final bubbleWithReactions = _buildBubbleWithReactions(
      bubble: bubble,
      isMine: isMine,
      hasReactions: hasReactions,
      reactionPill: reactionPill,
    );

    final isAlignedEnd = isMine && !widget.compactLayout;
    final canSwipeToReply = widget.onReply != null && !msg.isSystemEvent;

    final messageWidget = Container(
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
              if (isFailed && isMine) _buildRetryRow(msg: msg),
            ],
          ),
          if (!hasReactions)
            _buildHoverOverlay(msg: msg, isMine: isMine, mediaUrl: mediaUrl),
        ],
      ),
    );

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: isSending ? 0.5 : 1.0,
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Semantics(
          label: 'Message from ${msg.fromUsername}. Long press for actions.',
          child: GestureDetector(
            onLongPressStart: (details) {
              final isMobile = MediaQuery.of(context).size.width < 600;
              if (isMobile) {
                _showMobileActionSheet(context, msg, isMine, mediaUrl);
              } else if (!hasReactions) {
                widget.onReactionTap?.call(msg, details.globalPosition);
              }
            },
            onHorizontalDragUpdate: canSwipeToReply
                ? (details) {
                    // Only allow rightward swipe (positive dx)
                    final newDx = (_swipeDx + details.delta.dx).clamp(
                      0.0,
                      72.0,
                    );
                    setState(() => _swipeDx = newDx);
                    if (!_swipeTriggered && newDx >= 60) {
                      _swipeTriggered = true;
                      HapticFeedback.lightImpact();
                    }
                  }
                : null,
            onHorizontalDragEnd: canSwipeToReply
                ? (_) {
                    if (_swipeTriggered) {
                      widget.onReply?.call(msg);
                    }
                    setState(() {
                      _swipeDx = 0;
                      _swipeTriggered = false;
                    });
                  }
                : null,
            onHorizontalDragCancel: canSwipeToReply
                ? () => setState(() {
                    _swipeDx = 0;
                    _swipeTriggered = false;
                  })
                : null,
            child: Stack(
              children: [
                // Reply icon revealed during swipe
                if (canSwipeToReply && _swipeDx > 0)
                  Positioned(
                    left: 8,
                    top: 0,
                    bottom: 0,
                    child: Align(
                      alignment: Alignment.centerLeft,
                      child: Opacity(
                        opacity: (_swipeDx / 60).clamp(0.0, 1.0),
                        child: Container(
                          width: 32,
                          height: 32,
                          decoration: BoxDecoration(
                            color: context.accent.withValues(alpha: 0.2),
                            shape: BoxShape.circle,
                          ),
                          child: Icon(
                            Icons.reply_rounded,
                            size: 16,
                            color: context.accent,
                          ),
                        ),
                      ),
                    ),
                  ),
                // Message content, shifted right during swipe
                Transform.translate(
                  offset: Offset(_swipeDx, 0),
                  child: messageWidget,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

IconData _systemEventIcon(String content) {
  final lower = content.toLowerCase();
  if (lower.contains('call')) {
    return Icons.call;
  }
  if (lower.contains('encryption') || lower.contains('key')) {
    return Icons.vpn_key;
  }
  if (lower.contains('joined') || lower.contains('left')) {
    return Icons.group;
  }
  return Icons.info_outline;
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
