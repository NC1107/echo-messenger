import 'dart:async';
import 'dart:math' as math;

import 'package:cached_network_image/cached_network_image.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:photo_manager/photo_manager.dart' show PhotoManager;

import '../models/chat_message.dart';
import '../providers/theme_provider.dart' show MessageLayout, UIDensity;
import '../services/clipboard_service.dart';
import '../services/message_cache.dart' show MessageCache;
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../utils/download_helper.dart';
import '../utils/clipboard_image_helper.dart' show writeImageToClipboard;
import '../utils/semantics_preview.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart' show buildAvatar, avatarColor;
import '../services/media_cache_service.dart';
import 'message/hover_action_button.dart';
import 'message/link_preview_card.dart';
import 'message/media_content.dart';
import 'message/message_status_icon.dart';
import 'message/message_indicators.dart';
import 'message/reaction_bar.dart';
import 'message/reply_count_badge.dart';
import 'message/reply_quote.dart';
import 'message/retry_row.dart';
import 'message/rich_text_content.dart';
import 'message/sender_name_label.dart';
import 'message/poll_widget.dart';
import 'message/system_event_pill.dart';
import 'message/youtube_embed.dart';
import 'context_menu/actions/message_actions_registry.dart';
import 'context_menu/echo_context_menu.dart';

/// Default 5-emoji quick-react set shared by mobile long-press and desktop
/// hover-action button. The "+" affordance to open the full picker is rendered
/// separately by each surface, matching the design canvas.
const reactionEmojis = ['👍', '❤️', '😂', '🔥', '🙏'];

const _forwardedPrefix = '[Forwarded] ';

/// True on Android/iOS (native, not web).
bool get _isMobilePlatform =>
    !kIsWeb &&
    (defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS);

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

  /// User-selected layout: `bubbles` (default WhatsApp-style L/R align), `compact`
  /// (Discord-style all-left with bubble bg), or `plain` (Slack-style all-left, no bg).
  final MessageLayout layout;

  /// User-selected density tier (Phase 2 follow-up).  Drives body
  /// fontSize / line-height, name + timestamp fontSize, and inter-
  /// message vertical padding — orthogonal to [layout], which still
  /// owns bubble shape, alignment, color, and the inline-vs-stacked
  /// header decision.
  final UIDensity density;

  /// True for any non-bubbles layout — they share alignment + spacing semantics.
  bool get compactLayout => layout != MessageLayout.bubbles;

  /// True for the no-background plain (Slack) layout.
  bool get _isPlain => layout == MessageLayout.plain;

  /// True for the Discord-style compact layout (avatars + transparent rows,
  /// distinct from [_isPlain] which is the Slack-style no-background layout).
  bool get _isCompact => layout == MessageLayout.compact;

  /// When true, messages whose content matches a decrypt-failure sentinel are
  /// hidden entirely (render as [SizedBox.shrink]). When false (the default)
  /// they show the lock-icon pill (#668). Controlled by the
  /// `chat.hide_undecryptable_messages` SharedPreferences key.
  final bool hideUndecryptable;

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
    this.layout = MessageLayout.bubbles,
    this.density = UIDensity.compact,
    this.hideUndecryptable = false,
    this.onImageTap,
  });

  @override
  State<MessageItem> createState() => _MessageItemState();
}

