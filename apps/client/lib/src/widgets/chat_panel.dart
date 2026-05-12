import 'dart:async';

import 'package:desktop_drop/desktop_drop.dart';
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/chat_message.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/media_ticket_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/responsive.dart';
import 'chat_input_bar.dart';
import 'chat_panel_controller.dart';
import 'chat_panel/chat_panel_body.dart';
import 'chat_panel/deleted_for_me_storage.dart';
import 'chat_panel/drop_handler.dart';
import 'chat_panel/history_loaders.dart' as history;
import 'chat_panel/message_actions.dart' as actions;
import 'chat_panel/no_conversation_placeholder.dart';
import 'chat_panel/reaction_picker_overlay.dart';
import 'chat_panel/scroll_helpers.dart' as sh;
import 'thread_view_panel.dart';

class ChatPanel extends ConsumerStatefulWidget {
  final Conversation? conversation;
  final VoidCallback? onMembersToggle;
  final VoidCallback? onGroupInfo;
  final VoidCallback? onBack;
  final VoidCallback? onShowLounge;
  final bool hideVoiceDock;

  /// When set, the panel scrolls to and briefly highlights this message
  /// after the conversation finishes loading.
  final String? initialMessageId;

  const ChatPanel({
    super.key,
    this.conversation,
    this.onMembersToggle,
    this.onGroupInfo,
    this.onBack,
    this.onShowLounge,
    this.hideVoiceDock = false,
    this.initialMessageId,
  });

  @override
  ConsumerState<ChatPanel> createState() => _ChatPanelState();
}

