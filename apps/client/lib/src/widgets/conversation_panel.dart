import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversation_filter_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/update_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/motion_tokens.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/theme_provider.dart' show uiDensityProvider;
import '../utils/time_utils.dart';
import 'avatar_utils.dart';
import 'connection_status_badge.dart';
import 'conversation_item.dart';
import 'echo_logo_icon.dart';
import 'empty_state.dart';
import 'feedback_dialog.dart';
import 'skeleton_loader.dart';
import 'voice_footer.dart';

// Re-export avatar utilities so existing `show` imports keep working.
export 'avatar_utils.dart'
    show buildAvatar, avatarColor, groupAvatarColor, resolveAvatarUrl;

class ConversationPanel extends ConsumerStatefulWidget {
  final String? selectedConversationId;
  final void Function(Conversation conversation) onConversationTap;
  final VoidCallback? onNewChat;
  final VoidCallback? onNewGroup;
  final VoidCallback? onDiscover;
  final VoidCallback? onCollapseSidebar;
  final VoidCallback? onSettings;
  final VoidCallback? onShowContacts;
  final VoidCallback? onGlobalSearch;
  final VoidCallback? onSavedMessages;

  /// Opens the keyboard-shortcuts overlay (also bindable to Ctrl+/).
  /// When null, the help icon in the header is hidden.
  final VoidCallback? onShowKeyboardShortcuts;

  /// Opens a QR-scan flow to add a contact. When null, the QR icon in the
  /// header is hidden.
  final VoidCallback? onScanQr;

  /// Called when the user taps "Message" on a contact in the Contacts tab.
  /// Should call getOrCreateDm and then select the conversation.
  final void Function(String userId, String username)? onMessageContact;

  /// Optional external focus node for the search bar (e.g. for Ctrl+K shortcut).
  final FocusNode? externalSearchFocusNode;

  /// Called when the user taps the voice footer body to navigate to the lounge.
  final VoidCallback? onNavigateToLounge;

  const ConversationPanel({
    super.key,
    this.selectedConversationId,
    required this.onConversationTap,
    this.onNewChat,
    this.onNewGroup,
    this.onDiscover,
    this.onCollapseSidebar,
    this.onSettings,
    this.onShowContacts,
    this.onGlobalSearch,
    this.onSavedMessages,
    this.onShowKeyboardShortcuts,
    this.onScanQr,
    this.onMessageContact,
    this.externalSearchFocusNode,
    this.onNavigateToLounge,
  });

  @override
  ConsumerState<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends ConsumerState<ConversationPanel> {
  bool _isSearching = false;
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _keyboardListenerFocusNode = FocusNode();
  // Timer removed -- HomeScreen handles pending contacts polling

  /// True after the user manually dismisses the "session replaced" banner.
  /// Resets on next reconnect (the websocket clears `wasReplaced`, and we
  /// re-show the banner if a future replacement happens).
  bool _replacedBannerDismissed = false;

  /// Debounce timer for the search field. Delays the fuzzy-score recompute
  /// so we don't run it on every keystroke.
  Timer? _searchDebounce;

  @override
  void initState() {
    super.initState();
    _loadPinnedIds();
    _startPendingRefreshLoop();
    widget.externalSearchFocusNode?.addListener(_onExternalSearchFocus);
  }

  @override
  void didUpdateWidget(covariant ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.externalSearchFocusNode != oldWidget.externalSearchFocusNode) {
      oldWidget.externalSearchFocusNode?.removeListener(_onExternalSearchFocus);
      widget.externalSearchFocusNode?.addListener(_onExternalSearchFocus);
    }
    // When a conversation is selected externally, reset the filter so the
    // selected conversation is visible and highlighted.
    if (widget.selectedConversationId != null &&
        widget.selectedConversationId != oldWidget.selectedConversationId &&
        ref.read(conversationFilterTypeProvider) !=
            ConversationFilterType.all) {
      ref
          .read(conversationFilterTypeProvider.notifier)
          .set(ConversationFilterType.all);
    }
  }

  @override
  void dispose() {
    widget.externalSearchFocusNode?.removeListener(_onExternalSearchFocus);
    _searchController.dispose();
    _searchFocusNode.dispose();
    _keyboardListenerFocusNode.dispose();
    _searchDebounce?.cancel();
    super.dispose();
  }

  /// Debounced search handler (150ms). Avoids running fuzzyScore over every
  /// conversation on every keystroke.
  void _onSearchChanged(String value) {
    final trimmed = value.trim();
    _searchDebounce?.cancel();
    _searchDebounce = Timer(const Duration(milliseconds: 150), () {
      if (!mounted) return;
      ref.read(conversationSearchQueryProvider.notifier).set(trimmed);
    });
  }

  // Pending contacts refresh is handled by HomeScreen's timer -- no duplicate here.
  void _startPendingRefreshLoop() {
    // Just do the initial load
    final authState = ref.read(authProvider);
    if (authState.isLoggedIn) {
      ref.read(contactsProvider.notifier).loadPending(force: true);
    }
  }

  void _onFilterChanged(ConversationFilterType filter) {
    if (ref.read(conversationFilterTypeProvider) == filter) return;
    ref.read(conversationFilterTypeProvider.notifier).set(filter);
  }

  void _onExternalSearchFocus() {
    if (widget.externalSearchFocusNode?.hasFocus == true) {
      _activateSearch();
    }
  }

