import 'dart:async';

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_cache_manager/flutter_cache_manager.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart' show PhotoManager;

import '../models/chat_message.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/download_helper.dart';
import '../utils/clipboard_image_helper.dart' show writeImageToClipboard;
import '../utils/time_utils.dart';
import 'avatar_utils.dart' show buildAvatar, avatarColor;
import 'message/media_content.dart';
import 'message/message_status_icon.dart';
import 'message/reaction_bar.dart';
import 'message/reply_quote.dart';
import 'message/link_preview_card.dart';
import 'message/rich_text_content.dart';

/// Common emojis for the reaction picker.
const reactionEmojis = ['👍', '❤️', '😂', '😮', '😢', '🔥', '👎', '🎉'];

/// True on Android/iOS (native, not web).
bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

/// Bounded cache manager for chat images to prevent unbounded disk usage.
final chatImageCacheManager = CacheManager(
  Config(
    'chatImages',
    maxNrOfCacheObjects: 200,
    stalePeriod: const Duration(days: 30),
  ),
);

class MessageItem extends StatefulWidget {
  final ChatMessage message;
  final bool showHeader;
  final bool isLastInGroup;
  final String myUserId;
  final void Function(ChatMessage message, Offset globalPosition)?
  onReactionTap;
  final void Function(ChatMessage message, String emoji)? onReactionSelect;

  /// Called when user taps "More emojis…" in the mobile action sheet
  /// to open the full Unicode emoji picker.
  final void Function(ChatMessage message)? onMoreReactions;
  final void Function(ChatMessage message)? onDelete;
  final void Function(ChatMessage message)? onEdit;
  final void Function(ChatMessage message)? onReply;
  final void Function(ChatMessage message)? onViewThread;
  final void Function(String userId)? onAvatarTap;
  final void Function(ChatMessage message)? onPin;
  final void Function(ChatMessage message)? onUnpin;
  final void Function(ChatMessage message)? onRetry;
  final void Function(ChatMessage message)? onSave;
  final void Function(ChatMessage message)? onUnsave;
  final void Function(ChatMessage message)? onForward;
  final void Function(String replyToId)? onTapReplyQuote;

  /// Called when the tiny lock icon on a received message is tapped.
  /// When null, the lock icon is non-interactive.
  final void Function(ChatMessage message)? onVerifyIdentity;

  /// Whether this message is currently bookmarked.
  final bool isSaved;

  /// Server URL for resolving relative image paths.
  final String? serverUrl;

  /// Auth token for authenticated image requests.
  final String? authToken;

  /// Short-lived media ticket for web image auth (avoids JWT in URLs).
  final String? mediaTicket;

  /// Avatar URL path for the message sender (relative, e.g. /api/users/.../avatar).
  final String? senderAvatarUrl;

  /// When true, uses Discord-style compact layout (all left-aligned, colored usernames).
  final bool compactLayout;

  /// Called when an image in this message is tapped, with the resolved URL.
  /// When provided, the gallery viewer in the parent is opened instead of the
  /// single-image dialog inside [MediaContent] / [_showImageViewer].
  final void Function(String resolvedUrl)? onImageTap;

  const MessageItem({
    super.key,
    required this.message,
    required this.showHeader,
    required this.isLastInGroup,
    required this.myUserId,
    this.onReactionTap,
    this.onReactionSelect,
    this.onMoreReactions,
    this.onDelete,
    this.onEdit,
    this.onReply,
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
    this.isSaved = false,
    this.serverUrl,
    this.authToken,
    this.mediaTicket,
    this.senderAvatarUrl,
    this.compactLayout = false,
    this.onImageTap,
  });

  @override
  State<MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<MessageItem>
    with SingleTickerProviderStateMixin {
  bool _isHovered = false;
  double _swipeDx = 0;
  bool _swipeTriggered = false;
  Timer? _expireTimer;
  late final AnimationController _swipeAnimController;

  @override
  void initState() {
    super.initState();
    _swipeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    _scheduleExpireTimer();
  }

  @override
  void didUpdateWidget(MessageItem oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.message.expiresAt != widget.message.expiresAt) {
      _expireTimer?.cancel();
      _scheduleExpireTimer();
    }
  }