class _ChatPanelState extends ConsumerState<ChatPanel>
    with WidgetsBindingObserver {
  final _scrollController = ScrollController();
  final _chatInputBarKey = GlobalKey<ChatInputBarState>();
  final _controller = ChatPanelController();

  String _newMessagesBannerText() {
    if (_newMessagesBelowCount <= 0) return 'New messages';
    final noun = _newMessagesBelowCount == 1 ? 'message' : 'messages';
    return '$_newMessagesBelowCount new $noun';
  }

  Set<String> get _dismissedBannerIds => DismissedBannersStorage.ids;
  String? get _selectedTextChannelId => _controller.selectedTextChannelId;
  set _selectedTextChannelId(String? v) =>
      _controller.selectedTextChannelId = v;
  String? get _loadedHistoryKey => _controller.loadedHistoryKey;
  set _loadedHistoryKey(String? v) => _controller.loadedHistoryKey = v;
  String? get _loadedChannelsConversationId =>
      _controller.loadedChannelsConversationId;
  set _loadedChannelsConversationId(String? v) =>
      _controller.loadedChannelsConversationId = v;
  String? _activeVoiceChannelId;

  String? get _unreadBoundaryMessageId => _controller.unreadBoundaryMessageId;
  set _unreadBoundaryMessageId(String? v) =>
      _controller.unreadBoundaryMessageId = v;
  int get _unreadBoundaryCount => _controller.unreadBoundaryCount;
  set _unreadBoundaryCount(int v) => _controller.unreadBoundaryCount = v;

  // GlobalKeys for rendered message items, keyed by ID. Used by
  // `_scrollToMessage` for pixel-accurate scrolling and by
  // `_updateFloatingDate` to detect the topmost visible message.
  final _messageKeys = <String, GlobalKey>{};

  bool _showSearch = false;
  ChatMessage? _threadParent;
  String? _highlightedMessageId;
  String? _pendingInitialMessageId;
  Timer? _highlightTimer;
  double get _lastKeyboardInset => _controller.lastKeyboardInset;
  set _lastKeyboardInset(double v) => _controller.lastKeyboardInset = v;
  bool _isDragOver = false;
  final Set<String> _savedIds = {};
  String? get _floatingDate => _controller.floatingDate;
  bool get _floatingDateVisible => _controller.floatingDateVisible;
  bool get _wasNearBottom => _controller.wasNearBottom;
  set _wasNearBottom(bool v) => _controller.wasNearBottom = v;
  bool get _hasNewMessagesBelow => _controller.hasNewMessagesBelow;
  set _hasNewMessagesBelow(bool v) => _controller.hasNewMessagesBelow = v;
  int get _newMessagesBelowCount => _controller.newMessagesBelowCount;
  set _newMessagesBelowCount(int v) => _controller.newMessagesBelowCount = v;
  // Hidden Semantics live-region label (#495). Cleared ~3s after each
  // announcement so a window-focus event doesn't replay the stale label.
  String _liveRegionAnnouncement = '';
  String? _lastAnnouncedMessageId;
  Timer? _liveRegionClearTimer;
  OverlayEntry? _reactionOverlay;

  bool get _hideEncryptionBanner {
    final convId = widget.conversation?.id;
    return convId != null && _dismissedBannerIds.contains(convId);
  }

  Future<void> _dismissEncryptionBanner() async {
    final convId = widget.conversation?.id;
    if (convId == null) return;
    setState(() {});
    await DismissedBannersStorage.add(convId);
  }

  @override
  void initState() {
    super.initState();
    _controller.attachScrollController(_scrollController);
    _controller.deletedForMeIds = DeletedForMeStorage.ids;
    _scrollController.addListener(_onScroll);
    WidgetsBinding.instance.addObserver(this);
    DismissedBannersStorage.ensureLoaded();
    DeletedForMeStorage.ensureLoaded().then((_) {
      if (mounted) _controller.deletedForMeIds = DeletedForMeStorage.ids;
    });
    _pendingInitialMessageId = widget.initialMessageId;
  }

  @override
  void didUpdateWidget(covariant ChatPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.conversation?.id != oldWidget.conversation?.id) {
      // Save scroll offset for the old conversation+channel
      final oldId = oldWidget.conversation?.id;
      if (oldId != null) {
        _controller.cacheCurrentOffset(oldId);
      }

      _selectedTextChannelId = null;
      _activeVoiceChannelId = null;
      _loadedHistoryKey = null;
      _controller.autoScrollConversationKey = null;
      _showSearch = false;
      _threadParent = null;
      _highlightedMessageId = null;
      _pendingInitialMessageId = widget.initialMessageId;
      _hasNewMessagesBelow = false;
      _newMessagesBelowCount = 0;
      _unreadBoundaryMessageId = null;
      _unreadBoundaryCount = 0;
      _controller.floatingDate = null;
      _controller.floatingDateVisible = false;
      _controller.floatingDateTimer?.cancel();
      _highlightTimer?.cancel();
      _messageKeys.clear();
      _liveRegionAnnouncement = '';
      _lastAnnouncedMessageId = null;
      _liveRegionClearTimer?.cancel();
      _dismissReactionPicker();

      // Restore cached scroll position for the new conversation, or scroll
      // to bottom if no cached position exists. If there's an unread boundary,
      // defer to the first-load callback which scrolls to the divider.
      final newId = widget.conversation?.id;
      if (newId != null) {
        final cached =
            _controller.scrollPositions[_controller.cacheKeyFor(newId)];
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
            _controller.restoreCachedOffsetWithRetry(cached);
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
    _liveRegionClearTimer?.cancel();
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    _controller.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    super.didChangeAppLifecycleState(state);
    if (state == AppLifecycleState.resumed && widget.conversation != null) {
      _markAsRead();
    }
  }

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
    if (conv == null) return;
    sh.updateFloatingDate(
      ref: ref,
      conv: conv,
      scrollController: _scrollController,
      messageKeys: _messageKeys,
      selectedTextChannelId: _selectedTextChannelId,
      resolveMessages: _resolveMessages,
      controller: _controller,
      setState: setState,
      mounted: () => mounted,
    );
  }

  void _scrollToBottom({bool animated = true, int settleRetries = 3}) {
    _controller.scrollToBottom(
      conversationId: widget.conversation?.id,
      animated: animated,
      settleRetries: settleRetries,
      onSettleComplete: () {
        if (_hasNewMessagesBelow) {
          setState(() {
            _hasNewMessagesBelow = false;
            _newMessagesBelowCount = 0;
          });
        }
      },
    );
  }

  bool _isNearBottom() => _controller.isNearBottom();

  void _loadHistory() {
    final conv = widget.conversation;
    if (conv == null) return;
    final key = '${conv.id}:${_selectedTextChannelId ?? ""}';
    if (key == _loadedHistoryKey) return;
    _loadedHistoryKey = key;
    // Capture unread boundary from cached messages before they are marked read.
    _captureUnreadBoundary();
    history.loadHistory(
      ref: ref,
      conv: conv,
      selectedTextChannelId: _selectedTextChannelId,
    );
  }

  void _loadChannels() {
    final conv = widget.conversation;
    if (conv == null || !conv.isGroup) return;
    if (conv.id == _loadedChannelsConversationId) return;
    _loadedChannelsConversationId = conv.id;
    history.loadChannels(ref: ref, conv: conv);
  }

  void _loadOlderMessages() {
    final conv = widget.conversation;
    if (conv == null) return;
    history.loadOlderMessages(
      ref: ref,
      conv: conv,
      selectedTextChannelId: _selectedTextChannelId,
      controller: _controller,
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

  void _captureUnreadBoundary() {
    final conv = widget.conversation;
    if (conv == null) return;
    sh.captureUnreadBoundary(
      ref: ref,
      conv: conv,
      selectedTextChannelId: _selectedTextChannelId,
      controller: _controller,
      resolveMessages: _resolveMessages,
      setState: setState,
    );
  }

  void _scrollToUnreadBoundary() {
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
    sh.scrollToUnreadBoundary(
      scrollController: _scrollController,
      messageKeys: _messageKeys,
      messages: messages,
      unreadBoundaryMessageId: _unreadBoundaryMessageId,
    );
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

  void _highlightMessage(String messageId) {
    setState(() => _highlightedMessageId = messageId);
    _highlightTimer?.cancel();
    _highlightTimer = Timer(const Duration(seconds: 3), () {
      if (mounted) setState(() => _highlightedMessageId = null);
    });
    _scrollToMessage(messageId);
  }

  void _scrollToMessage(String messageId) {
    final conv = widget.conversation;
    final chatState = ref.read(chatProvider);
    final selectedChannelId = conv != null && conv.isGroup
        ? _selectedTextChannelId
        : null;
    final includeUnchanneled =
        conv != null && conv.isGroup && _selectedTextChannelId == null;
    final messages = conv == null
        ? const <ChatMessage>[]
        : _resolveMessages(
            conv,
            chatState,
            selectedChannelId,
            includeUnchanneled,
          );
    sh.scrollToMessage(
      messageId: messageId,
      scrollController: _scrollController,
      messageKeys: _messageKeys,
      messages: messages,
    );
  }

  Future<void> _jumpToReplyQuote(String replyToId) async {
    final conv = widget.conversation;
    if (conv == null) return;
    await history.jumpToReplyQuote(
      context: context,
      ref: ref,
      conv: conv,
      selectedTextChannelId: _selectedTextChannelId,
      controller: _controller,
      replyToId: replyToId,
      resolveMessages: _resolveMessages,
      mounted: () => mounted,
      onHighlight: () => _highlightMessage(replyToId),
    );
  }

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

  void _dismissReactionPicker() {
    _reactionOverlay?.remove();
    _reactionOverlay = null;
  }

  void _showReactionPicker(ChatMessage message, Offset tapPosition) {
    final conv = widget.conversation;
    if (conv == null) return;
    _dismissReactionPicker();
    final myUserId = ref.read(authProvider).userId ?? '';
    _reactionOverlay = buildReactionPickerOverlay(
      context: context,
      message: message,
      myUserId: myUserId,
      tapPosition: tapPosition,
      onDismiss: _dismissReactionPicker,
      onToggleReaction: (emoji, already) =>
          _toggleReaction(message, emoji, already),
      onPickFromFull: () => _showFullReactionPicker(message, myUserId),
    );
    Overlay.of(context).insert(_reactionOverlay!);
  }

  void _toggleReaction(ChatMessage message, String emoji, bool remove) {
    final conv = widget.conversation;
    if (conv == null) return;
    actions.toggleReaction(
      ref: ref,
      conv: conv,
      message: message,
      emoji: emoji,
      remove: remove,
    );
  }

  void _showFullReactionPicker(ChatMessage message, String myUserId) {
    actions.showFullReactionPickerFor(
      context: context,
      message: message,
      myUserId: myUserId,
      onPick: (emoji, alreadyReacted) =>
          _toggleReaction(message, emoji, alreadyReacted),
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
    sh.setupAutoScroll(
      ref: ref,
      conv: conv,
      selectedChannelId: selectedChannelId,
      includeUnchanneled: includeUnchanneled,
      controller: _controller,
      getLastAnnouncedMessageId: () => _lastAnnouncedMessageId,
      setLastAnnouncedMessageId: (v) => _lastAnnouncedMessageId = v,
      setLiveRegionAnnouncement: (v) => _liveRegionAnnouncement = v,
      getLiveRegionClearTimer: () => _liveRegionClearTimer,
      setLiveRegionClearTimer: (t) => _liveRegionClearTimer = t,
      isNearBottom: _isNearBottom,
      scrollToBottom: () => _scrollToBottom(settleRetries: 3),
      onCaptureUnreadBoundary: _captureUnreadBoundary,
      onScrollToUnreadBoundary: _scrollToUnreadBoundary,
      setState: setState,
      mounted: () => mounted,
    );
  }

  String _displayNameFor(Conversation conv, String myUserId) => conv.isGroup
      ? (conv.name ?? 'Group')
      : (conv.members
                .where((m) => m.userId != myUserId)
                .firstOrNull
                ?.username ??
            'Chat');

  List<ChatMessage> _resolveMessages(
    Conversation conv,
    ChatState chatState,
    String? selectedChannelId,
    bool includeUnchanneled,
  ) => _controller.resolveMessages(
    conv,
    chatState,
    selectedChannelId,
    includeUnchanneled,
  );

  List<ChatMessage> _filterChannelAndDeleted(
    Conversation conv,
    List<ChatMessage> raw,
    String? selectedChannelId,
    bool includeUnchanneled,
  ) => _controller.filterChannelAndDeleted(
    conv,
    raw,
    selectedChannelId,
    includeUnchanneled,
  );

  @override
  Widget build(BuildContext context) {
    final conv = widget.conversation;

    if (conv == null) return const NoConversationPlaceholder();

    // Load on first build + scroll to newest message (or unread boundary)
    if (_loadedHistoryKey == null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _loadHistory();
        _loadChannels();
        // Capture unread boundary before marking as read (which resets count)
        _captureUnreadBoundary();
        _markAsRead();
        final pendingMsg = _pendingInitialMessageId;
        if (pendingMsg != null) {
          _pendingInitialMessageId = null;
          // Wait for next frame so message widgets are rendered and keys registered.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            _highlightMessage(pendingMsg);
          });
        } else if (_unreadBoundaryMessageId != null) {
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

    // Watch only this conversation's message list reference and the loading
    // flag for this channel — `messagesByConversation` keeps inner list
    // refs stable across copyWith for unaffected conversations, so adding
    // a message to conv B no longer rebuilds conv A's panel (#834 F6).
    // PR #838 perf: keep this as .select
    final convMessages = ref.watch(
      chatProvider.select((s) => s.messagesByConversation[conv.id]),
    );
    final messages = _filterChannelAndDeleted(
      conv,
      convMessages ?? const [],
      selectedChannelId,
      includeUnchanneled,
    );

    final isLoadingHistory = ref.watch(
      chatProvider.select(
        (s) => s.isLoadingHistory(conv.id, channelId: selectedChannelId),
      ),
    );
    final hasMoreHistory = ref.watch(
      chatProvider.select(
        (s) => s.conversationHasMore(conv.id, channelId: selectedChannelId),
      ),
    );

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

    final chatContentBox = buildChatContentBox(
      context,
      ref,
      ChatPanelBodyParams(
        conv: conv,
        myUserId: myUserId,
        authToken: authToken,
        serverUrl: serverUrl,
        mediaTicket: mediaTicket,
        messages: messages,
        memberAvatars: memberAvatars,
        selectedTextChannelId: _selectedTextChannelId,
        selectedChannelId: selectedChannelId,
        activeVoiceChannelId: _activeVoiceChannelId,
        isLoadingHistory: isLoadingHistory,
        hasMoreHistory: hasMoreHistory,
        displayName: displayName,
        scrollController: _scrollController,
        messageKeys: _messageKeys,
        savedIds: _savedIds,
        highlightedMessageId: _highlightedMessageId,
        unreadBoundaryMessageId: _unreadBoundaryMessageId,
        unreadBoundaryCount: _unreadBoundaryCount,
        floatingDate: _floatingDate,
        floatingDateVisible: _floatingDateVisible,
        hasNewMessagesBelow: _hasNewMessagesBelow,
        newMessagesBannerText: _newMessagesBannerText(),
        liveRegionAnnouncement: _liveRegionAnnouncement,
        showSearch: _showSearch,
        hideVoiceDock: widget.hideVoiceDock,
        hideEncryptionBanner: _hideEncryptionBanner,
        typingUsers: typingUsers,
        isDragOver: _isDragOver,
        chatInputBarKey: _chatInputBarKey,
        onBack: widget.onBack,
        onMembersToggle: widget.onMembersToggle,
        onGroupInfo: widget.onGroupInfo,
        onShowLounge: widget.onShowLounge,
        onTextChannelChanged: _onTextChannelChanged,
        onVoiceChannelChanged: (channelId) {
          if (mounted) setState(() => _activeVoiceChannelId = channelId);
        },
        onSetShowSearch: (v) => setState(() => _showSearch = v),
        onDismissEncryptionBanner: _dismissEncryptionBanner,
        onHighlightMessage: _highlightMessage,
        onShowReactionPicker: _showReactionPicker,
        onToggleReaction: _toggleReaction,
        onShowFullReactionPicker: (msg) =>
            _showFullReactionPicker(msg, myUserId),
        onDeleteFailed: (msg) =>
            actions.deleteFailed(ref: ref, conv: conv, message: msg),
        onConfirmDelete: (msg) => actions.confirmDelete(
          context: context,
          ref: ref,
          conv: conv,
          message: msg,
          addToDeletedForMe: DeletedForMeStorage.add,
        ),
        onRetryMessage: (msg) =>
            actions.retryMessage(ref: ref, conv: conv, message: msg),
        onOpenThread: _openThread,
        onPinMessage: (msg) => actions.pinMessage(
          context: context,
          ref: ref,
          conv: conv,
          message: msg,
        ),
        onUnpinMessage: (msg) => actions.unpinMessage(
          context: context,
          ref: ref,
          conv: conv,
          message: msg,
        ),
        onForwardMessage: (msg) =>
            actions.forwardMessage(context: context, ref: ref, message: msg),
        onSaveMessage: (msg) => actions.saveMessage(
          context: context,
          message: msg,
          onAddSavedId: (id) => setState(() => _savedIds.add(id)),
        ),
        onUnsaveMessage: (msg) => actions.unsaveMessage(
          context: context,
          message: msg,
          onRemoveSavedId: (id) => setState(() => _savedIds.remove(id)),
        ),
        onJumpToReplyQuote: _jumpToReplyQuote,
        onOpenImageGallery: (resolvedUrl) => actions.openImageGallery(
          context: context,
          ref: ref,
          tappedUrl: resolvedUrl,
          messages: messages,
          serverUrl: serverUrl,
          authToken: authToken,
        ),
        onScrollToBottom: () => _scrollToBottom(settleRetries: 2),
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
        // LiveKit handles remote audio playback automatically (#prod-2026-05-08
        // legacy P2P WebRTC migration); no hidden renderer widgets needed.
        voiceRenderers: const [],
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

    // DropTarget on desktop + web only — mobile has no external drag-drop.
    final dropSupported =
        kIsWeb ||
        defaultTargetPlatform == TargetPlatform.linux ||
        defaultTargetPlatform == TargetPlatform.macOS ||
        defaultTargetPlatform == TargetPlatform.windows;
    if (!dropSupported) return chatContent;
    return DropTarget(
      onDragEntered: (_) => setState(() => _isDragOver = true),
      onDragExited: (_) => setState(() => _isDragOver = false),
      onDragDone: (d) {
        setState(() => _isDragOver = false);
        onChatPanelDropDone(d, _chatInputBarKey.currentState);
      },
      child: chatContent,
    );
  }
}
