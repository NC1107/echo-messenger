import 'dart:async';
import 'dart:typed_data';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../models/reaction.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/websocket_provider.dart';
import '../screens/user_profile_screen.dart';
import '../services/message_cache.dart';
import '../services/saved_messages_service.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import 'skeleton_loader.dart';
import 'channel_bar.dart';
import 'chat_header_bar.dart';
import 'chat_input_bar.dart';
import 'connection_status_banner.dart';
import 'crypto_degraded_banner.dart';
import 'identity_key_changed_banner.dart';
import '../providers/media_ticket_provider.dart';
import 'forward_message_dialog.dart';
import 'image_gallery_viewer.dart';
import 'message/media_content.dart'
    show
        extractEmbeddedImageUrls,
        isImageUrl,
        isStandaloneMediaUrl,
        mediaHeaders,
        resolveMediaUrl;
import 'message_item.dart';
import 'message_search_overlay.dart';
import 'thread_view_panel.dart';

// reactionEmojis imported from message_item.dart

class ChatPanel extends ConsumerStatefulWidget {
  final Conversation? conversation;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;
  final VoidCallback? onBack;
  final VoidCallback? onShowLounge;
  final bool hideVoiceDock;

  const ChatPanel({
    super.key,
    this.conversation,
    this.onMembersToggle,
    this.onGroupInfo,
    this.onBack,
    this.onShowLounge,
    this.hideVoiceDock = false,
  });

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _chatInputBarKey = GlobalKey<ChatInputBarState>();

  /// Cache scroll offsets keyed by conversation ID so switching conversations
  /// preserves the user's position. Capped at [_kMaxScrollPositions] entries
  /// to prevent unbounded growth as the user visits many conversations.
  static final Map<String, double> _scrollPositions = {};
  static const int _kMaxScrollPositions = 50;

  /// Evict the oldest entries from [_scrollPositions] when over the limit.
  static void _evictScrollPositions() {
    while (_scrollPositions.length > _kMaxScrollPositions) {
      _scrollPositions.remove(_scrollPositions.keys.first);
    }
  }

  String _newMessagesBannerText() {
    if (_newMessagesBelowCount <= 0) return 'New messages';
    final noun = _newMessagesBelowCount == 1 ? 'message' : 'messages';
    return '$_newMessagesBelowCount new $noun';
  }

  static const _dismissedBannersKey = 'dismissed_encryption_banners';
  static Set<String> _dismissedBannerIds = {};
  static bool _bannersLoaded = false;

  /// Persistent blocklist of message IDs deleted via "delete for me".
  /// Survives app restarts so messages don't reappear on history reload.
  static const _deletedForMeKey = 'deleted_for_me_ids';
  static Set<String> _deletedForMeIds = {};
  static bool _deletedForMeLoaded = false;
  String? _selectedTextChannelId;
  String? _activeVoiceChannelId;
  String? _loadedHistoryKey;
  String? _loadedChannelsConversationId;
  String? _autoScrollConversationKey;

  /// The message ID at which the "New Messages" divider should appear.
  /// Set when opening a conversation with unread messages, cleared when
  /// the unread count drops to 0.
  String? _unreadBoundaryMessageId;
  int _unreadBoundaryCount = 0;

  /// GlobalKeys for rendered message items, keyed by message ID.
  /// Used by [_scrollToMessage] for pixel-accurate scrolling (via
  /// [Scrollable.ensureVisible]) and by [_updateFloatingDate] to detect which
  /// message is at the top of the viewport without a hardcoded height estimate.
  /// Cleared whenever the active conversation changes to prevent leaks.
  final _messageKeys = <String, GlobalKey>{};

  bool _showSearch = false;
  ChatMessage? _threadParent;
  String? _highlightedMessageId;
  Timer? _highlightTimer;
  double _lastKeyboardInset = 0;

  /// True while a file is being dragged over the chat area.
  bool _isDragOver = false;

  /// Local mirror of SavedMessagesService so [MessageItem] can render the
  /// correct bookmark icon without async round-trips.
  final Set<String> _savedIds = {};

  /// Floating date label state
  String? _floatingDate;
  bool _floatingDateVisible = false;
  Timer? _floatingDateTimer;
  // Tracks near-bottom state from the user's last scroll event, before any
  // viewport resize (keyboard open/close). Used in _handleKeyboardScroll so
  // we don't lose context when maxScrollExtent shifts under us.
  bool _wasNearBottom = true;

  /// True when a new message arrives while the user has scrolled up.
  bool _hasNewMessagesBelow = false;
  int _newMessagesBelowCount = 0;

  OverlayEntry? _reactionOverlay;

  bool get _hideEncryptionBanner {
    final convId = widget.conversation?.id;
    return convId != null && _dismissedBannerIds.contains(convId);
  }

  Future<void> _dismissEncryptionBanner() async {
    final convId = widget.conversation?.id;
    if (convId == null) return;
    setState(() => _dismissedBannerIds.add(convId));
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(
      _dismissedBannersKey,
      _dismissedBannerIds.toList(),
    );
  }

  static Future<void> _loadDismissedBanners() async {
    if (_bannersLoaded) return;
    _bannersLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    _dismissedBannerIds = (prefs.getStringList(_dismissedBannersKey) ?? [])
        .toSet();
  }

  static Future<void> _loadDeletedForMe() async {
    if (_deletedForMeLoaded) return;
    _deletedForMeLoaded = true;
    final prefs = await SharedPreferences.getInstance();
    _deletedForMeIds = (prefs.getStringList(_deletedForMeKey) ?? []).toSet();
  }