  void _activateSearch() {
    setState(() => _isSearching = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  Future<void> _loadPinnedIds() async {
    // Seed from SharedPreferences for immediate rendering before server load.
    final prefs = await SharedPreferences.getInstance();
    final pinned = prefs.getStringList('pinned_conversation_ids') ?? [];
    if (mounted) {
      // Merge SharedPrefs IDs with any server-known pinned conversations.
      final serverPinned = ref
          .read(conversationsProvider)
          .conversations
          .where((c) => c.isPinned)
          .map((c) => c.id)
          .toSet();
      ref.read(pinnedConversationIdsProvider.notifier).set({
        ...pinned.toSet(),
        ...serverPinned,
      });
    }
  }

  Future<void> _savePinnedIds() async {
    final prefs = await SharedPreferences.getInstance();
    final ids = ref.read(pinnedConversationIdsProvider);
    await prefs.setStringList('pinned_conversation_ids', ids.toList());
  }

  void _togglePin(String conversationId) {
    final current = ref.read(pinnedConversationIdsProvider);
    final isPinned = current.contains(conversationId);
    final updated = Set<String>.from(current);
    if (isPinned) {
      updated.remove(conversationId);
    } else {
      updated.add(conversationId);
    }
    ref.read(pinnedConversationIdsProvider.notifier).set(updated);
    _savePinnedIds();
    ref
        .read(conversationsProvider.notifier)
        .setPinned(conversationId, !isPinned);
  }

  void _clearSearch() {
    _searchDebounce?.cancel();
    ref.read(conversationSearchQueryProvider.notifier).set('');
    setState(() {
      _isSearching = false;
      _searchController.clear();
    });
  }

  Future<void> _handleContextMenuSelection(
    String? value,
    Conversation conv,
  ) async {
    if (value == 'pin') {
      _togglePin(conv.id);
    } else if (value == 'mute') {
      final ok = await ref
          .read(conversationsProvider.notifier)
          .toggleMute(conv.id);
      if (!ok && mounted) {
        ToastService.show(
          context,
          'Failed to update mute settings',
          type: ToastType.error,
        );
      }
    } else if (value == 'leave_group') {
      _leaveGroup(conv);
    } else if (value == 'delete_dm') {
      _deleteDm(conv);
    }
  }

  List<PopupMenuEntry<String>> _buildContextMenuItems(
    BuildContext context,
    Conversation conv,
    bool isPinned,
  ) {
    return [
      PopupMenuItem<String>(
        value: 'pin',
        child: Row(
          children: [
            Icon(
              isPinned ? Icons.push_pin : Icons.push_pin_outlined,
              size: 16,
              color: context.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              isPinned ? 'Unpin' : 'Pin to top',
              style: TextStyle(color: context.textPrimary, fontSize: 13),
            ),
          ],
        ),
      ),
      PopupMenuItem<String>(
        value: 'mute',
        child: Row(
          children: [
            Icon(
              conv.isMuted
                  ? Icons.notifications_outlined
                  : Icons.notifications_off_outlined,
              size: 16,
              color: context.textSecondary,
            ),
            const SizedBox(width: 8),
            Text(
              conv.isMuted ? 'Unmute' : 'Mute',
              style: TextStyle(color: context.textPrimary, fontSize: 13),
            ),
          ],
        ),
      ),
      if (conv.isGroup)
        const PopupMenuItem<String>(
          value: 'leave_group',
          child: Row(
            children: [
              Icon(Icons.exit_to_app, size: 16, color: EchoTheme.danger),
              SizedBox(width: 8),
              Text(
                'Leave Group',
                style: TextStyle(color: EchoTheme.danger, fontSize: 13),
              ),
            ],
          ),
        ),
      if (!conv.isGroup)
        const PopupMenuItem<String>(
          value: 'delete_dm',
          child: Row(
            children: [
              Icon(Icons.delete_outline, size: 16, color: EchoTheme.danger),
              SizedBox(width: 8),
              Text(
                'Delete Conversation',
                style: TextStyle(color: EchoTheme.danger, fontSize: 13),
              ),
            ],
          ),
        ),
    ];
  }

  void _showConversationContextMenu(
    BuildContext context,
    Conversation conv,
    Offset position,
  ) {
    final pinnedIds = ref.read(pinnedConversationIdsProvider);
    final isPinned = pinnedIds.contains(conv.id) || conv.isPinned;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      position: RelativeRect.fromRect(
        Rect.fromLTWH(position.dx, position.dy, 0, 0),
        Offset.zero & overlay.size,
      ),
      color: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: context.border),
      ),
      items: _buildContextMenuItems(context, conv, isPinned),
    ).then((value) => _handleContextMenuSelection(value, conv));
  }

  Future<void> _leaveGroup(Conversation conv) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: const Text(
          'Leave Group',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Are you sure you want to leave "${conv.name ?? "this group"}"?',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    try {
      final success = await ref
          .read(conversationsProvider.notifier)
          .leaveGroup(conv.id);

      if (!mounted) return;

      if (success) {
        ToastService.show(
          context,
          'You have left the group.',
          type: ToastType.success,
        );
      } else {
        ToastService.show(
          context,
          'Failed to leave group',
          type: ToastType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Error leaving group: $e',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _deleteDm(Conversation conv) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: const Text(
          'Delete Conversation',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will remove the conversation from your list. '
          'You can start a new conversation anytime.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirmed != true || !mounted) return;

    final success = await ref
        .read(conversationsProvider.notifier)
        .leaveConversation(conv.id);

    if (!mounted) return;

    if (success) {
      ToastService.show(
        context,
        'Conversation deleted',
        type: ToastType.success,
      );
    } else {
      ToastService.show(
        context,
        'Failed to delete conversation',
        type: ToastType.error,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(
      conversationsProvider.select(
        (s) => (s.conversations, s.isLoading, s.error),
      ),
    );
    final (allConversations, convIsLoading, convError) = conversationsState;
    final convState = ConversationsState(
      conversations: allConversations,
      isLoading: convIsLoading,
      error: convError,
    );
    final (myUserId, myUsername, myAvatarUrl, myPresenceStatus) = ref.watch(
      authProvider.select(
        (s) => (s.userId, s.username, s.avatarUrl, s.presenceStatus),
      ),
    );
    final userId = myUserId ?? '';
    final username = myUsername ?? 'User';
    final serverUrl = ref.watch(serverUrlProvider);
    final (wsConnected, wsReplaced, wsOnlineUsers) = ref.watch(
      websocketProvider.select(
        (s) => (s.isConnected, s.wasReplaced, s.onlineUsers),
      ),
    );
    final contactsState = ref.watch(contactsProvider);

    final pendingCount = contactsState.pendingRequests.length;

    // Derived list is precomputed by sortedConversationsProvider — no
    // sort/filter work happens here in the build path.
    final conversations = ref.watch(sortedConversationsProvider);

    return Container(
      color: context.sidebarBg,
      child: Stack(
        children: [
          Column(
            children: [
              _buildLogoHeader(context, pendingCount),
              _buildSearchBar(context),
              _buildFilterChips(),
              _buildReplacedBanner(context, wsReplaced),
              if (pendingCount > 0) _buildPendingBanner(pendingCount),
              Expanded(
                child: _buildChatsTab(
                  convState,
                  conversations,
                  allConversations,
                  userId,
                  serverUrl,
                  wsOnlineUsers,
                ),
              ),
              // Hide the status bar on mobile narrow — redundant with the
              // bottom tab bar that already exposes Settings + identity.
              //
              // The update banner / bug-report row sits ABOVE the VoiceFooter
              // so the desktop voice-dock overlay (`_buildDesktopVoiceDock`,
              // anchored at `bottom: 60`) can't cover the bug-report button
              // when a call is active (#913).
              if (MediaQuery.sizeOf(context).width >= 600)
                _buildSidebarUpdateBanner(context),
              // Explicit gap between bug-report row and voice dock to prevent
              // visual occlusion when corners round.
              if (MediaQuery.sizeOf(context).width >= 600)
                const SizedBox(height: 4),
              // On narrow (mobile), VoiceFooter is rendered at the Scaffold
              // level in home_screen.dart above the bottom tab bar.
              if (MediaQuery.sizeOf(context).width >= 600)
                VoiceFooter(onNavigateToLounge: widget.onNavigateToLounge),
              if (MediaQuery.sizeOf(context).width >= 600)
                _buildUserStatusBar(
                  context,
                  myUsername: username,
                  serverUrl: serverUrl,
                  avatarUrl: myAvatarUrl,
                  wsConnected: wsConnected,
                  wsReplaced: wsReplaced,
                  presenceStatus: myPresenceStatus,
                ),
            ],
          ),
          if (widget.onNewChat != null) _buildComposeFab(context),
        ],
      ),
    );
  }

  /// Square accent FAB anchored bottom-right of the conversation panel.
  ///
  /// Mobile-only (width < 600): the desktop header "+" menu is hidden on
  /// narrow layouts, so this FAB becomes the sole entry-point for compose
  /// actions. A single tap fires "New chat" (primary action). A long-press
  /// opens a popup with "New chat", "New group", and "Discover groups" so
  /// all three are reachable without cluttering the header.
  Widget _buildComposeFab(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    if (!isMobile) return const SizedBox.shrink();

    // If no secondary actions are provided we fall back to a plain tap-only FAB.
    final hasMenu = widget.onNewGroup != null || widget.onDiscover != null;

    return Positioned(
      right: 16,
      bottom: 16,
      child: hasMenu
          ? _ComposeFabMenu(
              onNewChat: widget.onNewChat,
              onNewGroup: widget.onNewGroup,
              onDiscover: widget.onDiscover,
            )
          : Semantics(
              label: 'New chat',
              button: true,
              child: Material(
                color: context.accent,
                borderRadius: BorderRadius.circular(16),
                elevation: 4,
                child: InkWell(
                  onTap: widget.onNewChat,
                  borderRadius: BorderRadius.circular(16),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(
                      Icons.edit_outlined,
                      color: context.onAccent,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildLogoHeader(BuildContext context, int pendingCount) {
    // Use the larger title style on mobile (full-screen), smaller on desktop
    // sidebar where horizontal real-estate is tight.
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final titleSize = isMobile ? 28.0 : 17.0;
    final titleWeight = isMobile ? FontWeight.w700 : FontWeight.w700;
    final headerHeight = isMobile ? 64.0 : 56.0;

    return Container(
      height: headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                // Anchor the connection status dot to a small fixed-size
                // icon on every layout. Wrapping it around the large
                // "Chats" text on mobile placed the dot at the lower-right
                // of the "s" — visually awkward; the icon variant matches
                // desktop and gives the dot a predictable anchor.
                const ConnectionStatusBadge(child: EchoLogoIcon(size: 22)),
                const SizedBox(width: 10),
                Text(
                  isMobile ? 'Chats' : 'Echo',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: titleSize,
                    fontWeight: titleWeight,
                    letterSpacing: isMobile ? -0.5 : 0,
                  ),
                ),
              ],
            ),
          ),
          // Right: non-draggable action buttons.
          // All icons at 18px with uniform 44x44 tap targets per WCAG 2.5.5.
          if (widget.onScanQr != null)
            IconButton(
              icon: const Icon(Icons.qr_code_scanner, size: 18),
              color: context.textSecondary,
              tooltip: 'Scan QR to add contact',
              onPressed: widget.onScanQr,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          const SizedBox(width: 2),
          _buildNewActionMenu(context, pendingCount),
          if (!isMobile && widget.onShowKeyboardShortcuts != null) ...[
            const SizedBox(width: 2),
            IconButton(
              icon: const Icon(Icons.help_outline, size: 18),
              color: context.textSecondary,
              tooltip: 'Keyboard shortcuts (Ctrl+/)',
              onPressed: widget.onShowKeyboardShortcuts,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ],
          if (!isMobile && widget.onGlobalSearch != null) ...[
            const SizedBox(width: 2),
            IconButton(
              icon: const Icon(Icons.search_outlined, size: 18),
              color: context.textSecondary,
              tooltip: 'Search messages (Ctrl+Shift+F)',
              onPressed: widget.onGlobalSearch,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ],
          if (widget.onCollapseSidebar != null) ...[
            const SizedBox(width: 2),
            IconButton(
              icon: const Icon(Icons.chevron_left, size: 18),
              color: context.textSecondary,
              tooltip: 'Collapse sidebar',
              onPressed: widget.onCollapseSidebar,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNewActionMenu(BuildContext context, int pendingCount) {
    // On mobile (narrow) the pencil FAB already exposes these actions;
    // hide the "+" header button there to avoid duplication.
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    if (isMobile) return const SizedBox.shrink();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        PopupMenuButton<String>(
          icon: Icon(Icons.add, size: 18, color: context.textSecondary),
          tooltip: 'New',
          padding: EdgeInsets.zero,
          // 44×44 tap target per WCAG 2.5.5
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          // Menu minimum width so text never clips on narrow viewports
          menuPadding: const EdgeInsets.symmetric(vertical: 4),
          popUpAnimationStyle: AnimationStyle.noAnimation,
          offset: const Offset(0, 36),
          onSelected: (value) {
            switch (value) {
              case 'chat':
                widget.onNewChat?.call();
              case 'group':
                widget.onNewGroup?.call();
              case 'discover':
                widget.onDiscover?.call();
              case 'saved':
                widget.onSavedMessages?.call();
            }
          },
          itemBuilder: (context) => const [
            PopupMenuItem(
              value: 'chat',
              child: SizedBox(
                width: 200,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.person_add_outlined, size: 18),
                    SizedBox(width: 10),
                    Flexible(
                      child: Text('New Chat', overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuItem(
              value: 'group',
              child: SizedBox(
                width: 200,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.group_add_outlined, size: 18),
                    SizedBox(width: 10),
                    Flexible(
                      child: Text('New Group', overflow: TextOverflow.ellipsis),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuItem(
              value: 'discover',
              child: SizedBox(
                width: 200,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.explore_outlined, size: 18),
                    SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'Discover Groups',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            PopupMenuItem(
              value: 'saved',
              child: SizedBox(
                width: 200,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.bookmark_border_outlined, size: 18),
                    SizedBox(width: 10),
                    Flexible(
                      child: Text(
                        'Saved Messages',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
        if (pendingCount > 0 &&
            (kIsWeb ||
                defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS))
          Positioned(
            // Re-center the badge on the larger 44×44 button.
            top: 6,
            right: 6,
            child: IgnorePointer(
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  color: EchoTheme.danger,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    pendingCount > 9 ? '9+' : '$pendingCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildSearchBar(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    if (!isMobile) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: GestureDetector(
        onTap: () {
          if (!_isSearching) {
            setState(() => _isSearching = true);
            WidgetsBinding.instance.addPostFrameCallback((_) {
              _searchFocusNode.requestFocus();
            });
          }
        },
        child: Container(
          height: 44,
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(10),
          ),
          child: _isSearching
              ? _buildActiveSearchBar(context)
              : _buildInactiveSearchBar(context),
        ),
      ),
    );
  }

  Widget _buildActiveSearchBar(BuildContext context) {
    final searchQuery = ref.watch(conversationSearchQueryProvider);
    return KeyboardListener(
      focusNode: _keyboardListenerFocusNode,
      onKeyEvent: (event) {
        if (event is KeyDownEvent &&
            event.logicalKey == LogicalKeyboardKey.escape) {
          _clearSearch();
        }
      },
      child: Row(
        children: [
          const SizedBox(width: 12),
          Icon(Icons.search_outlined, size: 18, color: context.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              controller: _searchController,
              focusNode: _searchFocusNode,
              autofocus: true,
              style: TextStyle(color: context.textPrimary, fontSize: 13),
              decoration: InputDecoration(
                hintText: 'Search conversations',
                hintStyle: TextStyle(color: context.textMuted, fontSize: 13),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                filled: false,
                contentPadding: const EdgeInsets.symmetric(vertical: 10),
                isDense: true,
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          if (searchQuery.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.close, size: 16),
              color: context.textMuted,
              onPressed: _clearSearch,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
            )
          else
            const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildInactiveSearchBar(BuildContext context) {
    return Row(
      children: [
        const SizedBox(width: 12),
        Icon(Icons.search_outlined, size: 18, color: context.textMuted),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            'Search conversations',
            style: TextStyle(color: context.textMuted, fontSize: 13),
            overflow: TextOverflow.ellipsis,
          ),
        ),
      ],
    );
  }

  Widget _buildFilterChips() {
    final activeFilter = ref.watch(conversationFilterTypeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
      child: Row(
        children: [
          _buildChip('All', ConversationFilterType.all, activeFilter),
          const SizedBox(width: 6),
          _buildChip(
            'DMs',
            ConversationFilterType.dms,
            activeFilter,
            icon: Icons.person_outline,
          ),
          const SizedBox(width: 6),
          _buildChip(
            'Groups',
            ConversationFilterType.groups,
            activeFilter,
            icon: Icons.groups_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildChip(
    String label,
    ConversationFilterType filter,
    ConversationFilterType activeFilter, {
    IconData? icon,
  }) {
    final isSelected = activeFilter == filter;
    // Selected chip bg is always `context.accent` (a saturated indigo across
    // every theme variant), so white reads cleanly. The previous reliance on
    // `colorScheme.onPrimary` broke on themes where onPrimary resolves dark
    // (graphite/ember/neon).
    final chipColor = isSelected ? Colors.white : context.textSecondary;
    final chipWeight = isSelected ? FontWeight.w600 : FontWeight.w500;
    return GestureDetector(
      onTap: () => _onFilterChanged(filter),
      // Opaque so taps in the transparent vertical padding still register.
      behavior: HitTestBehavior.opaque,
      child: Container(
        // Outer wrapper provides the 44x44 tap target without enlarging the
        // visual pill -- the inner Container keeps the compact 28px chip.
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: MotionDurations.quick,
          curve: MotionCurves.emphasis,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected ? context.accent : context.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: chipColor),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  color: chipColor,
                  fontSize: 12,
                  fontWeight: chipWeight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPendingBanner(int pendingCount) {
    return GestureDetector(
      onTap: widget.onShowContacts,
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: context.accent.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.accent.withValues(alpha: 0.3)),
        ),
        child: Row(
          children: [
            Icon(Icons.person_add, size: 16, color: context.accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '$pendingCount pending contact ${pendingCount == 1 ? 'request' : 'requests'}',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
            Icon(Icons.chevron_right, size: 16, color: context.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _buildReplacedBanner(BuildContext context, bool wsReplaced) {
    if (!wsReplaced || _replacedBannerDismissed) return const SizedBox.shrink();
    return Column(
      children: [
        GestureDetector(
          onTap: () {
            // Trigger a fresh connect, clearing wasReplaced if applicable
            final ws = ref.read(websocketProvider.notifier);
            if (ref.read(websocketProvider).wasReplaced) {
              ws.reconnectAfterReplacement();
            } else {
              ws.connect();
            }
          },
          child: Container(
            height: 56,
            margin: const EdgeInsets.symmetric(horizontal: 16),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: EchoTheme.warning, width: 1),
            ),
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                const Icon(
                  Icons.devices_other,
                  size: 18,
                  color: EchoTheme.warning,
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Signed in on another device. Tap to reconnect.',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const Icon(Icons.refresh, size: 18, color: EchoTheme.warning),
                Semantics(
                  label: 'Dismiss session banner',
                  button: true,
                  child: IconButton(
                    icon: Icon(Icons.close, size: 16, color: context.textMuted),
                    tooltip: 'Dismiss',
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 36,
                      minHeight: 36,
                    ),
                    // Stop the parent GestureDetector from also firing a
                    // reconnect when the user just wants to close the banner.
                    onPressed: () {
                      setState(() => _replacedBannerDismissed = true);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  /// Resolves the visible label, optional action button, dismiss flag, and
  /// optional progress bar for the current update state.
  ({String label, Widget? action, bool showDismiss, Widget? progress})
  _resolveUpdateBannerState(BuildContext context, UpdateState update) {
    switch (update.status) {
      case UpdateStatus.downloading:
        final pct = (update.downloadProgress * 100).toInt();
        return (
          label: 'Downloading update... $pct%',
          action: TextButton(
            onPressed: () => ref.read(updateProvider.notifier).cancelDownload(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Cancel',
              style: TextStyle(color: context.textMuted, fontSize: 11),
            ),
          ),
          showDismiss: false,
          progress: LinearProgressIndicator(
            value: update.downloadProgress,
            color: context.accent,
            backgroundColor: context.border,
            minHeight: 2,
          ),
        );
      case UpdateStatus.readyToInstall:
        return (
          label: 'v${update.latestVersion} ready',
          action: TextButton(
            onPressed: () => ref.read(updateProvider.notifier).applyUpdate(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Restart',
              style: TextStyle(
                color: context.accent,
                fontSize: 11,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          showDismiss: true,
          progress: null,
        );
      case UpdateStatus.installing:
        return (
          label: 'Installing update...',
          action: const SizedBox(
            width: 12,
            height: 12,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
          showDismiss: false,
          progress: null,
        );
      case UpdateStatus.error:
        return (
          label: 'Update failed',
          action: TextButton(
            onPressed: () => ref.read(updateProvider.notifier).downloadUpdate(),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
            child: Text(
              'Retry',
              style: TextStyle(color: context.accent, fontSize: 11),
            ),
          ),
          showDismiss: true,
          progress: null,
        );
      default: // idle, update available
        return _resolveAvailableUpdateState(context, update);
    }
  }

  /// Resolves banner state for the idle / update-available case.
  ({String label, Widget? action, bool showDismiss, Widget? progress})
  _resolveAvailableUpdateState(BuildContext context, UpdateState update) {
    if (kIsWeb) {
      return (
        label: 'New version available',
        action: null,
        showDismiss: true,
        progress: null,
      );
    }
    return (
      label: 'v${update.latestVersion} available',
      action: TextButton(
        onPressed: update.assetDownloadUrl != null
            ? () => ref.read(updateProvider.notifier).downloadUpdate()
            : () {
                final url = update.downloadUrl;
                if (url != null) launchUrl(Uri.parse(url));
              },
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 8),
          minimumSize: Size.zero,
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
        child: Text(
          update.assetDownloadUrl != null ? 'Update' : 'Download',
          style: TextStyle(
            color: context.accent,
            fontSize: 11,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
      showDismiss: true,
      progress: null,
    );
  }

  Widget _buildSidebarUpdateBanner(BuildContext context) {
    final update = ref.watch(updateProvider);

    const activeStatuses = {
      UpdateStatus.downloading,
      UpdateStatus.readyToInstall,
      UpdateStatus.installing,
    };
    final isActive = activeStatuses.contains(update.status);
    final isVisible =
        update.updateAvailable ||
        isActive ||
        update.status == UpdateStatus.error;
    // When no update banner is showing, fall back to a small "Report a bug"
    // affordance so the user can reach the feedback dialog without leaving
    // the sidebar / opening Settings.
    if (!isVisible) return _buildBugReportRow(context);
    if (update.dismissed && !isActive) return _buildBugReportRow(context);

    final (:label, :action, :showDismiss, :progress) =
        _resolveUpdateBannerState(context, update);

    return Container(
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 6, 6, 6),
            child: Row(
              children: [
                Icon(
                  Icons.system_update_outlined,
                  size: 14,
                  color: context.accent,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    label,
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 11,
                      fontWeight: FontWeight.w500,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                ?action,
                if (showDismiss)
                  IconButton(
                    icon: Icon(Icons.close, size: 12, color: context.textMuted),
                    onPressed: () =>
                        ref.read(updateProvider.notifier).dismiss(),
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
              ],
            ),
          ),
          ?progress,
        ],
      ),
    );
  }

  /// Small "Report a bug" affordance shown in the slot the update banner
  /// otherwise occupies. Visible only when no update is in flight — keeps
  /// the sidebar tight when an update is pending / installing.
  Widget _buildBugReportRow(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      child: Align(
        alignment: Alignment.centerLeft,
        child: TextButton.icon(
          icon: const Icon(Icons.bug_report_outlined, size: 14),
          label: const Text('Report a bug'),
          onPressed: () => showFeedbackDialog(context),
          style: TextButton.styleFrom(
            foregroundColor: context.textMuted,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            minimumSize: Size.zero,
            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            textStyle: const TextStyle(fontSize: 11),
          ),
        ),
      ),
    );
  }

  Widget _buildUserStatusBar(
    BuildContext context, {
    required String myUsername,
    required String serverUrl,
    required String? avatarUrl,
    required bool wsConnected,
    required bool wsReplaced,
    required String presenceStatus,
  }) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          _buildUserAvatar(
            context,
            myUsername,
            serverUrl,
            avatarUrl,
            wsConnected,
            presenceStatus,
          ),
          const SizedBox(width: 10),
          _buildUserNameAndStatus(context, myUsername, wsConnected, wsReplaced),
          IconButton(
            icon: const Icon(Icons.settings_outlined, size: 18),
            color: context.textSecondary,
            tooltip: 'Settings',
            onPressed: widget.onSettings,
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          ),
        ],
      ),
    );
  }

  static Color _presenceColor(String status) => switch (status) {
    'away' => EchoTheme.warning,
    'dnd' => EchoTheme.danger,
    'invisible' => const Color(0xFF6B6B6F),
    _ => EchoTheme.online,
  };

  Widget _buildUserAvatar(
    BuildContext context,
    String myUsername,
    String serverUrl,
    String? avatarUrl,
    bool wsConnected,
    String presenceStatus,
  ) {
    final dotColor = wsConnected
        ? _presenceColor(presenceStatus)
        : EchoTheme.warning;

    return Semantics(
      label: 'Status: $presenceStatus. Tap to change.',
      button: true,
      child: PopupMenuButton<String>(
        key: const Key('status-picker'),
        tooltip: 'Change status',
        offset: const Offset(0, -160),
        onSelected: (status) {
          ref.read(authProvider.notifier).setPresenceStatus(status);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'online',
            child: _StatusMenuItem(label: 'Online', color: EchoTheme.online),
          ),
          PopupMenuItem(
            value: 'away',
            child: _StatusMenuItem(label: 'Away', color: EchoTheme.warning),
          ),
          PopupMenuItem(
            value: 'dnd',
            child: _StatusMenuItem(
              label: 'Do Not Disturb',
              color: EchoTheme.danger,
            ),
          ),
          PopupMenuItem(
            value: 'invisible',
            child: _StatusMenuItem(
              label: 'Invisible',
              color: Color(0xFF6B6B6F),
            ),
          ),
        ],
        child: Stack(
          children: [
            buildAvatar(
              name: myUsername,
              radius: 16,
              bgColor: context.accent,
              imageUrl: resolveAvatarUrl(avatarUrl, serverUrl),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.mainBg, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _connectionStatusLabel(bool wsReplaced, bool wsConnected) {
    if (wsReplaced) return 'Session replaced';
    if (wsConnected) return 'Online';
    return 'Reconnecting...';
  }

  Widget _buildUserNameAndStatus(
    BuildContext context,
    String myUsername,
    bool wsConnected,
    bool wsReplaced,
  ) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            myUsername,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            _connectionStatusLabel(wsReplaced, wsConnected),
            style: TextStyle(
              color: wsConnected ? EchoTheme.online : EchoTheme.warning,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildChatsTab(
    ConversationsState conversationsState,
    List<Conversation> conversations,
    List<Conversation> allConversations,
    String myUserId,
    String serverUrl,
    Set<String> wsOnlineUsers,
  ) {
    final Widget child;
    if (conversationsState.isLoading && allConversations.isEmpty) {
      child = const ConversationListSkeleton(key: ValueKey('skeleton'));
    } else if (conversationsState.error != null && allConversations.isEmpty) {
      child = KeyedSubtree(
        key: const ValueKey('error'),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.all(32),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.cloud_off,
                  size: 40,
                  color: context.textMuted.withValues(alpha: 0.5),
                ),
                const SizedBox(height: 16),
                Text(
                  "Couldn't load conversations",
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 8),
                TextButton.icon(
                  onPressed: () => ref
                      .read(conversationsProvider.notifier)
                      .loadConversations(),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                ),
              ],
            ),
          ),
        ),
      );
    } else if (conversations.isEmpty) {
      child = KeyedSubtree(
        key: const ValueKey('empty'),
        child: _buildChatsEmptyState(),
      );
    } else {
      // conversations is already sorted + filtered by sortedConversationsProvider.
      child = KeyedSubtree(
        key: const ValueKey('list'),
        child: _buildConversationList(
          conversations,
          myUserId,
          serverUrl,
          wsOnlineUsers,
        ),
      );
    }
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 200),
      child: child,
    );
  }

  Widget _buildChatsEmptyState() {
    final searchQuery = ref.watch(conversationSearchQueryProvider);
    if (searchQuery.isNotEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                Icons.search_off,
                size: 40,
                color: context.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 16),
              Text(
                "No results found for '$searchQuery'",
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 14,
                  fontWeight: FontWeight.w500,
                ),
                textAlign: TextAlign.center,
              ),
              const SizedBox(height: 8),
              Text(
                'Try a different search term',
                textAlign: TextAlign.center,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
            ],
          ),
        ),
      );
    }

    // No conversations yet — show onboarding guidance.
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    return EmptyState(
      icon: Icons.forum_outlined,
      title: 'No conversations yet',
      body: 'Start a new chat or wait for friends to message you.',
      ctaLabel: 'Start a new chat',
      onCta: widget.onNewChat,
      footer: (!isMobile && widget.onShowKeyboardShortcuts != null)
          ? Text(
              'Keyboard shortcuts (Ctrl+/)',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            )
          : null,
    );
  }

  Widget _buildListItem({
    required int index,
    required List<Conversation> sorted,
    required int pinnedCount,
    required String myUserId,
    required String serverUrl,
    required Set<String> wsOnlineUsers,
  }) {
    if (pinnedCount > 0) {
      if (index == 0) {
        return Padding(
          padding: const EdgeInsets.only(left: 8, top: 4, bottom: 2),
          child: Text(
            'PINNED',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: context.textMuted,
              letterSpacing: 0.5,
            ),
          ),
        );
      }
      if (index == pinnedCount + 1) {
        return Divider(
          height: 12,
          thickness: 1,
          indent: 8,
          endIndent: 8,
          color: context.border,
        );
      }
      final convIndex = index <= pinnedCount ? index - 1 : index - 2;
      if (convIndex >= sorted.length) return const SizedBox.shrink();
      final conv = sorted[convIndex];
      return _buildConversationTile(
        conv,
        conv.isPinned ||
            ref.read(pinnedConversationIdsProvider).contains(conv.id),
        myUserId,
        serverUrl,
        wsOnlineUsers,
      );
    }

    final conv = sorted[index];
    return _buildConversationTile(
      conv,
      conv.isPinned ||
          ref.read(pinnedConversationIdsProvider).contains(conv.id),
      myUserId,
      serverUrl,
      wsOnlineUsers,
    );
  }

  Widget _buildConversationList(
    List<Conversation> sorted,
    String myUserId,
    String serverUrl,
    Set<String> wsOnlineUsers,
  ) {
    // Count how many pinned items are at the front of the sorted list.
    final pinnedIds = ref.watch(pinnedConversationIdsProvider);
    final pinnedCount = sorted
        .where((c) => pinnedIds.contains(c.id) || c.isPinned)
        .length;
    // Extra items: section header for pinned (if any) + divider after pinned.
    final extraItems = pinnedCount > 0 ? 2 : 0;

    return RefreshIndicator(
      onRefresh: () =>
          ref.read(conversationsProvider.notifier).loadConversations(),
      color: context.accent,
      child: Scrollbar(
        thumbVisibility: defaultTargetPlatform != TargetPlatform.iOS,
        // Wrap the list in SlidableAutoCloseBehavior so opening a second row's
        // swipe-action panel automatically closes any previously-open one —
        // matches the iOS Mail / Messages pattern. Without this wrapper each
        // Slidable is independent and several rows can sit half-open at once.
        child: SlidableAutoCloseBehavior(
          child: ListView.builder(
            physics: const AlwaysScrollableScrollPhysics(),
            padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 8),
            // Use fixed itemExtent when no section headers/dividers for faster layout.
            // Three-way density (UX roadmap Phase 2): cozy / normal / compact.
            itemExtent: extraItems == 0
                ? conversationItemHeightFor(ref.watch(uiDensityProvider))
                : null,
            itemCount: sorted.length + extraItems,
            itemBuilder: (context, index) => _buildListItem(
              index: index,
              sorted: sorted,
              pinnedCount: pinnedCount,
              myUserId: myUserId,
              serverUrl: serverUrl,
              wsOnlineUsers: wsOnlineUsers,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildConversationTile(
    Conversation conv,
    bool isPinned,
    String myUserId,
    String serverUrl,
    Set<String> wsOnlineUsers,
  ) {
    final peer = conv.isGroup
        ? null
        : conv.members.where((m) => m.userId != myUserId).firstOrNull;
    final isPeerOnline = peer != null && wsOnlineUsers.contains(peer.userId);

    final onlineMemberCount = conv.isGroup
        ? conv.members
              .where(
                (m) => m.userId != myUserId && wsOnlineUsers.contains(m.userId),
              )
              .length
        : 0;

    final item = ConversationItem(
      conversation: conv,
      myUserId: myUserId,
      isSelected: conv.id == widget.selectedConversationId,
      isPinned: isPinned,
      isPeerOnline: isPeerOnline,
      peerAvatarUrl: resolveAvatarUrl(peer?.avatarUrl, serverUrl),
      groupIconUrl: resolveAvatarUrl(conv.iconUrl, serverUrl),
      timestamp: formatConversationTimestamp(conv.lastMessageTimestamp),
      onTap: () => widget.onConversationTap(conv),
      onContextMenu: (position) =>
          _showConversationContextMenu(context, conv, position),
      onTogglePin: () => _togglePin(conv.id),
      onLeave: () => conv.isGroup ? _leaveGroup(conv) : _deleteDm(conv),
      onlineMemberCount: onlineMemberCount,
    );

    final isMobile =
        defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;

    if (!isMobile) return item;

    return _buildSlidableTile(context, conv, isPinned, item);
  }

  /// Wraps [item] in a [Slidable] with mute / pin / delete swipe actions.
  /// Extracted to keep [_buildConversationTile] under the cognitive-complexity
  /// budget — the action callbacks each capture state-mutating closures.
  Widget _buildSlidableTile(
    BuildContext context,
    Conversation conv,
    bool isPinned,
    Widget item,
  ) {
    return Slidable(
      key: ValueKey(conv.id),
      // Shared groupTag so SlidableAutoCloseBehavior knows these rows
      // belong to one logical list — opening row B closes row A.
      groupTag: 'conversation-list',
      endActionPane: ActionPane(
        motion: const DrawerMotion(),
        extentRatio: 0.6,
        children: [
          SlidableAction(
            onPressed: (_) => _toggleMuteWithFeedback(conv.id),
            icon: conv.isMuted ? Icons.volume_up : Icons.volume_off,
            backgroundColor: Colors.blueGrey,
            label: conv.isMuted ? 'Unmute' : 'Mute',
          ),
          SlidableAction(
            onPressed: (_) => _togglePin(conv.id),
            icon: Icons.push_pin,
            backgroundColor: Colors.orange,
            label: isPinned ? 'Unpin' : 'Pin',
          ),
          SlidableAction(
            onPressed: (_) =>
                conv.isGroup ? _leaveGroup(conv) : _deleteDm(conv),
            icon: Icons.delete_outline,
            backgroundColor: EchoTheme.danger,
            label: conv.isGroup ? 'Leave' : 'Delete',
          ),
        ],
      ),
      child: item,
    );
  }

  Future<void> _toggleMuteWithFeedback(String conversationId) async {
    final ok = await ref
        .read(conversationsProvider.notifier)
        .toggleMute(conversationId);
    if (!ok && mounted) {
      ToastService.show(
        context,
        'Failed to update mute settings',
        type: ToastType.error,
      );
    }
  }
}

// ---------------------------------------------------------------------------
// Mobile compose FAB with long-press popup menu
// ---------------------------------------------------------------------------

/// Pencil FAB used on narrow (mobile) layouts. A single tap triggers the
/// primary "New chat" action. A long-press opens a small popup menu anchored
/// to the button itself with "New chat", "New group", and "Discover groups"
/// so every compose action is reachable one-handed without a header button.
class _ComposeFabMenu extends StatelessWidget {
  const _ComposeFabMenu({this.onNewChat, this.onNewGroup, this.onDiscover});

  final VoidCallback? onNewChat;
  final VoidCallback? onNewGroup;
  final VoidCallback? onDiscover;

  void _openMenu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final offset = box.localToGlobal(Offset.zero);
    final size = box.size;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      color: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: context.border),
      ),
      // Anchor just above the FAB.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'chat',
          child: Row(
            children: [
              Icon(
                Icons.person_add_outlined,
                size: 18,
                color: context.textSecondary,
              ),
              const SizedBox(width: 10),
              const Text('New chat'),
            ],
          ),
        ),
        if (onNewGroup != null)
          PopupMenuItem<String>(
            value: 'group',
            child: Row(
              children: [
                Icon(
                  Icons.group_add_outlined,
                  size: 18,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 10),
                const Text('New group'),
              ],
            ),
          ),
        if (onDiscover != null)
          PopupMenuItem<String>(
            value: 'discover',
            child: Row(
              children: [
                Icon(
                  Icons.explore_outlined,
                  size: 18,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 10),
                const Text('Discover groups'),
              ],
            ),
          ),
      ],
    ).then((value) {
      switch (value) {
        case 'chat':
          onNewChat?.call();
        case 'group':
          onNewGroup?.call();
        case 'discover':
          onDiscover?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'New chat. Long-press for more options.',
      button: true,
      child: Material(
        color: context.accent,
        borderRadius: BorderRadius.circular(16),
        elevation: 4,
        child: InkWell(
          onTap: onNewChat,
          onLongPress: () => _openMenu(context),
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.edit_outlined, color: context.onAccent, size: 22),
          ),
        ),
      ),
    );
  }
}

/// Row widget used inside the status picker popup menu.
///
/// Each entry shows a coloured presence dot and a label, matching the visual
/// language used in conversation list items and user profile screens.
class _StatusMenuItem extends StatelessWidget {
  const _StatusMenuItem({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}
