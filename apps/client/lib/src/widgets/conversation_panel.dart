import 'dart:async';

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_slidable/flutter_slidable.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversation_filter_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/update_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/clipboard_service.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../theme/motion_tokens.dart';
import 'package:url_launcher/url_launcher.dart';
import '../providers/theme_provider.dart' show uiDensityProvider;
import '../utils/presence.dart';
import '../utils/time_utils.dart';
import 'avatar_utils.dart';
import 'confirm_dialog.dart';
import 'connection_status_badge.dart';
import 'context_menu/actions/conversation_actions_registry.dart';
import 'context_menu/echo_context_menu.dart';
import 'conversation_item.dart';
import 'echo_banner.dart';
import 'echo_logo_icon.dart';
import 'empty_state.dart';
import 'feedback_dialog.dart';
import 'skeleton_loader.dart';
import 'voice_dock.dart';
import 'voice_footer.dart';

// Re-export avatar utilities so existing `show` imports keep working.
export 'avatar_utils.dart'
    show buildAvatar, avatarColor, groupAvatarColor, resolveAvatarUrl;

part 'conversation_panel/parts/actions.dart';
part 'conversation_panel/parts/banners.dart';
part 'conversation_panel/parts/compose_fab.dart';
part 'conversation_panel/parts/header.dart';
part 'conversation_panel/parts/list_renderer.dart';

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

  /// Opens the cross-group threads inbox. Surfaced from the "+" menu
  /// next to Saved Messages.
  final VoidCallback? onThreads;

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
    this.onThreads,
    this.onShowKeyboardShortcuts,
    this.onScanQr,
    this.onMessageContact,
    this.externalSearchFocusNode,
    this.onNavigateToLounge,
  });

  @override
  ConsumerState<ConversationPanel> createState() => _ConversationPanelState();
}

class _ConversationPanelState extends ConsumerState<ConversationPanel>
    with
        _ConversationPanelActionsMixin,
        _ConversationPanelBannersMixin,
        _ConversationPanelComposeFabMixin,
        _ConversationPanelHeaderMixin,
        _ConversationPanelListRendererMixin {
  @override
  void initState() {
    super.initState();
    _loadPinnedIds();
    _startPendingRefreshLoop();
  }

  @override
  void didUpdateWidget(covariant ConversationPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    // Reset filter on external selection so the picked conversation is visible.
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
    super.dispose();
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

    final conversations = ref.watch(sortedConversationsProvider);

    return Container(
      color: context.sidebarBg,
      child: Stack(
        children: [
          Column(
            children: [
              _buildLogoHeader(context, pendingCount),
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
              // VoiceDock is inline (not floating) so update/bug-report stay reachable during calls (F-029).
              if (MediaQuery.sizeOf(context).width >= 600)
                // LayoutBuilder gives dock actual column width to avoid under-fill/overflow on resize (TD-11).
                LayoutBuilder(
                  builder: (context, constraints) => VoiceDock(
                    width: constraints.maxWidth,
                    onNavigateToLounge: widget.onNavigateToLounge,
                  ),
                ),
              if (MediaQuery.sizeOf(context).width >= 600)
                _buildSidebarUpdateBanner(context),
              if (MediaQuery.sizeOf(context).width >= 600)
                const SizedBox(height: 4),
              // Mobile renders VoiceFooter at Scaffold level (home_screen.dart); desktop uses VoiceDock above.
              if (MediaQuery.sizeOf(context).width < 600)
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
}