  static Future<void> _addToDeletedForMe(String messageId) async {
    _deletedForMeIds.add(messageId);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_deletedForMeKey, _deletedForMeIds.toList());
  }

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    _loadDismissedBanners();
    _loadDeletedForMe();
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation?.id != oldWidget.conversation?.id) {
      // Save scroll offset for the old conversation+channel
      final oldId = oldWidget.conversation?.id;
      if (oldId != null && _scrollController.hasClients) {
        final oldKey = '$oldId:${_selectedTextChannelId ?? ""}';
        _scrollPositions[oldKey] = _scrollController.offset;
        _evictScrollPositions();
      }

      _selectedTextChannelId = null;
      _activeVoiceChannelId = null;
      _loadedHistoryKey = null;
      _autoScrollConversationKey = null;
      _showSearch = false;
      _threadParent = null;
      _highlightedMessageId = null;
      _hasNewMessagesBelow = false;
      _newMessagesBelowCount = 0;
      _unreadBoundaryMessageId = null;
      _unreadBoundaryCount = 0;
      _floatingDate = null;
      _floatingDateVisible = false;
      _floatingDateTimer?.cancel();
      _highlightTimer?.cancel();
      _messageKeys.clear();
      _dismissReactionPicker();

      // Restore cached scroll position for the new conversation, or scroll
      // to bottom if no cached position exists. If there's an unread boundary,
      // defer to the first-load callback which scrolls to the divider.
      final newId = widget.conversation?.id;
      if (newId != null) {
        final newKey = '$newId:${_selectedTextChannelId ?? ""}';
        final cached = _scrollPositions[newKey];
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!_scrollController.hasClients) return;
          // Defer to the first-load callback if unread boundary will be set
          final convData = ref
              .read(conversationsProvider)
              .conversations
              .where((c) => c.id == newId)
              .firstOrNull;
          if (convData != null && convData.unreadCount > 0) return;
          if (cached != null) {
            _scrollController.jumpTo(
              cached.clamp(0, _scrollController.position.maxScrollExtent),
            );
          } else {
            _scrollToBottom(animated: false, settleRetries: 3);
          }
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _dismissReactionPicker();
    _highlightTimer?.cancel();
    _floatingDateTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && widget.conversation != null) {
      _markAsRead();
    }
  }

  // ---------------------------------------------------------------------------
  // History + scroll management
  // ---------------------------------------------------------------------------

  void _onScroll() {
    _wasNearBottom = _isNearBottom();
    if (_scrollController.position.pixels <=
        _scrollController.position.minScrollExtent + 50) {
      _loadOlderMessages();
    }
    // Clear "new messages" pill and unread divider when user scrolls near
    // the bottom -- they've seen all the new messages.
    if (_isNearBottom()) {
      if (_hasNewMessagesBelow || _unreadBoundaryMessageId != null) {
        setState(() {
          _hasNewMessagesBelow = false;
          _newMessagesBelowCount = 0;
          _unreadBoundaryMessageId = null;
          _unreadBoundaryCount = 0;
        });
      }
    }
    _updateFloatingDate();
  }

  void _updateFloatingDate() {
    final conv = widget.conversation;
    if (conv == null || !_scrollController.hasClients) return;

    final chatState = ref.read(chatProvider);
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled = conv.isGroup && _selectedTextChannelId == null;
    final messages = _resolveMessages(
      conv,
      chatState,
      selectedChannelId,
      includeUnchanneled,
    );
    if (messages.isEmpty) return;

    // Find the topmost rendered message by querying each message's RenderBox
    // position in the viewport. This is accurate for any message height
    // (images, reactions, multi-line text) and avoids the old 60px estimate.
    String? topmostId;
    double closestY = double.infinity;
    for (final entry in _messageKeys.entries) {
      final ctx = entry.value.currentContext;
      if (ctx == null) continue;
      final box = ctx.findRenderObject();
      if (box is! RenderBox || !box.hasSize) continue;
      final y = box.localToGlobal(Offset.zero).dy;
      if (y < closestY) {
        closestY = y;
        topmostId = entry.key;
      }
    }
    final msgIndex = topmostId == null
        ? 0
        : messages
              .indexWhere((m) => m.id == topmostId)
              .clamp(0, messages.length - 1);

    try {
      final dt = DateTime.parse(messages[msgIndex].timestamp).toLocal();
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      String label;
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        label = 'Today';
      } else if (dt.year == yesterday.year &&
          dt.month == yesterday.month &&
          dt.day == yesterday.day) {
        label = 'Yesterday';
      } else {
        label = '${_fullMonthName(dt.month)} ${dt.day}, ${dt.year}';
      }

      if (label != _floatingDate || !_floatingDateVisible) {
        setState(() {
          _floatingDate = label;
          _floatingDateVisible = true;
        });
      }
    } catch (_) {
      return;
    }

    _floatingDateTimer?.cancel();
    _floatingDateTimer = Timer(const Duration(seconds: 2), () {
      if (mounted) setState(() => _floatingDateVisible = false);
    });
  }

  void _scrollToBottom({bool animated = true, int settleRetries = 3}) {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_scrollController.hasClients) return;

      final target = _scrollController.position.maxScrollExtent;
      final alreadyAtBottom =
          (target - _scrollController.position.pixels).abs() < 1;
      if (alreadyAtBottom) return;

      Future<void> settleIfNeeded() async {
        if (settleRetries <= 0 || !_scrollController.hasClients) return;
        // Wait for layout to settle so maxScrollExtent includes new content
        await Future<void>.delayed(const Duration(milliseconds: 150));
        if (!_scrollController.hasClients) return;
        final newTarget = _scrollController.position.maxScrollExtent;
        if ((newTarget - _scrollController.position.pixels).abs() > 1) {
          _scrollController.jumpTo(newTarget);
        }
        await Future<void>.delayed(const Duration(milliseconds: 100));
        _scrollToBottom(animated: false, settleRetries: settleRetries - 1);
      }

      if (animated) {
        _scrollController
            .animateTo(
              target,
              duration: const Duration(milliseconds: 220),
              curve: Curves.easeOut,
            )
            .whenComplete(settleIfNeeded);
      } else {
        _scrollController.jumpTo(target);
        settleIfNeeded();
      }

      // Update the scroll cache and dismiss the new-messages pill.
      // Key includes channel ID so switching text channels within a group
      // preserves separate scroll positions.
      final convId = widget.conversation?.id;
      if (convId != null) {
        final cacheKey = '$convId:${_selectedTextChannelId ?? ""}';
        _scrollPositions[cacheKey] = target;
        _evictScrollPositions();
      }
      if (_hasNewMessagesBelow) {
        setState(() {
          _hasNewMessagesBelow = false;
          _newMessagesBelowCount = 0;
        });
      }
    });
  }

  bool _isNearBottom() {
    if (!_scrollController.hasClients) return true;
    final pos = _scrollController.position;
    return pos.maxScrollExtent - pos.pixels < 150;
  }

  void _loadHistory() {
    final conv = widget.conversation;
    if (conv == null) return;
    final key = '${conv.id}:${_selectedTextChannelId ?? ""}';
    if (key == _loadedHistoryKey) return;
    _loadedHistoryKey = key;

    final auth = ref.read(authProvider);
    if (auth.token == null || auth.userId == null) return;

    // Load cached messages first for instant display
    ref.read(chatProvider.notifier).loadFromCache(conv.id, auth.userId!);

    // Capture unread boundary from cached messages before they are marked read.
    _captureUnreadBoundary();

    final groupCrypto = conv.isGroup
        ? ref.read(groupCryptoServiceProvider)
        : null;
    if (groupCrypto != null) {
      groupCrypto.setToken(auth.token!);
    }

    // For 1:1 DMs, pass the crypto service so encrypted messages can be
    // decrypted. Without this, _decryptIfNeeded sees crypto==null and
    // shows "[Encrypted history]" instead of the actual message content.
    final cryptoState = ref.read(cryptoProvider);
    final crypto = (!conv.isGroup && cryptoState.isInitialized)
        ? ref.read(cryptoServiceProvider)
        : null;
    if (crypto != null) {
      crypto.setToken(auth.token!);
    }

    ref
        .read(chatProvider.notifier)
        .loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          channelId: _selectedTextChannelId,
          crypto: crypto,
          isGroup: conv.isGroup,
          groupCrypto: groupCrypto,
        );
  }

  void _loadChannels() {
    final conv = widget.conversation;
    if (conv == null || !conv.isGroup) return;
    if (conv.id == _loadedChannelsConversationId) return;
    _loadedChannelsConversationId = conv.id;
    ref.read(channelsProvider.notifier).loadChannels(conv.id);
  }

  void _loadOlderMessages() {
    final conv = widget.conversation;
    if (conv == null) return;
    final chatState = ref.read(chatProvider);
    if ((chatState.loadingHistory[conv.id] ?? false) ||
        !(chatState.hasMore[conv.id] ?? true)) {
      return;
    }

    final messages = conv.isGroup
        ? chatState.messagesForConversationChannel(
            conv.id,
            channelId: _selectedTextChannelId,
            includeUnchanneled: _selectedTextChannelId == null,
          )
        : chatState.messagesForConversation(conv.id);
    if (messages.isEmpty) return;

    final oldestTimestamp = messages.first.timestamp;
    final auth = ref.read(authProvider);
    if (auth.token == null || auth.userId == null) return;

    final groupCryptoOlder = conv.isGroup
        ? ref.read(groupCryptoServiceProvider)
        : null;
    if (groupCryptoOlder != null) {
      groupCryptoOlder.setToken(auth.token!);
    }

    // Pass crypto for 1:1 DM decryption (same as _loadHistory)
    final cryptoStateOlder = ref.read(cryptoProvider);
    final cryptoOlder = (!conv.isGroup && cryptoStateOlder.isInitialized)
        ? ref.read(cryptoServiceProvider)
        : null;
    if (cryptoOlder != null) {
      cryptoOlder.setToken(auth.token!);
    }

    ref
        .read(chatProvider.notifier)
        .loadHistoryWithUserId(
          conv.id,
          auth.token!,
          auth.userId!,
          channelId: _selectedTextChannelId,
          before: oldestTimestamp,
          crypto: cryptoOlder,
          isGroup: conv.isGroup,
          groupCrypto: groupCryptoOlder,
        );
  }

  void _markAsRead() {
    final conv = widget.conversation;
    if (conv == null) return;
    ref.read(conversationsProvider.notifier).markAsRead(conv.id);
    final privacy = ref.read(privacyProvider);
    if (!privacy.readReceiptsEnabled) return;
    ref.read(conversationsProvider.notifier).sendReadReceipt(conv.id);
    ref.read(websocketProvider.notifier).sendReadReceipt(conv.id);
  }

  /// Compute the unread boundary message ID from the current unread count.
  /// Called once when a conversation is first opened or messages finish loading.
  void _captureUnreadBoundary() {
    final conv = widget.conversation;
    if (conv == null) return;
    // Only capture once per conversation open
    if (_unreadBoundaryMessageId != null) return;

    final convState = ref.read(conversationsProvider);
    final convData = convState.conversations
        .where((c) => c.id == conv.id)
        .firstOrNull;
    if (convData == null || convData.unreadCount <= 0) return;

    final chatState = ref.read(chatProvider);
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled = conv.isGroup && _selectedTextChannelId == null;
    final messages = _resolveMessages(
      conv,
      chatState,
      selectedChannelId,
      includeUnchanneled,
    );
    if (messages.isEmpty) return;

    final boundaryIndex = messages.length - convData.unreadCount;
    if (boundaryIndex > 0 && boundaryIndex < messages.length) {
      setState(() {
        _unreadBoundaryMessageId = messages[boundaryIndex].id;
        _unreadBoundaryCount = convData.unreadCount;
      });
    }
  }

  /// Scroll to the unread boundary divider so it appears near the top.
  void _scrollToUnreadBoundary() {
    final conv = widget.conversation;
    if (conv == null || _unreadBoundaryMessageId == null) return;

    final chatState = ref.read(chatProvider);
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled = conv.isGroup && _selectedTextChannelId == null;
    final messages = _resolveMessages(
      conv,
      chatState,
      selectedChannelId,
      includeUnchanneled,
    );
    final index = messages.indexWhere((m) => m.id == _unreadBoundaryMessageId);
    if (index < 0 || !_scrollController.hasClients) return;

    // Use Scrollable.ensureVisible if the key is available for pixel-accurate
    // positioning; fall back to a jump when the item is not yet rendered.
    final key = _messageKeys[_unreadBoundaryMessageId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        alignment: 0.15,
        duration: Duration.zero,
      );
    } else {
      // Item not rendered yet — scroll by index (approximate).
      final estimatedOffset = (index + 1) * 60.0 - 120.0;
      _scrollController.jumpTo(
        estimatedOffset.clamp(0, _scrollController.position.maxScrollExtent),
      );
    }
  }

  void _onTextChannelChanged(String? channelId) {
    if (_selectedTextChannelId == channelId) return;
    _messageKeys.clear();
    setState(() {
      _selectedTextChannelId = channelId;
      _loadedHistoryKey = null;
      _hasNewMessagesBelow = false;
      _newMessagesBelowCount = 0;
    });
    _loadHistory();
    _markAsRead();
  }

  // ---------------------------------------------------------------------------
  // Search highlight
  // ---------------------------------------------------------------------------

  void _highlightMessage(String messageId) {
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
    _scrollToMessage(messageId);
  }

  void _scrollToMessage(String messageId) {
    final key = _messageKeys[messageId];
    if (key?.currentContext != null) {
      Scrollable.ensureVisible(
        key!.currentContext!,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
        alignment: 0.3,
      );
      return;
    }

    // Target message is off-screen (not rendered by ListView.builder).
    // Find its index and estimate scroll position to jump near it.
    final conv = widget.conversation;
    if (conv == null || !_scrollController.hasClients) return;
    final chatState = ref.read(chatProvider);
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled = conv.isGroup && _selectedTextChannelId == null;
    final messages = _resolveMessages(
      conv,
      chatState,
      selectedChannelId,
      includeUnchanneled,
    );
    final index = messages.indexWhere((m) => m.id == messageId);
    if (index < 0) return;

    // +1 accounts for the loading indicator at index 0 in the ListView.
    final estimatedOffset = (index + 1) * 60.0;
    _scrollController.animateTo(
      estimatedOffset.clamp(0, _scrollController.position.maxScrollExtent),
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeOut,
    );

    // After the jump, retry with ensureVisible once the widget is rendered.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final retryKey = _messageKeys[messageId];
      if (retryKey?.currentContext != null) {
        Scrollable.ensureVisible(
          retryKey!.currentContext!,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
          alignment: 0.3,
        );
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Jump to reply quote
  // ---------------------------------------------------------------------------

  void _jumpToReplyQuote(String replyToId) {
    final conv = widget.conversation;
    if (conv == null) return;
    final chatState = ref.read(chatProvider);
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled = conv.isGroup && _selectedTextChannelId == null;
    final messages = _resolveMessages(
      conv,
      chatState,
      selectedChannelId,
      includeUnchanneled,
    );
    final index = messages.indexWhere((m) => m.id == replyToId);
    if (index < 0) {
      ToastService.show(
        context,
        'Original message not loaded',
        type: ToastType.info,
      );
      return;
    }
    _highlightMessage(replyToId);
  }

  // ---------------------------------------------------------------------------
  // Thread view
  // ---------------------------------------------------------------------------

  void _openThread(ChatMessage message) {
    final isMobile = Responsive.isMobile(context);
    if (isMobile) {
      final serverUrl = ref.read(serverUrlProvider);
      final authToken = ref.read(authProvider).token ?? '';
      showThreadBottomSheet(
        context: context,
        ref: ref,
        parentMessage: message,
        serverUrl: serverUrl,
        authToken: authToken,
        onReply: (msg) {
          ref.read(chatProvider.notifier).setReplyTo(msg);
          _chatInputBarKey.currentState?.requestInputFocus();
        },
      );
    } else {
      setState(() => _threadParent = message);
    }
  }

  // ---------------------------------------------------------------------------
  // Reaction picker
  // ---------------------------------------------------------------------------

  void _dismissReactionPicker() {
    _reactionOverlay?.remove();
    _reactionOverlay = null;
  }

  void _showReactionPicker(ChatMessage message, Offset tapPosition) {
    final conv = widget.conversation;
    if (conv == null) return;
    _dismissReactionPicker();

    final myUserId = ref.read(authProvider).userId ?? '';
    final overlay = Overlay.of(context);
    const pickerWidth = 385.0; // wider to accommodate the "+" button
    const pickerHeight = 44.0;
    final screenWidth = MediaQuery.of(context).size.width;

    final left = (tapPosition.dx - pickerWidth / 2).clamp(
      12.0,
      screenWidth - pickerWidth - 12,
    );
    final top = (tapPosition.dy - pickerHeight - 12).clamp(
      12.0,
      double.infinity,
    );

    _reactionOverlay = OverlayEntry(
      builder: (_) => Stack(
        children: [
          Positioned.fill(
            child: GestureDetector(
              onTap: () {
                _dismissReactionPicker();
                FocusManager.instance.primaryFocus?.unfocus();
              },
              behavior: HitTestBehavior.opaque,
              child: Container(color: Colors.black.withValues(alpha: 0.15)),
            ),
          ),
          Positioned(
            left: left,
            top: top,
            child: TweenAnimationBuilder<double>(
              tween: Tween(begin: 0, end: 1),
              duration: const Duration(milliseconds: 200),
              curve: Curves.easeOutCubic,
              builder: (_, value, child) => Opacity(
                opacity: value,
                child: Transform.translate(
                  offset: Offset(0, 8 * (1 - value)),
                  child: child,
                ),
              ),
              child: Container(
                height: pickerHeight,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                decoration: BoxDecoration(
                  color: context.surface.withValues(alpha: 0.95),
                  borderRadius: BorderRadius.circular(22),
                  border: Border.all(color: context.border),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.3),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    ...reactionEmojis.map((emoji) {
                      final alreadyReacted = message.reactions.any(
                        (r) => r.emoji == emoji && r.userId == myUserId,
                      );
                      return GestureDetector(
                        onTap: () {
                          _dismissReactionPicker();
                          _toggleReaction(message, emoji, alreadyReacted);
                          FocusManager.instance.primaryFocus?.unfocus();
                        },
                        child: Container(
                          width: 36,
                          height: 36,
                          margin: const EdgeInsets.symmetric(horizontal: 2),
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
                              fontSize: 22,
                              decoration: TextDecoration.none,
                            ),
                          ),
                        ),
                      );
                    }),
                    // Full emoji picker button
                    GestureDetector(
                      onTap: () {
                        _dismissReactionPicker();
                        _showFullReactionPicker(message, myUserId);
                      },
                      child: Container(
                        width: 36,
                        height: 36,
                        margin: const EdgeInsets.only(left: 4, right: 2),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(color: context.border, width: 1),
                        ),
                        alignment: Alignment.center,
                        child: Icon(
                          Icons.add,
                          size: 18,
                          color: context.textSecondary,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
    overlay.insert(_reactionOverlay!);
  }

  void _toggleReaction(ChatMessage message, String emoji, bool remove) {
    final conv = widget.conversation;
    if (conv == null) return;

    // Guard: the message may have been deleted via WebSocket between the
    // time the user opened the reaction picker and tapped an emoji.
    final stillExists = ref
        .read(chatProvider)
        .messagesForConversation(conv.id)
        .any((m) => m.id == message.id);
    if (!stillExists) return;

    final myUserId = ref.read(authProvider).userId ?? '';
    ref
        .read(websocketProvider.notifier)
        .sendReaction(conv.id, message.id, emoji);
    if (remove) {
      ref
          .read(chatProvider.notifier)
          .removeReaction(conv.id, message.id, myUserId, emoji);
    } else {
      ref
          .read(chatProvider.notifier)
          .addReaction(
            conv.id,
            Reaction(
              messageId: message.id,
              userId: myUserId,
              username: '',
              emoji: emoji,
            ),
          );
    }
  }

  void _showFullReactionPicker(ChatMessage message, String myUserId) {
    showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: context.surface,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (sheetContext) => SizedBox(
        height: 380,
        child: EmojiPicker(
          onEmojiSelected: (_, emoji) {
            Navigator.of(sheetContext).pop();
            final alreadyReacted = message.reactions.any(
              (r) => r.emoji == emoji.emoji && r.userId == myUserId,
            );
            _toggleReaction(message, emoji.emoji, alreadyReacted);
          },
          config: Config(
            height: 380,
            checkPlatformCompatibility: true,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: context.surface,
              columns: 9,
              emojiSizeMax: 28,
              verticalSpacing: 0,
              horizontalSpacing: 0,
              noRecents: Text(
                'No recents yet.',
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ),
            categoryViewConfig: CategoryViewConfig(
              initCategory: Category.SMILEYS,
              recentTabBehavior: RecentTabBehavior.RECENT,
              backgroundColor: context.surface,
              indicatorColor: context.accent,
              iconColorSelected: context.accent,
              iconColor: context.textMuted,
            ),
            skinToneConfig: SkinToneConfig(
              enabled: true,
              dialogBackgroundColor: context.surface,
              indicatorColor: context.accent,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            searchViewConfig: SearchViewConfig(
              backgroundColor: context.surface,
              buttonIconColor: context.textSecondary,
              hintText: 'Find an emoji...',
            ),
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Retry failed message
  // ---------------------------------------------------------------------------

  Future<void> _retryMessage(ChatMessage message) async {
    final conv = widget.conversation;
    if (conv == null) return;
    final chatNotifier = ref.read(chatProvider.notifier);
    chatNotifier.updateMessageStatus(
      conv.id,
      message.id,
      MessageStatus.sending,
    );
    try {
      final ws = ref.read(websocketProvider.notifier);
      if (conv.isGroup) {
        await ws.sendGroupMessage(
          conv.id,
          message.failedContent ?? message.content,
          channelId: message.channelId,
          replyToId: message.replyToId,
        );
      } else {
        final myUserId = ref.read(authProvider).userId ?? '';
        final peer = conv.members
            .where((m) => m.userId != myUserId)
            .firstOrNull;
        if (peer == null) return;
        await ws.sendMessage(
          peer.userId,
          message.failedContent ?? message.content,
          conversationId: conv.id,
          replyToId: message.replyToId,
        );
      }
    } catch (_) {
      ref
          .read(chatProvider.notifier)
          .updateMessageStatus(conv.id, message.id, MessageStatus.failed);
    }
  }

  void _deleteFailed(ChatMessage message) {
    final conv = widget.conversation;
    if (conv == null) return;
    ref.read(chatProvider.notifier).deleteMessage(conv.id, message.id);
  }

  // ---------------------------------------------------------------------------
  // Forward message
  // ---------------------------------------------------------------------------

  void _forwardMessage(ChatMessage message) {
    showForwardDialog(
      context: context,
      onForward: (target) => _sendForwardedMessage(message, target),
    );
  }

  Future<void> _sendForwardedMessage(
    ChatMessage message,
    Conversation target,
  ) async {
    final myUserId = ref.read(authProvider).userId ?? '';
    final ws = ref.read(websocketProvider.notifier);
    final content = message.content;

    try {
      await ref.read(chatProvider.notifier).forwardMessage(content, target.id, (
        forwardedContent,
      ) async {
        // Add optimistic message so the sender sees it locally immediately.
        String peerUserId = '';
        if (!target.isGroup) {
          final peer = target.members
              .where((m) => m.userId != myUserId)
              .firstOrNull;
          peerUserId = peer?.userId ?? '';
        }
        ref
            .read(chatProvider.notifier)
            .addOptimistic(
              peerUserId,
              forwardedContent,
              myUserId,
              conversationId: target.id,
            );

        if (target.isGroup) {
          await ws.sendGroupMessage(target.id, forwardedContent);
        } else {
          final peer = target.members
              .where((m) => m.userId != myUserId)
              .firstOrNull;
          if (peer == null) return;
          await ws.sendMessage(
            peer.userId,
            forwardedContent,
            conversationId: target.id,
          );
        }
      });

      if (mounted) {
        ToastService.show(
          context,
          'Message forwarded',
          type: ToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to forward message',
          type: ToastType.error,
        );
      }
    }
  }

  // ---------------------------------------------------------------------------
  // Delete confirmation
  // ---------------------------------------------------------------------------

  void _confirmDelete(ChatMessage message) {
    final conv = widget.conversation;
    if (conv == null) return;
    showDialog<_DeleteChoice>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: const Text('Delete message?'),
        actions: [
          Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              TextButton(
                onPressed: () => Navigator.pop(ctx, _DeleteChoice.forMe),
                child: Text(
                  'Delete for me',
                  style: TextStyle(color: context.textSecondary),
                ),
              ),
              if (message.isMine)
                TextButton(
                  onPressed: () =>
                      Navigator.pop(ctx, _DeleteChoice.forEveryone),
                  child: const Text(
                    'Delete for everyone',
                    style: TextStyle(color: EchoTheme.danger),
                  ),
                ),
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: Text(
                  'Cancel',
                  style: TextStyle(color: context.textSecondary),
                ),
              ),
            ],
          ),
        ],
      ),
    ).then((choice) {
      if (choice == null) return;
      if (choice == _DeleteChoice.forMe) {
        ref.read(chatProvider.notifier).deleteMessage(conv.id, message.id);
        MessageCache.removeMessage(conv.id, message.id);
        _addToDeletedForMe(message.id);
        if (mounted) {
          ToastService.show(
            context,
            'Message deleted for you',
            type: ToastType.info,
          );
        }
      } else {
        ref.read(chatProvider.notifier).deleteMessage(conv.id, message.id);
        final serverUrl = ref.read(serverUrlProvider);
        ref
            .read(authProvider.notifier)
            .authenticatedRequest(
              (token) => http.delete(
                Uri.parse('$serverUrl/api/messages/${message.id}'),
                headers: {'Authorization': 'Bearer $token'},
              ),
            );
        if (mounted) {
          ToastService.show(
            context,
            'Message deleted for everyone',
            type: ToastType.success,
          );
        }
      }
    });
  }

  // ---------------------------------------------------------------------------
  // Pin / Unpin
  // ---------------------------------------------------------------------------

  Future<void> _pinMessage(ChatMessage message) async {
    final conv = widget.conversation;
    if (conv == null) return;
    final myUserId = ref.read(authProvider).userId ?? '';
    final serverUrl = ref.read(serverUrlProvider);

    // Optimistically update local state
    ref
        .read(chatProvider.notifier)
        .updateMessagePin(conv.id, message.id, myUserId, DateTime.now());

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse(
                '$serverUrl/api/conversations/${conv.id}'
                '/messages/${message.id}/pin',
              ),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        ToastService.show(context, 'Message pinned', type: ToastType.success);
      } else {
        // Revert on failure
        ref
            .read(chatProvider.notifier)
            .updateMessagePin(conv.id, message.id, null, null);
        ToastService.show(
          context,
          'Failed to pin message',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ref
          .read(chatProvider.notifier)
          .updateMessagePin(conv.id, message.id, null, null);
      ToastService.show(
        context,
        'Failed to pin message',
        type: ToastType.error,
      );
    }
  }

  Future<void> _unpinMessage(ChatMessage message) async {
    final conv = widget.conversation;
    if (conv == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    // Save previous state for revert
    final prevPinnedById = message.pinnedById;
    final prevPinnedAt = message.pinnedAt;

    // Optimistically clear pin
    ref
        .read(chatProvider.notifier)
        .updateMessagePin(conv.id, message.id, null, null);

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse(
                '$serverUrl/api/conversations/${conv.id}'
                '/messages/${message.id}/pin',
              ),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (!mounted) return;
      if (response.statusCode >= 200 && response.statusCode < 300) {
        ToastService.show(context, 'Message unpinned', type: ToastType.success);
      } else {
        // Revert on failure
        ref
            .read(chatProvider.notifier)
            .updateMessagePin(
              conv.id,
              message.id,
              prevPinnedById,
              prevPinnedAt,
            );
        ToastService.show(
          context,
          'Failed to unpin message',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (!mounted) return;
      ref
          .read(chatProvider.notifier)
          .updateMessagePin(conv.id, message.id, prevPinnedById, prevPinnedAt);
      ToastService.show(
        context,
        'Failed to unpin message',
        type: ToastType.error,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Save / Unsave (local bookmarks)
  // ---------------------------------------------------------------------------

  Future<void> _saveMessage(ChatMessage message) async {
    await SavedMessagesService.instance.bookmark(message);
    if (!mounted) return;
    setState(() => _savedIds.add(message.id));
    ToastService.show(context, 'Message saved', type: ToastType.success);
  }

  Future<void> _unsaveMessage(ChatMessage message) async {
    await SavedMessagesService.instance.unsaveMessage(message.id);
    if (!mounted) return;
    setState(() => _savedIds.remove(message.id));
    ToastService.show(context, 'Bookmark removed', type: ToastType.info);
  }

  // ---------------------------------------------------------------------------
  // Image gallery
  // ---------------------------------------------------------------------------

  /// Collects all resolved image URLs from [messages] in order, then opens the
  /// gallery viewer starting at the image matching [tappedUrl].
  void _openImageGallery({
    required String tappedUrl,
    required List<ChatMessage> messages,
    required String serverUrl,
    required String authToken,
  }) {
    final headers = mediaHeaders(authToken: authToken);
    final mediaTicket = ref.read(mediaTicketProvider);

    // Build an ordered list of all image URLs from this message list.
    final allUrls = <String>[];
    for (final msg in messages) {
      // [img:URL] marker — single image message.
      final imgMatch = RegExp(r'^\[img:(.+)\]$').firstMatch(msg.content);
      if (imgMatch != null) {
        final raw = imgMatch.group(1)!;
        allUrls.add(
          resolveMediaUrl(
            raw,
            serverUrl: serverUrl,
            authToken: authToken,
            mediaTicket: mediaTicket,
          ),
        );
        continue;
      }

      // Standalone image URL (e.g. https://…/photo.png).
      if (isStandaloneMediaUrl(msg.content) && isImageUrl(msg.content.trim())) {
        allUrls.add(
          resolveMediaUrl(
            msg.content.trim(),
            serverUrl: serverUrl,
            authToken: authToken,
            mediaTicket: mediaTicket,
          ),
        );
        continue;
      }

      // Embedded image URLs mixed into text.
      for (final embUrl in extractEmbeddedImageUrls(msg.content)) {
        allUrls.add(embUrl);
      }
    }

    if (allUrls.isEmpty) {
      // Fallback: show only the tapped image.
      allUrls.add(tappedUrl);
    }

    // Find the index of the tapped URL. Use string-starts-with matching to
    // handle minor URL differences (e.g. trailing query params differ).
    final idx = allUrls.indexWhere(
      (u) =>
          u == tappedUrl || u.startsWith(tappedUrl) || tappedUrl.startsWith(u),
    );

    showImageGallery(
      context: context,
      imageUrls: allUrls,
      initialIndex: idx < 0 ? 0 : idx,
      headers: headers,
    );
  }

  // ---------------------------------------------------------------------------
  // Message list helpers
  // ---------------------------------------------------------------------------

  bool _isSystemTimelineMessage(ChatMessage msg) {
    return msg.content.startsWith('[system:');
  }

  Widget _buildSystemTimelineMessage(ChatMessage msg) {
    final text = msg.content.replaceFirst('[system:', '').replaceFirst(']', '');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 14, color: context.textMuted),
              const SizedBox(width: 6),
              Text(
                text.trim(),
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }

  bool _withinGroupingWindow(String ts1, String ts2) {
    try {
      final dt1 = DateTime.parse(ts1);
      final dt2 = DateTime.parse(ts2);
      return dt2.difference(dt1).inMinutes.abs() < 5;
    } catch (_) {
      return false;
    }
  }

  bool _differentDay(String ts1, String ts2) {
    try {
      final d1 = DateTime.parse(ts1);
      final d2 = DateTime.parse(ts2);
      return d1.year != d2.year || d1.month != d2.month || d1.day != d2.day;
    } catch (_) {
      return false;
    }
  }

  Widget _buildDateDivider(String timestamp) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      String label;
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        label = 'Today';
      } else if (dt.year == yesterday.year &&
          dt.month == yesterday.month &&
          dt.day == yesterday.day) {
        label = 'Yesterday';
      } else {
        label = '${_fullMonthName(dt.month)} ${dt.day}, ${dt.year}';
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: context.border.withValues(alpha: 0.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: context.textMuted),
              ),
            ),
            Expanded(
              child: Container(
                height: 1,
                color: context.border.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  Widget _buildUnreadDivider(int count) {
    final noun = count == 1 ? 'message' : 'messages';
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 16),
      child: Row(
        children: [
          Expanded(child: Divider(color: context.accent, height: 1)),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Text(
              '$count new $noun',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: context.accent,
              ),
            ),
          ),
          Expanded(child: Divider(color: context.accent, height: 1)),
        ],
      ),
    );
  }

  String _fullMonthName(int m) {
    const names = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return names[m.clamp(1, 12)];
  }

  // ---------------------------------------------------------------------------
  // Build helpers
  // ---------------------------------------------------------------------------

  Widget _buildNoConversationPlaceholder() {
    final gradient = context.chatBgGradient;
    return DecoratedBox(
      decoration: gradient != null
          ? BoxDecoration(gradient: gradient)
          : BoxDecoration(color: context.chatBg),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_rounded,
              size: 56,
              color: context.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 20),
            Text(
              'No conversation selected',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Choose a conversation from the sidebar or start a new one',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyMessagePlaceholder(String displayName) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          CircleAvatar(
            radius: 28,
            backgroundColor: context.accent,
            child: Text(
              displayName.isNotEmpty ? displayName[0].toUpperCase() : '?',
              style: const TextStyle(fontSize: 22, color: Colors.white),
            ),
          ),
          const SizedBox(height: 12),
          Text(
            displayName,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Start your conversation with $displayName',
            style: TextStyle(color: context.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 16),
          Semantics(
            label: 'Say hi to $displayName',
            button: true,
            child: TextButton(
              onPressed: () {
                _chatInputBarKey.currentState?.preFillText('Hey! \u{1F44B}');
              },
              style: TextButton.styleFrom(
                foregroundColor: context.accent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 10,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(20),
                  side: BorderSide(
                    color: context.accent.withValues(alpha: 0.4),
                  ),
                ),
              ),
              child: const Text(
                'Say hi \u{1F44B}',
                style: TextStyle(fontSize: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMessageAtIndex({
    required int i,
    required List<ChatMessage> messages,
    required Map<String, String?> memberAvatars,
    required String myUserId,
    required String serverUrl,
    required String authToken,
    String? mediaTicket,
  }) {
    final msg = messages[i];

    if (_isSystemTimelineMessage(msg)) {
      return _buildSystemTimelineMessage(msg);
    }

    final needsDateDivider =
        i == 0 || _differentDay(messages[i - 1].timestamp, msg.timestamp);

    final showHeader =
        i == 0 ||
        messages[i - 1].fromUserId != msg.fromUserId ||
        !_withinGroupingWindow(messages[i - 1].timestamp, msg.timestamp);

    final isLastInGroup =
        i == messages.length - 1 ||
        messages[i + 1].fromUserId != msg.fromUserId;

    final senderAvatarUrl = memberAvatars[msg.fromUserId];
    final isHighlighted = _highlightedMessageId == msg.id;

    final showUnreadDivider = _unreadBoundaryMessageId == msg.id;

    final messageKey = _messageKeys.putIfAbsent(msg.id, () => GlobalKey());

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        if (needsDateDivider) _buildDateDivider(msg.timestamp),
        if (showUnreadDivider) _buildUnreadDivider(_unreadBoundaryCount),
        AnimatedContainer(
          key: messageKey,
          duration: const Duration(milliseconds: 400),
          color: isHighlighted
              ? context.accent.withValues(alpha: 0.15)
              : Colors.transparent,
          child: MessageItem(
            message: msg,
            showHeader: showHeader,
            isLastInGroup: isLastInGroup,
            myUserId: myUserId,
            serverUrl: serverUrl,
            authToken: authToken,
            mediaTicket: mediaTicket,
            senderAvatarUrl: senderAvatarUrl,
            compactLayout:
                ref.watch(messageLayoutProvider) == MessageLayout.compact,
            onReactionTap: _showReactionPicker,
            onReactionSelect: (message, emoji) {
              final alreadyReacted = message.reactions.any(
                (r) => r.emoji == emoji && r.userId == myUserId,
              );
              _toggleReaction(message, emoji, alreadyReacted);
            },
            onDelete: msg.status == MessageStatus.failed
                ? _deleteFailed
                : _confirmDelete,
            onRetry: msg.status == MessageStatus.failed ? _retryMessage : null,
            onEdit: (msg) {
              _chatInputBarKey.currentState?.enterEditMode(msg);
            },
            onReply: (msg) {
              ref.read(chatProvider.notifier).setReplyTo(msg);
              _chatInputBarKey.currentState?.requestInputFocus();
            },
            onViewThread: (msg) => _openThread(msg),
            onPin: (msg) => _pinMessage(msg),
            onUnpin: (msg) => _unpinMessage(msg),
            onForward: (msg) => _forwardMessage(msg),
            isSaved:
                _savedIds.contains(msg.id) ||
                SavedMessagesService.instance.isMessageSaved(msg.id),
            onSave: (msg) => _saveMessage(msg),
            onUnsave: (msg) => _unsaveMessage(msg),
            onTapReplyQuote: _jumpToReplyQuote,
            onAvatarTap: (userId) {
              UserProfileScreen.show(context, ref, userId);
            },
            onImageTap: (resolvedUrl) => _openImageGallery(
              tappedUrl: resolvedUrl,
              messages: messages,
              serverUrl: serverUrl,
              authToken: authToken,
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildMessageListView({
    required Conversation conv,
    required List<ChatMessage> messages,
    required ChatState chatState,
    required Map<String, String?> memberAvatars,
    required String myUserId,
    required String serverUrl,
    required String authToken,
    String? mediaTicket,
  }) {
    return Scrollbar(
      controller: _scrollController,
      thumbVisibility: defaultTargetPlatform != TargetPlatform.iOS,
      child: ListView.builder(
        controller: _scrollController,
        padding: const EdgeInsets.only(bottom: 16),
        itemCount: messages.length + 1,
        itemBuilder: (context, index) {
          if (index == 0) {
            if (chatState.hasMore[conv.id] ?? true) {
              return SizedBox(
                height: 48,
                child: (chatState.loadingHistory[conv.id] ?? false)
                    ? const Center(
                        child: SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(strokeWidth: 2),
                        ),
                      )
                    : const SizedBox.shrink(),
              );
            }
            return const SizedBox(height: 8);
          }
          return _buildMessageAtIndex(
            i: index - 1,
            messages: messages,
            memberAvatars: memberAvatars,
            myUserId: myUserId,
            serverUrl: serverUrl,
            authToken: authToken,
            mediaTicket: mediaTicket,
          );
        },
      ),
    );
  }

  Widget _buildMessageListOrEmpty({
    required Conversation conv,
    required List<ChatMessage> messages,
    required bool isLoadingHistory,
    required String displayName,
    required ChatState chatState,
    required Map<String, String?> memberAvatars,
    required String myUserId,
    required String serverUrl,
    required String authToken,
    String? mediaTicket,
  }) {
    final Widget child;
    if (messages.isEmpty && isLoadingHistory) {
      child = const SingleChildScrollView(
        key: ValueKey('skeleton'),
        child: MessageListSkeleton(),
      );
    } else if (messages.isEmpty && !isLoadingHistory) {
      child = KeyedSubtree(
        key: const ValueKey('empty'),
        child: _buildEmptyMessagePlaceholder(displayName),
      );
    } else {
      child = KeyedSubtree(
        key: const ValueKey('list'),
        child: _buildMessageListView(
          conv: conv,
          messages: messages,
          chatState: chatState,
          memberAvatars: memberAvatars,
          myUserId: myUserId,
          serverUrl: serverUrl,
          authToken: authToken,
          mediaTicket: mediaTicket,
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }

  void _handleKeyboardScroll() {
    final keyboardInset = MediaQuery.of(context).viewInsets.bottom;
    if (keyboardInset != _lastKeyboardInset) {
      // Use the pre-resize near-bottom state captured in _onScroll, not the
      // current value (which is unreliable after the viewport has already shrunk).
      final wasNearBottom = _wasNearBottom;
      _lastKeyboardInset = keyboardInset;
      final inlinePickerActive =
          _chatInputBarKey.currentState?.showInlinePicker ?? false;
      if (wasNearBottom && !inlinePickerActive) {
        _scrollToBottom(animated: false, settleRetries: 2);
      }
    }
  }

  void _setupAutoScroll(
    Conversation conv,
    String? selectedChannelId,
    bool includeUnchanneled,
  ) {
    final key = '${conv.id}:${selectedChannelId ?? ""}';
    if (_autoScrollConversationKey == key) return;
    _autoScrollConversationKey = key;

    ref.listen<ChatState>(chatProvider, (prev, next) {
      int visibleCount(ChatState s) {
        if (!conv.isGroup) return s.messagesForConversation(conv.id).length;
        return s
            .messagesForConversationChannel(
              conv.id,
              channelId: selectedChannelId,
              includeUnchanneled: includeUnchanneled,
            )
            .length;
      }

      final prevCount = prev == null ? 0 : visibleCount(prev);
      final nextCount = visibleCount(next);

      // Attempt to capture unread boundary when messages first arrive
      // (e.g. history loaded asynchronously after conversation opened).
      if (prevCount == 0 && nextCount > 0 && _unreadBoundaryMessageId == null) {
        _captureUnreadBoundary();
        if (_unreadBoundaryMessageId != null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _scrollToUnreadBoundary();
          });
          return;
        }
      }

      if (nextCount > prevCount) {
        if (_isNearBottom()) {
          _scrollToBottom(settleRetries: 3);
        } else {
          setState(() {
            _hasNewMessagesBelow = true;
            _newMessagesBelowCount += nextCount - prevCount;
          });
        }
      }
    });
  }

  String _displayNameFor(Conversation conv, String myUserId) {
    if (conv.isGroup) return conv.name ?? 'Group';
    return conv.members
            .where((m) => m.userId != myUserId)
            .firstOrNull
            ?.username ??
        'Chat';
  }

  /// LiveKit handles remote audio playback automatically -- no hidden renderer
  /// widgets needed (unlike the legacy P2P WebRTC approach).
  List<Widget> _buildVoiceRenderers() => const [];

  // ---------------------------------------------------------------------------
  // Drag-and-drop file upload
  // ---------------------------------------------------------------------------

  /// Called when files are dropped onto the chat area. Forwards all dropped
  /// files to the input bar's attachment flow, one after another.
  Future<void> _onDropDone(DropDoneDetails details) async {
    if (details.files.isEmpty) return;

    final inputBar = _chatInputBarKey.currentState;
    if (inputBar == null) return;

    // Filter out directories before processing.
    final items = details.files.where((f) => f is! DropItemDirectory).toList();
    if (items.isEmpty) return;

    for (final item in items) {
      // On web, DropItem may carry bytes directly (no filesystem path).
      Uint8List? bytes;
      if (kIsWeb) {
        try {
          bytes = await item.readAsBytes();
        } catch (_) {}
      }

      await inputBar.attachDroppedFile(
        path: item.path,
        fileName: item.name,
        bytes: bytes,
      );
    }
  }

  /// Overlay shown when dragging a file over the chat panel.
  Widget _buildDropOverlay() {
    return Positioned.fill(
      child: IgnorePointer(
        child: AnimatedOpacity(
          opacity: _isDragOver ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 150),
          child: Container(
            color: Colors.black.withValues(alpha: 0.45),
            child: Center(
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 20,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.75),
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.4),
                    width: 2,
                  ),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.upload_file_outlined,
                      size: 40,
                      color: Colors.white.withValues(alpha: 0.9),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      'Drop file to send',
                      style: TextStyle(
                        color: Colors.white.withValues(alpha: 0.95),
                        fontSize: 18,
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

  /// Floating date pill shown at the top while scrolling.
  Widget _buildFloatingDatePill() {
    return Positioned(
      top: 8,
      left: 0,
      right: 0,
      child: Center(
        child: AnimatedOpacity(
          opacity: _floatingDateVisible ? 1.0 : 0.0,
          duration: const Duration(milliseconds: 200),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            decoration: BoxDecoration(
              color: context.surface.withValues(alpha: 0.92),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: context.border),
            ),
            child: Text(
              _floatingDate ?? '',
              style: TextStyle(fontSize: 11, color: context.textMuted),
            ),
          ),
        ),
      ),
    );
  }

  /// Floating pill shown when new messages arrive below the scroll viewport.
  Widget _buildNewMessagesPill() {
    return Positioned(
      bottom: 12,
      right: 24,
      child: Align(
        alignment: Alignment.centerRight,
        child: Semantics(
          label: 'scroll to new messages',
          button: true,
          child: GestureDetector(
            onTap: () => _scrollToBottom(settleRetries: 2),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              decoration: BoxDecoration(
                color: context.accent,
                borderRadius: BorderRadius.circular(20),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.25),
                    blurRadius: 8,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    _newMessagesBannerText(),
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  const SizedBox(width: 4),
                  const Icon(
                    Icons.arrow_downward,
                    size: 14,
                    color: Colors.white,
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Resolve messages for the current conversation and channel.
  /// Filters out messages the user has deleted locally ("delete for me").
  List<ChatMessage> _resolveMessages(
    Conversation conv,
    ChatState chatState,
    String? selectedChannelId,
    bool includeUnchanneled,
  ) {
    final List<ChatMessage> raw;
    if (conv.isGroup) {
      raw = chatState.messagesForConversationChannel(
        conv.id,
        channelId: selectedChannelId,
        includeUnchanneled: includeUnchanneled,
      );
    } else {
      raw = chatState.messagesForConversation(conv.id);
    }
    if (_deletedForMeIds.isEmpty) return raw;
    return raw.where((m) => !_deletedForMeIds.contains(m.id)).toList();
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;

    if (conv == null) return _buildNoConversationPlaceholder();

    // Load on first build + scroll to newest message (or unread boundary)
    if (_loadedHistoryKey == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadHistory();
        _loadChannels();
        // Capture unread boundary before marking as read (which resets count)
        _captureUnreadBoundary();
        _markAsRead();
        if (_unreadBoundaryMessageId != null) {
          _scrollToUnreadBoundary();
        } else {
          _scrollToBottom(settleRetries: 3);
        }
      });
    }

    _handleKeyboardScroll();

    final myUserId = ref.watch(authProvider.select((s) => s.userId)) ?? '';
    final authToken = ref.watch(authProvider.select((s) => s.token)) ?? '';
    final serverUrl = ref.watch(serverUrlProvider);
    final mediaTicket = ref.watch(mediaTicketProvider);
    final selectedChannelId = conv.isGroup ? _selectedTextChannelId : null;
    final includeUnchanneled = conv.isGroup && _selectedTextChannelId == null;

    // Only rebuild when typing users for THIS conversation change,
    // not on isConnected/onlineUsers/wasReplaced changes.
    final typingUserIds = ref.watch(
      websocketProvider.select(
        (s) => s.typingIn(conv.id, channelId: selectedChannelId),
      ),
    );

    final chatState = ref.watch(chatProvider);
    final messages = _resolveMessages(
      conv,
      chatState,
      selectedChannelId,
      includeUnchanneled,
    );

    final isLoadingHistory = chatState.loadingHistory[conv.id] ?? false;

    final typingUsers = typingUserIds.where((u) => u != myUserId).map((uid) {
      final member = conv.members.where((m) => m.userId == uid).firstOrNull;
      return member?.username ?? uid;
    }).toList();

    _setupAutoScroll(conv, selectedChannelId, includeUnchanneled);

    final displayName = _displayNameFor(conv, myUserId);

    final memberAvatars = <String, String?>{};
    for (final m in conv.members) {
      memberAvatars[m.userId] = m.avatarUrl;
    }

    final chatGradient = context.chatBgGradient;

    final chatContentBox = DecoratedBox(
      decoration: chatGradient != null
          ? BoxDecoration(gradient: chatGradient)
          : BoxDecoration(color: context.chatBg),
      child: Stack(
        children: [
          Column(
            children: [
              ChatHeaderBar(
                conversation: conv,
                myUserId: myUserId,
                serverUrl: serverUrl,
                onBack: widget.onBack,
                showSearch: _showSearch,
                onToggleSearch: () =>
                    setState(() => _showSearch = !_showSearch),
                onMembersToggle: widget.onMembersToggle,
                onGroupInfo: widget.onGroupInfo,
                onDismissEncryptionBanner: _dismissEncryptionBanner,
                hideEncryptionBanner: _hideEncryptionBanner,
              ),

              if (conv.isGroup)
                ChannelBar(
                  conversationId: conv.id,
                  selectedTextChannelId: _selectedTextChannelId,
                  activeVoiceChannelId: _activeVoiceChannelId,
                  hideVoiceDock: widget.hideVoiceDock,
                  onTextChannelChanged: _onTextChannelChanged,
                  onVoiceChannelChanged: (channelId) {
                    if (mounted) {
                      setState(() => _activeVoiceChannelId = channelId);
                    }
                  },
                  onShowLounge: widget.onShowLounge,
                ),

              if (_showSearch)
                MessageSearchOverlay(
                  conversationId: conv.id,
                  onMessageSelected: (messageId) {
                    setState(() => _showSearch = false);
                    _highlightMessage(messageId);
                  },
                  onClose: () => setState(() => _showSearch = false),
                ),

              if (isLoadingHistory)
                LinearProgressIndicator(
                  minHeight: 2,
                  color: context.accent,
                  backgroundColor: context.surface,
                ),

              const ConnectionStatusBanner(),
              const CryptoDegradedBanner(),
              if (!conv.isGroup) IdentityKeyChangedBanner(conversation: conv),

              Expanded(
                child: GestureDetector(
                  onTap: () => FocusScope.of(context).unfocus(),
                  child: Stack(
                    children: [
                      _buildMessageListOrEmpty(
                        conv: conv,
                        messages: messages,
                        isLoadingHistory: isLoadingHistory,
                        displayName: displayName,
                        chatState: chatState,
                        memberAvatars: memberAvatars,
                        myUserId: myUserId,
                        serverUrl: serverUrl,
                        authToken: authToken,
                        mediaTicket: mediaTicket,
                      ),
                      if (_floatingDate != null) _buildFloatingDatePill(),
                      if (_hasNewMessagesBelow) _buildNewMessagesPill(),
                    ],
                  ),
                ),
              ),

              ChatInputBar(
                key: _chatInputBarKey,
                conversation: conv,
                selectedTextChannelId: _selectedTextChannelId,
                effectiveActiveVoiceChannelId: _activeVoiceChannelId,
                typingUsers: typingUsers,
                onMessageSent: () {
                  _scrollToBottom(settleRetries: 2);
                  _markAsRead();
                },
                onMediaPickerChanged: () {
                  setState(() {});
                  // Scroll to bottom when inline picker appears/disappears
                  // so the latest messages stay visible.
                  WidgetsBinding.instance.addPostFrameCallback((_) {
                    _scrollToBottom(settleRetries: 2);
                  });
                },
              ),

              ..._buildVoiceRenderers(),
            ],
          ),
          // Floating emoji/GIF picker — rendered above the message list so taps
          // aren't absorbed by the ListView's gesture recognizers.
          if (_chatInputBarKey.currentState?.showMediaPicker ?? false)
            Positioned(
              bottom: 80,
              right: 16,
              child: _chatInputBarKey.currentState!.buildMediaPickerPanel(),
            ),
          // Drag-and-drop overlay
          if (_isDragOver) _buildDropOverlay(),
        ],
      ),
    );

    // Compose the chat content with optional thread panel.
    final Widget chatContent;
    if (_threadParent != null && !Responsive.isMobile(context)) {
      chatContent = Row(
        children: [
          Expanded(child: chatContentBox),
          ThreadViewPanel(
            parentMessage: _threadParent!,
            serverUrl: serverUrl,
            authToken: authToken,
            onReply: (msg) {
              ref.read(chatProvider.notifier).setReplyTo(msg);
              _chatInputBarKey.currentState?.requestInputFocus();
            },
            onClose: () => setState(() => _threadParent = null),
          ),
        ],
      );
    } else {
      chatContent = chatContentBox;
    }

    // Wrap in DropTarget on desktop and web only. Mobile platforms don't
    // support external file drag-and-drop, so skip to avoid unnecessary
    // platform channel setup.
    final dropSupported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;

    if (!dropSupported) return chatContent;

    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragOver = true),
      onDragExited: (_) => setState(() => _isDragOver = false),
      onDragDone: (details) {
        setState(() => _isDragOver = false);
        _onDropDone(details);
      },
      child: chatContent,
    );
  }
}

enum _DeleteChoice { forMe, forEveryone }