class _MessageItemState extends State<MessageItem>
    with SingleTickerProviderStateMixin {
  // ValueNotifier (not setState) so hover-driven rebuilds skip the bubble + embedded media (#834, closes #872).
  final _hoverNotifier = ValueNotifier<bool>(false);
  double _swipeDx = 0;
  bool _swipeTriggered = false;
  Timer? _expireTimer;
  late final AnimationController _swipeAnimController;
  Animation<double>? _swipeAnimation;
  late void Function() _swipeAnimListener;

  _HoverStyleSpec get _hoverStyle =>
      _HoverStyleSpec.forLayout(layout: widget.layout, context: context);

  @override
  void initState() {
    super.initState();
    _swipeAnimController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 200),
    );
    // Define listener once, reuse across animations
    _swipeAnimListener = () {
      if (mounted && _swipeAnimation != null) {
        setState(() => _swipeDx = _swipeAnimation!.value);
      }
    };
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
    _hoverNotifier.dispose();
    _expireTimer?.cancel();
    super.dispose();
  }

  /// Animate _swipeDx back to 0 with an ease-out spring-back over 200 ms.
  void _startSpringBack() {
    final startDx = _swipeDx;
    if (startDx == 0) return;

    // Remove old listener to prevent accumulation across multiple swipe cycles
    _swipeAnimation?.removeListener(_swipeAnimListener);

    _swipeAnimation = Tween<double>(begin: startDx, end: 0).animate(
      CurvedAnimation(parent: _swipeAnimController, curve: Curves.easeOut),
    );
    _swipeAnimation!.addListener(_swipeAnimListener);
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

  /// Avatar background color (contrast for the avatar's white initial glyph).
  Color _getAvatarColor(String userId) {
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

  void _showImageViewer({required String imageUrl}) {
    final headers = _mediaHeaders();
    showDialog<void>(
      context: context,
      barrierDismissible: true,
      barrierColor: Theme.of(context).shadowColor.withValues(alpha: 0.9),
      builder: (dialogContext) {
        return Stack(
          children: [
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
                  child: GestureDetector(
                    onTap: () => Navigator.of(dialogContext).pop(),
                    behavior: HitTestBehavior.opaque,
                    child: CachedNetworkImage(
                      imageUrl: imageUrl,
                      cacheKey: stableMediaCacheKey(imageUrl),
                      httpHeaders: headers,
                      cacheManager: chatMediaCacheManager,
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
    final style = _hoverStyle;
    return Container(
      // Clip the InkWell ripples on the 44x44 chips so they don't bleed
      // past the rounded card boundary into the adjacent message bubble.
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: style.background,
        borderRadius: BorderRadius.circular(style.containerRadius),
        border: Border.all(color: style.borderColor, width: style.borderWidth),
        boxShadow: style.shadow,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.onReply != null)
            Semantics(
              label: 'Reply to message',
              button: true,
              child: HoverActionButton(
                icon: Icons.reply_outlined,
                tooltip: 'Reply',
                iconSize: style.iconSize,
                iconOpacity: style.iconOpacity,
                iconColor: style.iconColor,
                cornerRadius: style.buttonRadius,
                onPressed: () => widget.onReply?.call(msg),
              ),
            ),
          if (widget.onForward != null)
            Semantics(
              label: 'Forward message',
              button: true,
              child: HoverActionButton(
                icon: Icons.forward_outlined,
                tooltip: 'Forward',
                iconSize: style.iconSize,
                iconOpacity: style.iconOpacity,
                iconColor: style.iconColor,
                cornerRadius: style.buttonRadius,
                onPressed: () => widget.onForward?.call(msg),
              ),
            ),
          // Overflow menu: copy, pin, edit, delete
          _buildOverflowMenu(
            msg,
            isMine,
            mediaUrl: mediaUrl,
            isImage: isImage,
            hoverStyle: style,
          ),
        ],
      ),
    );
  }

  /// Hover-bar "..." overflow affordance. Routes through the same
  /// [_openContextMenu] entrypoint as right-click and long-press —
  /// no parallel menu tree. Anchored to the button's bottom-left so
  /// the menu flips out below the bar exactly where the user clicked.
  Widget _buildOverflowMenu(
    ChatMessage msg,
    bool isMine, {
    String? mediaUrl,
    bool isImage = false,
    required _HoverStyleSpec hoverStyle,
  }) {
    final size = hoverStyle.buttonSize < 44 ? 44.0 : hoverStyle.buttonSize;
    return Semantics(
      label: 'More actions',
      button: true,
      child: Tooltip(
        message: 'More',
        child: Builder(
          builder: (btnContext) => InkWell(
            onTap: () {
              // Anchor menu at button's bottom-left.
              final box = btnContext.findRenderObject() as RenderBox?;
              final origin =
                  box?.localToGlobal(Offset(0, box.size.height)) ?? Offset.zero;
              _openContextMenu(origin, msg, isMine, mediaUrl);
            },
            borderRadius: BorderRadius.circular(6),
            child: SizedBox(
              width: size,
              height: size,
              child: Center(
                child: Opacity(
                  opacity: hoverStyle.iconOpacity,
                  child: Icon(
                    Icons.more_horiz,
                    size: hoverStyle.iconSize,
                    color: hoverStyle.iconColor,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Resolve the bubble background color based on message state.
  /// Plain (Slack) layout drops the bubble fill entirely (#564).
  // Locked rule: sent bubble = primary, recv bubble = surface — pinned in EchoColorExtension across all themes. Do not drift shades here.
  Color _bubbleColor({required bool isMine, required bool isFailed}) {
    if (isFailed) return EchoTheme.danger.withValues(alpha: 0.2);
    // Slice 5: compact (Discord) also drops the bubble fill — only the
    // legacy "bubbles" layout draws a coloured recv/sent background.
    if (widget._isPlain || widget._isCompact) return Colors.transparent;
    if (isMine) return context.sentBubble;
    return context.recvBubble;
  }

  /// Resolve the bubble border radius with iMessage stacked-pill cornering:
  /// inside a same-author run the inner-facing corners square to 4px while
  /// outer corners keep the full 14px radius, so a run of bubbles reads as
  /// one continuous stack rather than N separate pills. Plain mode squares
  /// off entirely (#564); compact layout drops the bubble fill so radius
  /// only matters on the original `bubbles` layout.
  BorderRadius _bubbleBorderRadius({required bool isMine}) {
    if (widget._isPlain) return BorderRadius.zero;
    final isRight = isMine && !widget.compactLayout;
    const full = Radius.circular(14);
    const tight = Radius.circular(4);
    final isFirst = widget.showHeader; // showHeader == first-in-group
    final isLast = widget.isLastInGroup;
    if (isRight) {
      // Bubble sits on the right edge; "inner" = the left-facing corners.
      return BorderRadius.only(
        topLeft: full,
        topRight: isFirst ? full : tight,
        bottomLeft: full,
        bottomRight: isLast ? full : tight,
      );
    }
    // Received bubble (left side); "inner" = the right-facing corners.
    return BorderRadius.only(
      topLeft: isFirst ? full : tight,
      topRight: full,
      bottomLeft: isLast ? full : tight,
      bottomRight: full,
    );
  }

  /// Returns true when [content] is a known decrypt-failure sentinel.
  ///
  /// Mirrors [MessageCache.failureSentinels] so system sentinels (prefixed
  /// `__system__:`) are never classified as decrypt failures (#663/#668).
  static bool _isDecryptFailure(String content) =>
      MessageCache.failureSentinels.contains(content) ||
      content.startsWith('[Could not decrypt');

  /// Build a clean lock-icon pill for messages that could not be decrypted.
  ///
  /// Replaces the old verbose text with a rounded pill containing a lock icon
  /// Resolve text color for message content.
  Color _contentTextColor({required bool isMine, required bool isFailed}) {
    if (isFailed) return EchoTheme.danger;
    // Plain/Compact drop the bubble fill (#564), so onPrimary (calibrated for accent bubble) reads as black-on-black on dark themes.
    if (widget._isPlain || widget._isCompact) return context.textPrimary;
    if (isMine) return Theme.of(context).colorScheme.onPrimary;
    return context.textPrimary;
  }

  /// Build the link-preview widget for [url], returning null when the URL
  /// belongs to the same server (avoid self-previews) or content starts with
  /// an attachment prefix.
  Widget? _buildLinkPreviewWidget(String displayContent) {
    if (displayContent.startsWith('[img:') ||
        displayContent.startsWith('[file:')) {
      return null;
    }
    final urlMatch = urlRegex.firstMatch(displayContent);
    if (urlMatch == null) return null;

    final previewUrl = urlMatch.group(0)!;
    final serverHost = Uri.tryParse(widget.serverUrl ?? '')?.host;
    final previewHost = Uri.tryParse(previewUrl)?.host;
    if (serverHost != null &&
        previewHost != null &&
        previewHost == serverHost) {
      return null;
    }
    final ytId = YouTubeEmbed.extractId(previewUrl);
    if (ytId != null) return YouTubeEmbed(videoId: ytId);
    return LinkPreviewCard(
      url: previewUrl,
      serverUrl: widget.serverUrl ?? '',
      token: widget.authToken ?? '',
    );
  }

  /// Build a single embedded-image tile (GIF via `Image.network`,
  /// everything else via `CachedNetworkImage`).
  Widget _buildEmbeddedImageWidget(String imgUrl) {
    final headers = _mediaHeaders();
    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: GestureDetector(
        onTap: () => widget.onImageTap != null
            ? widget.onImageTap!(imgUrl)
            : _showImageViewer(imageUrl: imgUrl),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400, maxHeight: 320),
          child: imgUrl.endsWith('.gif')
              ? Image.network(
                  imgUrl,
                  headers: headers,
                  fit: BoxFit.cover,
                  gaplessPlayback: true,
                  errorBuilder: (_, _, _) => const SizedBox.shrink(),
                )
              : CachedNetworkImage(
                  imageUrl: imgUrl,
                  cacheKey: stableMediaCacheKey(imgUrl),
                  fit: BoxFit.cover,
                  httpHeaders: headers,
                  cacheManager: chatMediaCacheManager,
                  errorWidget: (_, _, _) => const SizedBox.shrink(),
                  // Reserve area while loading to avoid scroll jump on decode.
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
    );
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
    final poll = _tryBuildPoll(msg);
    if (poll != null) return poll;

    if (hasMedia) {
      return _buildMediaBubble(msg: msg, isMine: isMine, isFailed: isFailed);
    }
    if (_isDecryptFailure(msg.content)) {
      return _buildDecryptFailureBubble(msg: msg, isMine: isMine);
    }
    return _buildTextBubble(msg: msg, isMine: isMine, isFailed: isFailed);
  }

  /// Poll messages render as an interactive vote widget.
  Widget? _tryBuildPoll(ChatMessage msg) {
    if (!isPollContent(msg.content)) return null;
    final parsed = parsePollTag(msg.content);
    if (parsed == null ||
        widget.serverUrl == null ||
        widget.authToken == null) {
      return null;
    }
    return PollWidget(
      messageId: msg.id,
      serverUrl: widget.serverUrl!,
      authToken: widget.authToken!,
      question: parsed.question,
      options: parsed.options,
    );
  }

  // Strip `[Forwarded] ` so MediaContent's start-anchored marker regex still matches.
  Widget _buildMediaBubble({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
  }) {
    final mediaContent = _stripForwardedPrefix(msg.content);
    final mediaWidget = MediaContent(
      content: mediaContent,
      isMine: isMine,
      serverUrl: widget.serverUrl,
      authToken: widget.authToken,
      mediaTicket: widget.mediaTicket,
      onImageTap: widget.onImageTap,
    );
    final caption = extractMediaCaption(mediaContent);
    if (caption == null) return mediaWidget;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        mediaWidget,
        const SizedBox(height: 4),
        RichTextContent(
          text: caption,
          textColor: _contentTextColor(isMine: isMine, isFailed: isFailed),
          accentHoverColor: context.accentHover,
          textSecondaryColor: context.textSecondary,
          density: widget.density,
        ),
      ],
    );
  }

  // Show our own preserved draft (with Resend/Delete) instead of generic decrypt pill that looks like another sender (F-006).
  Widget _buildDecryptFailureBubble({
    required ChatMessage msg,
    required bool isMine,
  }) {
    if (isMine && (msg.failedContent ?? '').isNotEmpty) {
      return OwnDecryptFailedBubble(
        originalText: msg.failedContent!,
        onResend: widget.onRetry == null ? null : () => widget.onRetry!(msg),
        onDelete: widget.onDelete == null ? null : () => widget.onDelete!(msg),
      );
    }
    return const DecryptFailurePill();
  }

  Widget _buildTextBubble({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
  }) {
    final displayContent = _stripForwardedPrefix(msg.content);
    final textColor = _contentTextColor(isMine: isMine, isFailed: isFailed);
    final textWidget = RichTextContent(
      text: displayContent,
      textColor: textColor,
      accentHoverColor: context.accentHover,
      textSecondaryColor: context.textSecondary,
      density: widget.density,
    );

    final embeddedImages = extractEmbeddedImageUrls(displayContent);
    final linkPreview = _buildLinkPreviewWidget(displayContent);

    if (embeddedImages.isEmpty && linkPreview == null) return textWidget;
    if (embeddedImages.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [textWidget, linkPreview!],
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        textWidget,
        ?linkPreview,
        for (final imgUrl in embeddedImages) ...[
          const SizedBox(height: 6),
          _buildEmbeddedImageWidget(imgUrl),
        ],
      ],
    );
  }

  String _stripForwardedPrefix(String content) {
    return content.startsWith(_forwardedPrefix)
        ? content.substring(_forwardedPrefix.length)
        : content;
  }

  /// Assemble the children of the bubble Column.
  List<Widget> _bubbleChildren({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required bool hasMedia,
  }) {
    return [
      if (msg.pinnedAt != null) PinnedIndicator(isMine: isMine),
      // Show sender name once per author-run; the prior "always show in compact" reproduced author/time on every continuation (2026-05-26 regression).
      if (widget.showHeader && (!isMine || widget.compactLayout))
        SenderNameLabel(
          message: msg,
          hasMedia: hasMedia,
          compactLayout: widget.compactLayout,
          density: widget.density,
        ),
      if (msg.replyToContent != null)
        ReplyQuote(
          replyToUsername: msg.replyToUsername,
          replyToContent: msg.replyToContent!,
          isMine: isMine,
          onTap: msg.replyToId != null && widget.onTapReplyQuote != null
              ? () => widget.onTapReplyQuote!(msg.replyToId!)
              : null,
        ),
      if (msg.content.startsWith(_forwardedPrefix))
        ForwardedBadge(isMine: isMine),
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
            style: GoogleFonts.inter(
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
    } else if (widget._isCompact) {
      // Slice 5: Discord has no horizontal inset around compact messages —
      // the avatar column already provides the indent.
      padding = const EdgeInsets.symmetric(horizontal: 0, vertical: 4);
    } else if (widget.compactLayout) {
      padding = const EdgeInsets.symmetric(horizontal: 8, vertical: 4);
    } else {
      // Bubbles layout: scale inner padding with density.
      padding = switch (widget.density) {
        UIDensity.cozy => const EdgeInsets.symmetric(
          horizontal: 14,
          vertical: 10,
        ),
        UIDensity.normal => const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 8,
        ),
        UIDensity.compact => const EdgeInsets.symmetric(
          horizontal: 10,
          vertical: 6,
        ),
      };
    }

    // Bubble cap: 520px (520 keeps reading line tight); ultrawide ≥1600px grows to min(720, 45%vw) (#403, #794).
    final width = MediaQuery.of(context).size.width;
    final maxBubble = width >= 1600 ? math.min(720.0, width * 0.45) : 520.0;
    final bubbleConstraints = widget.compactLayout
        ? const BoxConstraints()
        : BoxConstraints(maxWidth: maxBubble);

    return Container(
      constraints: bubbleConstraints,
      padding: padding,
      decoration: BoxDecoration(
        color: _bubbleColor(isMine: isMine, isFailed: isFailed),
        borderRadius: _bubbleBorderRadius(isMine: isMine),
      ),
      // Merge inner semantics so the screen reader announces one composite label; avatar/hover sit outside the merge.
      child: MergeSemantics(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: _bubbleChildren(
            msg: msg,
            isMine: isMine,
            isFailed: isFailed,
            hasMedia: hasMedia,
          ),
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
    // Plain (Slack) mode: render reactions inline beneath body, not as overlay pill.
    if (widget._isPlain) {
      return Column(
        crossAxisAlignment: isMine
            ? CrossAxisAlignment.end
            : CrossAxisAlignment.start,
        children: [
          bubble,
          Padding(padding: const EdgeInsets.only(top: 2), child: reactionPill),
        ],
      );
    }
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Padding(padding: const EdgeInsets.only(bottom: 14), child: bubble),
        Positioned(
          bottom: 0,
          left: isMine ? 8 : null,
          right: isMine ? null : 8,
          child: reactionPill,
        ),
      ],
    );
  }

  /// Build the avatar section shown to the left of received messages.
  /// [forceShow] overrides the showHeader check — used in compact mode to
  /// display a small avatar next to every message (Discord/Slack style).
  Widget _buildAvatarSection({
    required ChatMessage msg,
    bool forceShow = false,
  }) {
    final avatarImageUrl = widget.senderAvatarUrl != null
        ? '${widget.serverUrl ?? ""}${widget.senderAvatarUrl}'
        : null;
    final showAvatar = widget.showHeader || forceShow;

    final avatarWidth = _resolveAvatarWidth();
    final avatarRadius = _resolveAvatarRadius();

    return Semantics(
      label: 'View profile of ${msg.fromUsername}',
      button: true,
      child: GestureDetector(
        onTap: widget.onAvatarTap != null
            ? () => widget.onAvatarTap!(msg.fromUserId)
            : null,
        child: SizedBox(
          // Slice 5: bump compact avatar to 32px (closer to Discord's 40)
          // for legibility while staying tighter than the bubbles layout.
          width: avatarWidth,
          child: showAvatar
              ? buildAvatar(
                  name: msg.fromUsername,
                  radius: avatarRadius,
                  bgColor: _getAvatarColor(msg.fromUserId),
                  imageUrl: avatarImageUrl,
                )
              : const SizedBox.shrink(),
        ),
      ),
    );
  }

  double _resolveAvatarWidth() {
    if (widget._isCompact) return 32;
    return widget.compactLayout ? 24 : 28;
  }

  double _resolveAvatarRadius() {
    if (widget._isCompact) return 16;
    return widget.compactLayout ? 12 : 14;
  }

  /// Build the tiny green lock icon shown next to the timestamp on encrypted
  /// messages. Received-message lock is tappable to open the safety-number
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
            style: GoogleFonts.inter(fontSize: 11, color: context.textMuted),
          ),
          if (msg.isEncrypted)
            LockIcon(
              message: msg,
              isMine: isMine,
              onVerifyIdentity: widget.onVerifyIdentity,
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
                style: GoogleFonts.inter(
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
                    style: GoogleFonts.inter(
                      fontSize: 10,
                      color: context.textMuted,
                    ),
                  ),
                ],
              ),
            ),
          if (isMine) MessageStatusIcon(status: msg.status),
        ],
      ),
    );
  }

  /// Hover-timestamp rendered in the avatar gutter on continuation rows
  /// (Discord-style). The widget always occupies the same width as the
  /// avatar slot so the bubble alignment doesn't shift on hover; the text
  /// itself fades in/out.
  Widget _buildHoverGutterTimestamp({required ChatMessage msg}) {
    final fontSize = switch (widget.density) {
      UIDensity.cozy => 11.0,
      UIDensity.normal => 10.0,
      UIDensity.compact => 9.0,
    };
    return SizedBox(
      width: _resolveAvatarWidth(),
      child: ValueListenableBuilder<bool>(
        valueListenable: _hoverNotifier,
        builder: (context, isHovered, _) => AnimatedOpacity(
          opacity: isHovered ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 140),
          child: Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Text(
              _formatHourMinute(msg.timestamp),
              textAlign: TextAlign.right,
              style: GoogleFonts.inter(
                fontSize: fontSize,
                color: context.textMuted,
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// "HH:MM" only — Discord-style compact hover timestamp.
  String _formatHourMinute(String iso) {
    try {
      final dt = DateTime.parse(iso).toLocal();
      final h = dt.hour;
      final h12 = h == 0 ? 12 : (h > 12 ? h - 12 : h);
      final am = h < 12 ? 'AM' : 'PM';
      return '${h12.toString()}:${dt.minute.toString().padLeft(2, '0')} $am';
    } catch (_) {
      return '';
    }
  }

  /// True when the last-in-group row needs to surface extra metadata
  /// (edited tag, pin, expiry, lock) that the gutter timestamp can't.
  bool _hasTrailingMeta(ChatMessage msg) =>
      msg.editedAt != null ||
      msg.pinnedAt != null ||
      msg.expiresAt != null ||
      msg.isEncrypted;

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
    final style = _hoverStyle;
    // Always top-right (Discord convention), regardless of bubble side.
    return Positioned(
      top: style.overlayTop,
      right: 8,
      // IntrinsicWidth: CanvasKit otherwise stretches the Row to full Stack width when only one edge is set (prod 2026-05-08).
      child: ValueListenableBuilder<bool>(
        valueListenable: _hoverNotifier,
        builder: (context, isHovered, child) => ExcludeSemantics(
          excluding: !isHovered,
          child: IgnorePointer(
            ignoring: !isHovered,
            child: AnimatedOpacity(
              opacity: isHovered ? 1 : 0,
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOut,
              child: AnimatedSlide(
                offset: isHovered ? Offset.zero : style.hiddenSlideOffset,
                duration: const Duration(milliseconds: 140),
                curve: Curves.easeOut,
                child: child,
              ),
            ),
          ),
        ),
        child: IntrinsicWidth(
          child: _buildHoverActions(msg, isMine, mediaUrl: mediaUrl),
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

    // Continuation rows: avatar slot becomes the hover-timestamp gutter
    // (Discord pattern). The previous below-bubble hover timestamp reserved
    // ~16-18px of vertical space per row even at opacity 0, which is the
    // bulk of the inter-message gap users were seeing.
    if (!widget.showHeader) {
      return [
        _buildHoverGutterTimestamp(msg: msg),
        const SizedBox(width: 8),
        Flexible(child: bubbleWithReactions),
      ];
    }

    return [
      _buildAvatarSection(msg: msg),
      const SizedBox(width: 8),
      Flexible(child: bubbleWithReactions),
    ];
  }

  /// Build the system event pill (centered, borderless).
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

  /// Handle long-press: open the centralised context menu on mobile,
  /// or fall through to the desktop reaction picker on non-mobile
  /// when no reactions are present yet (matches pre-migration
  /// behaviour where long-press without reactions seeded the
  /// floating picker).
  void _handleLongPress(
    LongPressStartDetails details,
    ChatMessage msg,
    bool isMine,
    String? mediaUrl,
    bool hasReactions,
  ) {
    if (Responsive.isMobile(context)) {
      HapticFeedback.mediumImpact();
      _openContextMenu(details.globalPosition, msg, isMine, mediaUrl);
    } else if (!hasReactions) {
      widget.onReactionTap?.call(msg, details.globalPosition);
    }
  }

  /// Open the centralised Echo context menu for [msg]. Single
  /// entry-point used by mobile long-press, desktop right-click on
  /// the bubble, and the hover-bar "..." overflow button. Action
  /// visibility lives in [buildMessageMenu]; this method just hands
  /// it the live state + callbacks.
  void _openContextMenu(
    Offset anchor,
    ChatMessage msg,
    bool isMine,
    String? mediaUrl,
  ) {
    final isImage = mediaUrl != null && _isImageMedia(msg.content, mediaUrl);
    final unreadable = _isDecryptFailure(msg.content);

    final target = MessageTarget(
      message: msg,
      isMine: isMine,
      isSaved: widget.isSaved,
      isEncryptedUnreadable: unreadable,
      mediaUrl: mediaUrl,
      isImageMedia: isImage,
      onReply: _wrapMsgCallback(widget.onReply, msg),
      onForward: _wrapMsgCallback(widget.onForward, msg),
      onRetry: _resolveRetryCallback(msg),
      onCopyText: () => _copyMessageText(msg, mediaUrl),
      // `isImage` only true when `mediaUrl` is non-null (the predicate
      // guards both), so the analyser promotes `mediaUrl` here.
      onViewGallery: isImage ? () => _handleImageAction(mediaUrl) : null,
      onPin: _resolvePinCallback(msg),
      onUnpin: _resolveUnpinCallback(msg),
      onSave: _wrapMsgCallback(widget.onSave, msg),
      onUnsave: _wrapMsgCallback(widget.onUnsave, msg),
      onEdit: _wrapMsgCallback(widget.onEdit, msg),
      onDelete: _wrapMsgCallback(widget.onDelete, msg),
      onCopyId: () => _copyMessageId(msg),
      // Registry decides visibility based on isEncryptedUnreadable; we still wire callbacks.
      onPickReaction: widget.onReactionSelect == null
          ? null
          : (emoji) => widget.onReactionSelect!(msg, emoji),
      onOpenFullPicker: _wrapMsgCallback(widget.onMoreReactions, msg),
      recentReactions: reactionEmojis.take(4).toList(),
    );

    EchoContextMenu.open(
      context: context,
      target: target,
      anchor: anchor,
      model: buildMessageMenu(target),
    );
  }

  VoidCallback? _wrapMsgCallback(
    void Function(ChatMessage)? callback,
    ChatMessage msg,
  ) {
    if (callback == null) return null;
    return () => callback(msg);
  }

  VoidCallback? _resolveRetryCallback(ChatMessage msg) {
    if (msg.status != MessageStatus.failed || widget.onRetry == null) {
      return null;
    }
    return () => widget.onRetry!(msg);
  }

  VoidCallback? _resolvePinCallback(ChatMessage msg) {
    if (msg.pinnedAt != null || widget.onPin == null) return null;
    return () => widget.onPin!(msg);
  }

  VoidCallback? _resolveUnpinCallback(ChatMessage msg) {
    if (msg.pinnedAt == null || widget.onUnpin == null) return null;
    return () => widget.onUnpin!(msg);
  }

  void _copyMessageText(ChatMessage msg, String? mediaUrl) {
    final copyText = mediaUrl != null ? _resolveUrl(mediaUrl) : msg.content;
    copyToClipboard(
      context,
      copyText,
      successMessage: mediaUrl != null ? 'Link copied' : 'Copied to clipboard',
    );
  }

  void _copyMessageId(ChatMessage msg) {
    copyToClipboard(context, msg.id, successMessage: 'Message ID copied');
  }

  /// Compose a single composite semantic label for the message bubble so
  /// assistive tech announces sender, time, content, status, and metadata
  /// in one continuous read instead of fragmented pieces (#496).
  String _composeMessageSemanticsLabel(ChatMessage msg, bool isMine) {
    final who = isMine ? 'You' : msg.fromUsername;
    final time = formatMessageTimestamp(msg.timestamp);
    final preview = previewForSemantics(msg.content);
    final reactionCount = msg.reactions.length;
    final parts = <String>[
      'From $who at $time',
      if (preview.isNotEmpty) preview,
      if (reactionCount > 0)
        '$reactionCount reaction${reactionCount == 1 ? '' : 's'}',
      if (msg.pinnedAt != null) 'Pinned',
      if (msg.editedAt != null) 'Edited',
      if (msg.isEncrypted) 'End-to-end encrypted',
      'Long press for actions',
    ];
    return '${parts.join('. ')}.';
  }

  /// Density+header-aware top padding for the message row.
  double _buildTopPad() {
    if (widget.showHeader) {
      // Density-driven gap so layout and density are independent knobs.
      return switch (widget.density) {
        UIDensity.cozy => 12,
        UIDensity.normal => 8,
        UIDensity.compact => 3,
      };
    }
    // Continuation rows: tighter spacing so a group reads as one paragraph.
    return switch (widget.density) {
      UIDensity.cozy => 1,
      UIDensity.normal => 1,
      UIDensity.compact => 0,
    };
  }

  /// Row hover decoration: tint + border. Plain layout uses a 3px left accent
  /// rule (Slack style); other layouts use a thin all-sides border (#834).
  BoxDecoration? _buildRowHoverDecoration(
    bool isHovered,
    _HoverStyleSpec hoverSpec,
  ) {
    if (!isHovered) return null;
    if (widget._isPlain) {
      return BoxDecoration(
        color: hoverSpec.rowHoverColor,
        border: Border(
          left: BorderSide(
            color: context.accent.withValues(alpha: 0.4),
            width: 3,
          ),
        ),
      );
    }
    return BoxDecoration(
      color: hoverSpec.rowHoverColor,
      border: Border.all(color: hoverSpec.rowHoverBorderColor, width: 0.5),
      borderRadius: BorderRadius.circular(4),
    );
  }

  /// Inner column: bubble row + optional reply badge/preview + timestamp +
  /// optional retry row.
  Widget _buildMessageColumn({
    required ChatMessage msg,
    required bool isMine,
    required bool isFailed,
    required bool isAlignedEnd,
    required bool hasReactions,
    required Widget bubbleWithReactions,
    required String? mediaUrl,
  }) {
    return Stack(
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
              // Bubbles: avatar bottom (iMessage); compact: top (lines up with sender name).
              crossAxisAlignment: widget.compactLayout
                  ? CrossAxisAlignment.start
                  : CrossAxisAlignment.end,
              children: _buildMessageRowChildren(
                msg: msg,
                isMine: isMine,
                bubbleWithReactions: bubbleWithReactions,
              ),
            ),
            if (msg.replyCount > 0)
              ReplyCountBadge(
                message: msg,
                isMine: isMine,
                onTap: widget.onViewThread,
                inlineStyle: widget._isPlain,
              ),
            if (msg.replyCount > 0 &&
                (msg.latestReplyPreview?.trim().isNotEmpty ?? false) &&
                !msg.isEncrypted)
              _LatestReplyPreview(
                preview: msg.latestReplyPreview!,
                isMine: isMine,
              ),
            // Bottom timestamp row stays only when we genuinely need to
            // show delivery status (own messages) or trailing metadata on
            // the last message of a group. Continuation rows lift their
            // hover timestamp into the left gutter (see
            // _buildHoverGutterTimestamp), freeing the ~16-18px below-row
            // reservation that AnimatedOpacity used to keep even at 0
            // opacity.
            if (widget.isLastInGroup && (isMine || _hasTrailingMeta(msg)))
              _buildTimestampRow(msg: msg, isMine: isMine),
            if (isFailed && isMine)
              RetryRow(
                message: msg,
                onRetry: widget.onRetry,
                onDelete: widget.onDelete,
              ),
          ],
        ),
        if (!hasReactions)
          _buildHoverOverlay(msg: msg, isMine: isMine, mediaUrl: mediaUrl),
      ],
    );
  }

  /// GestureDetector that wraps [child] with swipe-to-reply handlers when
  /// [canSwipeToReply] is true, plus the long-press semantics.
  Widget _buildGestureDetector({
    required ChatMessage msg,
    required bool isMine,
    required bool canSwipeToReply,
    required bool hasReactions,
    required String? mediaUrl,
    required Widget child,
  }) {
    return GestureDetector(
      onLongPressStart: (details) =>
          _handleLongPress(details, msg, isMine, mediaUrl, hasReactions),
      // Right-click routes through _openContextMenu like the hover-bar overflow.
      onSecondaryTapDown: (details) =>
          _openContextMenu(details.globalPosition, msg, isMine, mediaUrl),
      onHorizontalDragUpdate: canSwipeToReply
          ? (details) {
              // Guard against iOS system back gesture zone (left 30px).
              if (details.globalPosition.dx < 30) return;
              final newDx = (_swipeDx + details.delta.dx).clamp(0.0, 72.0);
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
      child: child,
    );
  }

  @override
  Widget build(BuildContext context) {
    final msg = widget.message;
    final isMine = msg.isMine;
    final isFailed = msg.status == MessageStatus.failed;
    final isSending = msg.status == MessageStatus.sending;

    if (msg.isSystemEvent) return SystemEventPill(message: msg);

    // Hide undecryptable messages entirely when the user has opted in (#668).
    if (widget.hideUndecryptable && _isDecryptFailure(msg.content)) {
      return const SizedBox.shrink();
    }

    // Strip `[Forwarded] ` before media regex (start-anchored patterns would otherwise miss the marker).
    final contentForMedia = msg.content.startsWith(_forwardedPrefix)
        ? msg.content.substring(_forwardedPrefix.length)
        : msg.content;
    final mediaUrl = extractMediaUrl(contentForMedia);
    final hasMedia = mediaUrl != null;
    final hasReactions = msg.reactions.isNotEmpty;

    final reactionPill = ReactionBar(
      reactions: msg.reactions,
      currentUserId: widget.myUserId,
      isMine: isMine,
      chatBgColor: context.chatBg,
      onTap: (pos) => widget.onReactionTap?.call(msg, pos),
      density: widget.density,
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
    final topPad = _buildTopPad();
    final hoverSpec = _hoverStyle;

    final messageWidget = ValueListenableBuilder<bool>(
      valueListenable: _hoverNotifier,
      builder: (context, isHovered, child) => Container(
        padding: EdgeInsets.only(
          left: 12,
          right: 12,
          top: topPad,
          bottom: hasReactions ? 4 : 2,
        ),
        decoration: _buildRowHoverDecoration(isHovered, hoverSpec),
        child: child,
      ),
      child: _buildMessageColumn(
        msg: msg,
        isMine: isMine,
        isFailed: isFailed,
        isAlignedEnd: isAlignedEnd,
        hasReactions: hasReactions,
        bubbleWithReactions: bubbleWithReactions,
        mediaUrl: mediaUrl,
      ),
    );

    return AnimatedOpacity(
      duration: const Duration(milliseconds: 300),
      opacity: isSending ? 0.5 : 1.0,
      child: MouseRegion(
        onEnter: (_) => _hoverNotifier.value = true,
        onExit: (_) => _hoverNotifier.value = false,
        child: Semantics(
          label: _composeMessageSemanticsLabel(msg, isMine),
          // Declare the actual gesture (long-press); `button: true` lied to screen readers (#830 finding 11).
          onLongPress: () => _handleLongPress(
            const LongPressStartDetails(),
            msg,
            isMine,
            mediaUrl,
            hasReactions,
          ),
          child: _buildGestureDetector(
            msg: msg,
            isMine: isMine,
            canSwipeToReply: canSwipeToReply,
            hasReactions: hasReactions,
            mediaUrl: mediaUrl,
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

class _HoverStyleSpec {
  final Color background;
  final Color borderColor;
  final Color iconColor;
  final List<BoxShadow> shadow;
  final double borderWidth;
  final double containerRadius;
  final double buttonSize;
  final double buttonRadius;
  final double iconSize;
  final double iconOpacity;
  final double overlayTop;
  final Offset hiddenSlideOffset;
  final Color rowHoverColor;
  final Color rowHoverBorderColor;

  const _HoverStyleSpec({
    required this.background,
    required this.borderColor,
    required this.iconColor,
    required this.shadow,
    required this.borderWidth,
    required this.containerRadius,
    required this.buttonSize,
    required this.buttonRadius,
    required this.iconSize,
    required this.iconOpacity,
    required this.overlayTop,
    required this.hiddenSlideOffset,
    required this.rowHoverColor,
    required this.rowHoverBorderColor,
  });

  factory _HoverStyleSpec.forLayout({
    required MessageLayout layout,
    required BuildContext context,
  }) {
    switch (layout) {
      case MessageLayout.bubbles:
        return _HoverStyleSpec(
          background: context.surface.withValues(alpha: 0.98),
          borderColor: context.border,
          iconColor: context.textPrimary,
          shadow: const [
            BoxShadow(
              color: Color(0x3D000000),
              blurRadius: 14,
              offset: Offset(0, 4),
            ),
          ],
          borderWidth: 1,
          containerRadius: 8,
          buttonSize: 33,
          buttonRadius: 5,
          iconSize: 16,
          iconOpacity: 0.82,
          overlayTop: -8,
          hiddenSlideOffset: const Offset(0, -0.1),
          rowHoverColor: context.textPrimary.withValues(alpha: 0.04),
          rowHoverBorderColor: context.border.withValues(alpha: 0.15),
        );
      case MessageLayout.plain:
        return _HoverStyleSpec(
          background: context.surface.withValues(alpha: 0.76),
          borderColor: context.accent.withValues(alpha: 0.28),
          iconColor: context.textPrimary,
          shadow: const [
            BoxShadow(
              color: Color(0x29000000),
              blurRadius: 8,
              offset: Offset(0, 2),
            ),
          ],
          borderWidth: 1,
          containerRadius: 10,
          buttonSize: 33,
          buttonRadius: 6,
          iconSize: 15,
          iconOpacity: 0.8,
          overlayTop: -6,
          hiddenSlideOffset: const Offset(0, -0.08),
          rowHoverColor: context.accent.withValues(alpha: 0.04),
          rowHoverBorderColor: context.accent.withValues(alpha: 0.18),
        );
      case MessageLayout.compact:
        return _HoverStyleSpec(
          background: context.surface.withValues(alpha: 0.95),
          borderColor: context.border,
          iconColor: context.textSecondary,
          shadow: const [],
          borderWidth: 1,
          containerRadius: 6,
          buttonSize: 33,
          buttonRadius: 4,
          iconSize: 14,
          iconOpacity: 0.75,
          overlayTop: -8,
          hiddenSlideOffset: const Offset(0, -0.12),
          rowHoverColor: context.textPrimary.withValues(alpha: 0.03),
          rowHoverBorderColor: context.border.withValues(alpha: 0.09),
        );
    }
  }
}

/// Slack-style inline preview of the latest reply, rendered as a small
/// muted italic line directly under the reply-count badge. Aligns to the
/// same side as the badge (left for incoming, right for outgoing in
/// bubble layouts) so the eye treats badge + preview as one cluster.
class _LatestReplyPreview extends StatelessWidget {
  final String preview;
  final bool isMine;

  const _LatestReplyPreview({required this.preview, required this.isMine});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: EdgeInsets.only(top: 2, left: isMine ? 0 : 36, right: 4),
      child: Align(
        alignment: isMine ? Alignment.centerRight : Alignment.centerLeft,
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 320),
          child: Text(
            preview,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: GoogleFonts.inter(
              fontSize: 11,
              fontStyle: FontStyle.italic,
              color: context.textMuted,
            ),
          ),
        ),
      ),
    );
  }
}