  @override
  void dispose() {
    _swipeAnimController.dispose();
    _expireTimer?.cancel();
    super.dispose();
  }

  /// Animate _swipeDx back to 0 with an ease-out spring-back over 200 ms.
  void _startSpringBack() {
    final startDx = _swipeDx;
    if (startDx == 0) return;
    final animation = Tween<double>(begin: startDx, end: 0).animate(
      CurvedAnimation(parent: _swipeAnimController, curve: Curves.easeOut),
    );
    animation.addListener(() {
      if (mounted) setState(() => _swipeDx = animation.value);
    });
    _swipeAnimController.forward(from: 0);
  }

  void _scheduleExpireTimer() {
    final expiresAt = widget.message.expiresAt;
    if (expiresAt == null) return;
    final remaining = expiresAt.difference(DateTime.now().toUtc());
    if (remaining.isNegative) return;
    // Tick every second while less than 2 minutes remain; else every minute.
    final interval = remaining.inMinutes < 2
        ? const Duration(seconds: 1)
        : const Duration(minutes: 1);
    _expireTimer = Timer.periodic(interval, (_) {
      if (!mounted) return;
      setState(() {});
      final left = expiresAt.difference(DateTime.now().toUtc());
      if (left.isNegative) {
        _expireTimer?.cancel();
      } else if (left.inMinutes >= 2 && interval.inSeconds == 1) {
        // Slow down to per-minute once we're >= 2 minutes away.
        _expireTimer?.cancel();
        _scheduleExpireTimer();
      }
    });
  }

  String _formatTimeLeft(DateTime expiresAt) {
    final left = expiresAt.difference(DateTime.now().toUtc());
    if (left.isNegative) return 'expiring';
    if (left.inSeconds < 60) return '${left.inSeconds}s';
    if (left.inMinutes < 60) return '${left.inMinutes}m';
    if (left.inHours < 24) return '${left.inHours}h';
    return '${left.inDays}d';
  }

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
    mediaTicket: widget.mediaTicket,
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

  /// Fetch image bytes from the server and copy them to the system clipboard.
  Future<void> _copyImageToClipboard(String rawUrl) async {
    final url = _resolveUrl(rawUrl);
    try {
      final response = await http.get(Uri.parse(url), headers: _mediaHeaders());
      if (!mounted) return;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        ToastService.show(
          context,
          'Failed to copy image',
          type: ToastType.error,
        );
        return;
      }

      final contentType = response.headers['content-type'] ?? 'image/png';
      final success = await writeImageToClipboard(
        response.bodyBytes,
        contentType,
      );
      if (!mounted) return;

      if (success) {
        ToastService.show(context, 'Image copied', type: ToastType.success);
      } else {
        // Fallback: copy the URL if image clipboard write not supported
        Clipboard.setData(ClipboardData(text: url));
        ToastService.show(
          context,
          'Image copy not supported, link copied',
          type: ToastType.info,
        );
      }
    } catch (_) {
      if (!mounted) return;
      ToastService.show(context, 'Failed to copy image', type: ToastType.error);
    }
  }

  /// Fetch image bytes from the server and save them to the device gallery.
  /// Used on mobile platforms where clipboard image write is not supported.
  Future<void> _saveImageToGallery(String rawUrl) async {
    final url = _resolveUrl(rawUrl);
    try {
      final response = await http.get(Uri.parse(url), headers: _mediaHeaders());
      if (!mounted) return;
      if (response.statusCode < 200 || response.statusCode >= 300) {
        ToastService.show(
          context,
          'Failed to download image',
          type: ToastType.error,
        );
        return;
      }

      final bytes = Uint8List.fromList(response.bodyBytes);
      final filename =
          Uri.tryParse(url)?.pathSegments.lastOrNull ?? 'image.png';
      await PhotoManager.editor.saveImage(bytes, filename: filename);
      if (!mounted) return;
      ToastService.show(
        context,
        'Image saved to gallery',
        type: ToastType.success,
      );
    } catch (_) {
      if (!mounted) return;
      ToastService.show(context, 'Failed to save image', type: ToastType.error);
    }
  }

  /// On mobile, save image to gallery. On desktop, copy to clipboard.
  Future<void> _handleImageAction(String mediaUrl) async {
    if (_isMobilePlatform) {
      await _saveImageToGallery(mediaUrl);
    } else {
      await _copyImageToClipboard(mediaUrl);
    }
  }

  /// Returns true if the media message contains an image (not video/file).
  bool _isImageMedia(String content, String mediaUrl) {
    if (content.trimLeft().startsWith('[img:')) return true;
    if (isImageUrl(mediaUrl)) return true;
    // API media URLs without extension -- check content-type prefix
    final lower = mediaUrl.toLowerCase();
    if (lower.contains('/api/media/') &&
        !content.startsWith('[video:') &&
        !content.startsWith('[file:')) {
      return true;
    }
    return false;
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
                _buildQuickReactionRow(sheetContext, msg),
                Divider(height: 1, color: context.border),
                ..._buildActionTiles(
                  sheetContext: sheetContext,
                  msg: msg,
                  isMine: isMine,
                  mediaUrl: mediaUrl,
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  /// Quick reaction emoji row for the mobile action sheet.
  Widget _buildQuickReactionRow(BuildContext sheetContext, ChatMessage msg) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: Row(
        children: [
          for (final emoji in reactionEmojis) ...[
            Builder(
              builder: (_) {
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
                      style: const TextStyle(
                        fontSize: 24,
                        decoration: TextDecoration.none,
                      ),
                    ),
                  ),
                );
              },
            ),
            const SizedBox(width: 4),
          ],
          Semantics(
            button: true,
            label: 'More emojis',
            child: GestureDetector(
              onTap: () {
                Navigator.pop(sheetContext);
                widget.onMoreReactions?.call(msg);
              },
              child: Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(8),
                ),
                alignment: Alignment.center,
                child: Icon(
                  Icons.add_reaction_outlined,
                  size: 24,
                  color: context.accent,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Contextual action tiles for the mobile action sheet.
  List<Widget> _buildActionTiles({
    required BuildContext sheetContext,
    required ChatMessage msg,
    required bool isMine,
    required String? mediaUrl,
  }) {
    final isImage = mediaUrl != null && _isImageMedia(msg.content, mediaUrl);
    return [
      if (widget.onReply != null)
        _actionTile(
          sheetContext: sheetContext,
          icon: Icons.reply_outlined,
          label: 'Reply',
          onTap: () => widget.onReply?.call(msg),
        ),
      if (msg.replyCount > 0 && widget.onViewThread != null)
        _actionTile(
          sheetContext: sheetContext,
          icon: Icons.forum_outlined,
          label:
              'View ${msg.replyCount == 1 ? '1 reply' : '${msg.replyCount} replies'}',
          onTap: () => widget.onViewThread?.call(msg),
        ),
      _actionTile(
        sheetContext: sheetContext,
        icon: Icons.forward_outlined,
        label: 'Forward',
        onTap: () => widget.onForward?.call(msg),
      ),
      if (isImage)
        _actionTile(
          sheetContext: sheetContext,
          icon: _isMobilePlatform
              ? Icons.save_alt_outlined
              : Icons.image_outlined,
          label: _isMobilePlatform ? 'Save image' : 'Copy image',
          onTap: () => _handleImageAction(mediaUrl),
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
      if (!widget.isSaved && widget.onSave != null)
        _actionTile(
          sheetContext: sheetContext,
          icon: Icons.bookmark_border_outlined,
          label: 'Save',
          onTap: () => widget.onSave?.call(msg),
        ),
      if (widget.isSaved && widget.onUnsave != null)
        _actionTile(
          sheetContext: sheetContext,
          icon: Icons.bookmark_remove_outlined,
          label: 'Unsave',
          onTap: () => widget.onUnsave?.call(msg),
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
      if (widget.onDelete != null)
        _actionTile(
          sheetContext: sheetContext,
          icon: Icons.delete_outlined,
          label: 'Delete',
          color: isMine ? EchoTheme.danger : null,
          onTap: () => widget.onDelete?.call(msg),
        ),
    ];
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
      barrierColor: Theme.of(context).shadowColor.withValues(alpha: 0.9),
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
                    cacheManager: chatImageCacheManager,
                    fit: BoxFit.contain,
                    placeholder: (_, _) => SizedBox(
                      width: 320,
                      height: 240,
                      child: Center(
                        child: CircularProgressIndicator(
                          color: Theme.of(context).colorScheme.onPrimary,
                        ),
                      ),
                    ),
                    errorWidget: (_, _, _) => Center(
                      child: Icon(
                        Icons.broken_image_outlined,
                        color: Theme.of(
                          context,
                        ).colorScheme.onPrimary.withValues(alpha: 0.54),
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
                    color: Theme.of(context).colorScheme.onPrimary,
                    tooltip: 'Download',
                    onPressed: () => _downloadMedia(imageUrl),
                  ),
                  IconButton(
                    icon: const Icon(Icons.close),
                    color: Theme.of(context).colorScheme.onPrimary,
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
    final isImage = mediaUrl != null && _isImageMedia(msg.content, mediaUrl);
    return Container(
      decoration: BoxDecoration(
        color: context.surface.withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: context.border, width: 1),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
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
          // Overflow menu: copy, pin, edit, delete
          _buildOverflowMenu(msg, isMine, mediaUrl: mediaUrl, isImage: isImage),
        ],
      ),
    );
  }

  Widget _buildOverflowMenu(
    ChatMessage msg,
    bool isMine, {
    String? mediaUrl,
    bool isImage = false,
  }) {
    return Semantics(
      label: 'More actions',
      button: true,
      child: Tooltip(
        message: 'More',
        child: PopupMenuButton<String>(
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          icon: Opacity(
            opacity: 0.75,
            child: Icon(
              Icons.more_horiz,
              size: 14,
              color: context.textSecondary,
            ),
          ),
          onSelected: (value) {
            switch (value) {
              case 'copy':
                final copyText = mediaUrl != null
                    ? _resolveUrl(mediaUrl)
                    : msg.content;
                Clipboard.setData(ClipboardData(text: copyText));
                ToastService.show(
                  context,
                  mediaUrl != null ? 'Link copied' : 'Copied to clipboard',
                  type: ToastType.success,
                );
              case 'copy_image':
                _handleImageAction(mediaUrl!);
              case 'download':
                _downloadMedia(mediaUrl!);
              case 'pin':
                widget.onPin?.call(msg);
              case 'unpin':
                widget.onUnpin?.call(msg);
              case 'save':
                widget.onSave?.call(msg);
              case 'unsave':
                widget.onUnsave?.call(msg);
              case 'forward':
                widget.onForward?.call(msg);
              case 'edit':
                widget.onEdit?.call(msg);
              case 'delete':
                widget.onDelete?.call(msg);
            }
          },
          itemBuilder: (_) => [
            PopupMenuItem(
              value: 'copy',
              child: Row(
                children: [
                  const Icon(Icons.copy_outlined, size: 16),
                  const SizedBox(width: 8),
                  Text(mediaUrl != null ? 'Copy link' : 'Copy'),
                ],
              ),
            ),
            if (isImage)
              PopupMenuItem(
                value: 'copy_image',
                child: Row(
                  children: [
                    Icon(
                      _isMobilePlatform
                          ? Icons.save_alt_outlined
                          : Icons.image_outlined,
                      size: 16,
                    ),
                    const SizedBox(width: 8),
                    Text(_isMobilePlatform ? 'Save image' : 'Copy image'),
                  ],
                ),
              ),
            if (mediaUrl != null)
              const PopupMenuItem(
                value: 'download',
                child: Row(
                  children: [
                    Icon(Icons.download_outlined, size: 16),
                    SizedBox(width: 8),
                    Text('Download'),
                  ],
                ),
              ),
            if (msg.pinnedAt == null && widget.onPin != null)
              const PopupMenuItem(
                value: 'pin',
                child: Row(
                  children: [
                    Icon(Icons.push_pin_outlined, size: 16),
                    SizedBox(width: 8),
                    Text('Pin'),
                  ],
                ),
              ),
            if (msg.pinnedAt != null && widget.onUnpin != null)
              const PopupMenuItem(
                value: 'unpin',
                child: Row(
                  children: [
                    Icon(Icons.push_pin, size: 16),
                    SizedBox(width: 8),
                    Text('Unpin'),
                  ],
                ),
              ),
            if (!widget.isSaved && widget.onSave != null)
              const PopupMenuItem(
                value: 'save',
                child: Row(
                  children: [
                    Icon(Icons.bookmark_border_outlined, size: 16),
                    SizedBox(width: 8),
                    Text('Save'),
                  ],
                ),
              ),
            if (widget.isSaved && widget.onUnsave != null)
              const PopupMenuItem(
                value: 'unsave',
                child: Row(
                  children: [
                    Icon(Icons.bookmark_remove_outlined, size: 16),
                    SizedBox(width: 8),
                    Text('Unsave'),
                  ],
                ),
              ),
            const PopupMenuItem(
              value: 'forward',
              child: Row(
                children: [
                  Icon(Icons.forward_outlined, size: 16),
                  SizedBox(width: 8),
                  Text('Forward'),
                ],
              ),
            ),
            if (isMine && widget.onEdit != null)
              const PopupMenuItem(
                value: 'edit',
                child: Row(
                  children: [
                    Icon(Icons.edit_outlined, size: 16),
                    SizedBox(width: 8),
                    Text('Edit'),
                  ],
                ),
              ),
            if (widget.onDelete != null)
              PopupMenuItem(
                value: 'delete',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_outlined,
                      size: 16,
                      color: isMine ? EchoTheme.danger : null,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Delete',
                      style: isMine
                          ? const TextStyle(color: EchoTheme.danger)
                          : null,
                    ),
                  ],
                ),
              ),
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
  ///
  /// In compact layout the sender name and timestamp share a single inline
  /// row ("Username 12:34 PM") to save vertical space. Everywhere else the
  /// name stands alone on its own line above the bubble.
  Widget _buildSenderNameLabel({
    required ChatMessage msg,
    required bool hasMedia,
  }) {
    final nameText = Text(
      msg.fromUsername,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w600,
        color: _getUserColor(msg.fromUserId),
      ),
    );

    final padding = EdgeInsets.only(bottom: 4, left: hasMedia ? 8 : 0);

    if (!widget.compactLayout) {
      return Padding(padding: padding, child: nameText);
    }

    return Padding(
      padding: padding,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.baseline,
        textBaseline: TextBaseline.alphabetic,
        children: [
          nameText,
          const SizedBox(width: 6),
          Text(
            formatMessageTimestamp(msg.timestamp),
            style: TextStyle(fontSize: 10, color: context.textMuted),
          ),
        ],
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
            Icon(Icons.lock_clock_outlined, size: 14, color: context.textMuted),
            const SizedBox(width: 4),
            Flexible(
              child: Text(
                'Secured message',
                style: TextStyle(
                  fontStyle: FontStyle.italic,
                  color: context.textMuted,
                  fontSize: 13,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          'Unable to decrypt this message.',
          style: TextStyle(color: context.textMuted, fontSize: 12),
        ),
      ],
    );
  }

  /// Build the retry/delete row shown below a failed outbound message.
  Widget _buildRetryRow({required ChatMessage msg}) {
    return Container(
      margin: const EdgeInsets.only(top: 4, right: 4),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: EchoTheme.danger.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: EchoTheme.danger.withValues(alpha: 0.3)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.end,
        children: [
          const Icon(Icons.error_rounded, size: 16, color: EchoTheme.danger),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              msg.content.contains('not have been delivered')
                  ? 'Message may not have been delivered'
                  : 'Failed to send',
              style: const TextStyle(
                fontSize: 12,
                color: EchoTheme.danger,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          if (widget.onRetry != null) ...[
            const SizedBox(width: 10),
            GestureDetector(
              onTap: () => widget.onRetry?.call(msg),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: context.accent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'Retry',
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          ],
          if (widget.onDelete != null) ...[
            const SizedBox(width: 6),
            GestureDetector(
              onTap: () => widget.onDelete?.call(msg),
              child: Text(
                'Delete',
                style: TextStyle(
                  fontSize: 12,
                  color: EchoTheme.danger.withValues(alpha: 0.8),
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
    if (isMine) return Theme.of(context).colorScheme.onPrimary;
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
        mediaTicket: widget.mediaTicket,
        onImageTap: widget.onImageTap,
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

    // Link preview for the first URL (skip attachment-only messages and
    // internal server links).
    Widget? linkPreview;
    if (!msg.content.startsWith('[img:') && !msg.content.startsWith('[file:')) {
      final urlMatch = urlRegex.firstMatch(msg.content);
      if (urlMatch != null) {
        final previewUrl = urlMatch.group(0)!;
        final serverHost = Uri.tryParse(widget.serverUrl ?? '')?.host;
        final previewHost = Uri.tryParse(previewUrl)?.host;
        if (serverHost == null ||
            previewHost == null ||
            previewHost != serverHost) {
          linkPreview = LinkPreviewCard(
            url: previewUrl,
            serverUrl: widget.serverUrl ?? '',
            token: widget.authToken ?? '',
          );
        }
      }
    }

    if (embeddedImages.isEmpty && linkPreview == null) return textWidget;
    if (embeddedImages.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [textWidget, linkPreview!],
      );
    }

    final headers = _mediaHeaders();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        textWidget,
        ?linkPreview,
        for (final imgUrl in embeddedImages) ...[
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(8),
            child: GestureDetector(
              onTap: () => widget.onImageTap != null
                  ? widget.onImageTap!(imgUrl)
                  : _showImageViewer(imageUrl: imgUrl),
              child: ConstrainedBox(
                constraints: const BoxConstraints(
                  maxWidth: 400,
                  maxHeight: 320,
                ),
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
                        cacheManager: chatImageCacheManager,
                        errorWidget: (_, _, _) => const SizedBox.shrink(),
                        // Reserve the expected image area while loading so
                        // the scroll position does not jump when the image
                        // finally decodes.
                        placeholder: (_, _) => Container(
                          height: 200,
                          width: 300,
                          color: context.surface,
                          alignment: Alignment.center,
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
            ),
          ),
        ],
      ],
    );
  }

  /// Build a small pinned indicator shown inside the bubble.
  Widget _buildPinnedIndicator({required bool isMine}) {
    return Semantics(
      label: 'Pinned message',
      child: Padding(
        padding: const EdgeInsets.only(bottom: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.push_pin,
              size: 11,
              color: isMine
                  ? Theme.of(
                      context,
                    ).colorScheme.onPrimary.withValues(alpha: 0.7)
                  : context.accent,
            ),
            const SizedBox(width: 3),
            Text(
              'Pinned',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w500,
                color: isMine
                    ? Theme.of(
                        context,
                      ).colorScheme.onPrimary.withValues(alpha: 0.7)
                    : context.accent,
              ),
            ),
          ],
        ),
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
          onTap: msg.replyToId != null && widget.onTapReplyQuote != null
              ? () => widget.onTapReplyQuote!(msg.replyToId!)
              : null,
        ),
      _buildBubbleContent(
        msg: msg,
        isMine: isMine,
        isFailed: isFailed,
        hasMedia: hasMedia,
      ),
      if (msg.editedAt != null && !widget.isLastInGroup)
        Padding(
          padding: const EdgeInsets.only(top: 2),
          child: Text(
            '(edited)',
            style: TextStyle(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: context.textMuted,
            ),
          ),
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
    final EdgeInsets padding;
    if (hasMedia) {
      padding = const EdgeInsets.all(4);
    } else if (widget.compactLayout) {
      padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4);
    } else {
      padding = const EdgeInsets.symmetric(horizontal: 12, vertical: 8);
    }

    return Container(
      constraints: const BoxConstraints(maxWidth: 520),
      padding: padding,
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

  /// Build the tiny green lock icon shown next to the timestamp on encrypted
  /// messages. Received-message lock is tappable to open the safety-number
  /// verification screen; my own lock icon is non-interactive.
  Widget _buildLockIcon({required ChatMessage msg, required bool isMine}) {
    const icon = Padding(
      padding: EdgeInsets.only(left: 3),
      child: Icon(Icons.lock, size: 10, color: EchoTheme.online),
    );

    if (isMine || widget.onVerifyIdentity == null) {
      return icon;
    }

    return Tooltip(
      message: 'End-to-end encrypted. Tap to verify.',
      child: InkWell(
        onTap: () => widget.onVerifyIdentity!(msg),
        borderRadius: BorderRadius.circular(6),
        child: icon,
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
          if (msg.isEncrypted) _buildLockIcon(msg: msg, isMine: isMine),
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
          if (msg.expiresAt != null)
            Padding(
              padding: const EdgeInsets.only(left: 4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.timer_outlined,
                    size: 10,
                    color: context.textMuted,
                  ),
                  const SizedBox(width: 2),
                  Text(
                    _formatTimeLeft(msg.expiresAt!),
                    style: TextStyle(fontSize: 10, color: context.textMuted),
                  ),
                ],
              ),
            ),
          if (isMine) MessageStatusIcon(status: msg.status),
        ],
      ),
    );
  }

  Widget _buildReplyCountBadge({
    required ChatMessage msg,
    required bool isMine,
  }) {
    final count = msg.replyCount;
    final label = count == 1 ? '1 reply' : '$count replies';
    return Padding(
      padding: EdgeInsets.only(top: 4, left: isMine ? 0 : 36),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: Semantics(
          label: 'View $label',
          button: true,
          child: Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: BorderRadius.circular(12),
              onTap: () => widget.onViewThread?.call(msg),
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                decoration: BoxDecoration(
                  color: context.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.forum_outlined, size: 12, color: context.accent),
                    const SizedBox(width: 4),
                    Text(
                      label,
                      style: TextStyle(
                        fontSize: 12,
                        color: context.accent,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Inline timestamp that appears on hover/tap for messages that are not the
  /// last in their group (those already always show the timestamp).
  Widget _buildHoverTimestamp({
    required ChatMessage msg,
    required bool isMine,
  }) {
    return AnimatedOpacity(
      opacity: _isHovered ? 1.0 : 0.0,
      duration: const Duration(milliseconds: 140),
      child: Padding(
        padding: EdgeInsets.only(top: 2, left: isMine ? 0 : 36),
        child: Text(
          msg.editedAt != null
              ? '${formatMessageTimestamp(msg.timestamp)} (edited)'
              : formatMessageTimestamp(msg.timestamp),
          style: TextStyle(fontSize: 11, color: context.textMuted),
        ),
      ),
    );
  }

  /// Build the hover-actions overlay that appears above the bubble.
  ///
  /// When not hovered the overlay is wrapped in [ExcludeSemantics] so its
  /// invisible buttons don't appear in the accessibility tree.  This prevents
  /// Playwright (and screen-readers) from seeing phantom focusable elements
  /// that sit on top of the text-input area after the mouse leaves.
  Widget _buildHoverOverlay({
    required ChatMessage msg,
    required bool isMine,
    required String? mediaUrl,
  }) {
    return Positioned(
      top: -28,
      left: isMine ? null : 36,
      right: isMine ? 0 : 8,
      child: ExcludeSemantics(
        excluding: !_isHovered,
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
      ),
    );
  }

  /// Build the main message row containing the avatar and bubble.
  List<Widget> _buildMessageRowChildren({
    required ChatMessage msg,
    required bool isMine,
    required Widget bubbleWithReactions,
  }) {
    final needsAvatarColumn = !isMine || widget.compactLayout;
    if (!needsAvatarColumn) {
      return [Flexible(child: bubbleWithReactions)];
    }

    // Compact follow-up: reserve the avatar column with whitespace instead
    // of re-drawing the avatar.  28 (avatar) + 8 (gap) = 36.
    if (widget.compactLayout && !widget.showHeader) {
      return [const SizedBox(width: 36), Flexible(child: bubbleWithReactions)];
    }

    return [
      _buildAvatarSection(msg: msg),
      const SizedBox(width: 8),
      Flexible(child: bubbleWithReactions),
    ];
  }

  /// Build the system event pill (centered, borderless).
  Widget _buildSystemEventPill(ChatMessage msg) {
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

  /// Whether the current platform supports touch-based swipe gestures.
  static bool get _isMobileTouch =>
      !kIsWeb &&
      (defaultTargetPlatform == TargetPlatform.android ||
          defaultTargetPlatform == TargetPlatform.iOS);

  /// Wrap [messageWidget] with swipe-to-reply gesture handlers on mobile.
  Widget _buildSwipeToReplyWrapper({
    required bool canSwipe,
    required ChatMessage msg,
    required Widget messageWidget,
  }) {
    return Stack(
      children: [
        if (canSwipe && _swipeDx > 0)
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
        Transform.translate(offset: Offset(_swipeDx, 0), child: messageWidget),
      ],
    );
  }

  /// Handle long-press: show mobile action sheet or reaction picker.
  void _handleLongPress(
    LongPressStartDetails details,
    ChatMessage msg,
    bool isMine,
    String? mediaUrl,
    bool hasReactions,
  ) {
    if (Responsive.isMobile(context)) {
      _showMobileActionSheet(context, msg, isMine, mediaUrl);
    } else if (!hasReactions) {
      widget.onReactionTap?.call(msg, details.globalPosition);
    }
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isMine = msg.isMine;
    final isFailed = msg.status == MessageStatus.failed;
    final isSending = msg.status == MessageStatus.sending;

    if (msg.isSystemEvent) return _buildSystemEventPill(msg);

    final mediaUrl = extractMediaUrl(msg.content);
    final hasMedia = mediaUrl != null;

    final hasReactions = msg.reactions.isNotEmpty;
    final reactionPill = ReactionBar(
      reactions: msg.reactions,
      currentUserId: widget.myUserId,
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
    final canSwipeToReply =
        _isMobileTouch && widget.onReply != null && !msg.isSystemEvent;

    // In compact mode, the gap between bubbles from the same sender is
    // reduced so the conversation reads as a single stream.
    final double topPad;
    if (widget.showHeader) {
      topPad = widget.compactLayout ? 4 : 8;
    } else {
      topPad = widget.compactLayout ? 1 : 2;
    }

    final messageWidget = Container(
      padding: EdgeInsets.only(
        left: 24,
        right: 24,
        top: topPad,
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
              if (msg.replyCount > 0)
                _buildReplyCountBadge(msg: msg, isMine: isMine),
              if (widget.isLastInGroup)
                _buildTimestampRow(msg: msg, isMine: isMine)
              else
                _buildHoverTimestamp(msg: msg, isMine: isMine),
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
          button: true,
          child: GestureDetector(
            onLongPressStart: (details) =>
                _handleLongPress(details, msg, isMine, mediaUrl, hasReactions),
            onHorizontalDragUpdate: canSwipeToReply
                ? (details) {
                    // Guard against iOS system back gesture zone (left 30px).
                    if (details.globalPosition.dx < 30) return;
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
                    if (_swipeTriggered) widget.onReply?.call(msg);
                    _swipeTriggered = false;
                    _startSpringBack();
                  }
                : null,
            onHorizontalDragCancel: canSwipeToReply
                ? () {
                    _swipeTriggered = false;
                    _startSpringBack();
                  }
                : null,
            child: _buildSwipeToReplyWrapper(
              canSwipe: canSwipeToReply,
              msg: msg,
              messageWidget: messageWidget,
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
    return Semantics(
      label: tooltip,
      button: true,
      child: Tooltip(
        message: tooltip,
        child: ConstrainedBox(
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
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
        ),
      ),
    );
  }
}
