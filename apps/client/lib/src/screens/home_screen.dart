import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/auth_provider.dart';
import '../services/toast_service.dart';
import '../providers/chat_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/update_provider.dart';
import '../providers/livekit_voice_provider.dart';
import '../providers/release_notes_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/debug_log_service.dart';
import '../services/notification_service.dart';
import '../services/tray_service.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../widgets/chat_panel.dart';
import '../widgets/conversation_panel.dart'
    show ConversationPanel, buildAvatar, groupAvatarColor, resolveAvatarUrl;
import '../widgets/members_panel.dart';
import '../utils/web_lifecycle.dart';
import '../version.dart';
import '../widgets/keyboard_shortcuts_overlay.dart';
import '../widgets/global_search_overlay.dart';
import '../widgets/whats_new_modal.dart';
import '../widgets/quick_switcher_overlay.dart';
import '../widgets/voice_dock.dart';
import '../widgets/voice_footer.dart';
import '../widgets/window_chrome.dart';
import 'contacts_screen.dart';
import 'new_message_screen.dart';
import 'saved_messages_screen.dart';
import 'voice_lounge_screen.dart';
import 'create_group_screen.dart';
import 'discover_groups_screen.dart';
import 'settings_screen.dart';
import '../widgets/profile_sheets.dart';

class HomeScreen extends ConsumerStatefulWidget {
  final String? initialConversationId;
  final String? initialMessageId;

  const HomeScreen({
    super.key,
    this.initialConversationId,
    this.initialMessageId,
  });

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  Conversation? _selectedConversation;
  String? _pendingMessageId;
  // Slice 7: members panel defaults to on so group context (roles, online
  // status) is visible without an explicit toggle. Users can still hide it.
  bool _showMembers = true;
  Timer? _pendingRefreshTimer;
  late final LiveKitVoiceNotifier _voiceRtcNotifier;
  StreamSubscription<String>? _notificationTapSub;

  // Edge-swipe constants for narrow chat → conversation-list navigation
  static const double _edgeSwipeZone = 60;
  static const double _edgeSwipeThreshold = 60;

  // For narrow screen navigation
  int _narrowPanelIndex = 0; // 0 = conv list, 1 = chat

  // Voice lounge: when true and voice is active, show lounge instead of chat
  bool _showingLounge = true;
  bool _userDismissedLounge = false;

  // Settings inline state
  bool _showSettings = false;
  SettingsSection _settingsSection = SettingsSection.profile;

  /// Bottom tab index on mobile narrow viewport.
  /// 0 = Chats, 1 = Discover, 2 = Contacts, 3 = Settings.
  int _mobileTabIndex = 0;

  // Collapsible sidebar state
  bool _sidebarCollapsed = false;
  double _sidebarWidth = 350;
  static const _sidebarMinWidth = 200.0;
  static const _sidebarMaxWidth = 500.0;

  /// Lower clamp during a resize drag — below `_sidebarMinWidth` so the
  /// drag-end handler can detect a pull-through and snap into compact mode
  /// (#739). Stays above 0 so the sidebar never visually vanishes mid-drag.
  static const _sidebarPullThroughWidth = 100.0;
  static const _sidebarCollapsedWidth = 60.0;
  static const _sidebarDefaultWidth = 350.0;

  // Search focus node for Ctrl+K shortcut
  final _searchFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _voiceRtcNotifier = ref.read(voiceRtcProvider.notifier);
    WidgetsBinding.instance.addObserver(this);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initData();
    });
    // Navigate to conversation when user taps a notification
    _notificationTapSub = NotificationService().onNotificationTap.listen(
      _onNotificationTap,
    );
    // Web: leave voice call on tab close
    registerBeforeUnload(() {
      _voiceRtcNotifier.leaveChannel();
    });
  }

  @override
  void dispose() {
    _notificationTapSub?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    unregisterBeforeUnload();
    _pendingRefreshTimer?.cancel();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // Keep the notification service in sync with app focus so that native
    // notifications are suppressed while the user is looking at the app.
    NotificationService().setAppFocused(state == AppLifecycleState.resumed);

    if (state == AppLifecycleState.resumed) {
      ref.read(contactsProvider.notifier).loadPending(force: true);
    } else if (state == AppLifecycleState.detached) {
      // Only leave voice on full app termination, not on background.
      // Mobile users expect calls to continue when switching apps or
      // locking the screen.
      _voiceRtcNotifier.leaveChannel();
    }
  }

  Future<void> _initData() async {
    // 1. Initialize crypto (awaited -- must complete before anything else).
    // SplashScreen calls initAndUploadKeys() during auto-login, so this is
    // typically a no-op (CryptoNotifier guards against double-init internally).
    // The guard below avoids the async round-trip in the common case.
    final cryptoState = ref.read(cryptoProvider);
    if (!cryptoState.isInitialized) {
      final cryptoNotifier = ref.read(cryptoProvider.notifier);
      await cryptoNotifier.initAndUploadKeys();
    }

    // 2. Connect WebSocket
    final wsState = ref.read(websocketProvider);
    if (!wsState.isConnected) {
      ref.read(websocketProvider.notifier).connect();
    }

    // Clean up any stale voice session from a previous run.
    _voiceRtcNotifier.leaveChannel();

    // 3. Load conversations AFTER crypto and WS are set up
    await ref.read(conversationsProvider.notifier).loadConversations();

    // 3b. Auto-select conversation if passed via query parameter
    if (widget.initialConversationId != null && _selectedConversation == null) {
      final conversations = ref.read(conversationsProvider).conversations;
      final conv = conversations
          .where((c) => c.id == widget.initialConversationId)
          .firstOrNull;
      if (conv != null) {
        _selectConversation(conv, messageId: widget.initialMessageId);
      }
    }

    // 4. Load contacts for pending badge
    ref.read(contactsProvider.notifier).loadContacts();
    ref.read(contactsProvider.notifier).loadPending(force: true);
    _startPendingRefreshLoop();

    // 5. Load privacy preferences used for read-receipt/plaintext behavior.
    await ref.read(privacyProvider.notifier).load();

    // 6. Check for app updates.  Awaited so step 6b can read the
    // resulting release-notes body and decide whether to show the
    // What's New modal — without await the body isn't populated yet
    // and the modal silently skips.  Cached path is sync (≤ 1ms);
    // network path is a single 10s-timeout GET so worst-case impact
    // on home-screen first paint is bounded.
    await ref.read(updateProvider.notifier).check();

    // 6b. Show the What's New modal once per upgrade.  No-op on fresh
    // install (releaseNotesProvider bootstraps last_shown = appVersion
    // so first launch never surfaces a changelog).
    await _showWhatsNewIfNeeded();

    // 7b. Init system tray (desktop only; no-op on web/mobile). The
    // "Check for updates" menu item routes through _handleTrayCheckForUpdates
    // so the tray service stays UI-agnostic and the toast surfaces here
    // where we have a BuildContext.
    unawaited(
      TrayService.instance.init(onCheckForUpdates: _handleTrayCheckForUpdates),
    );

    // 7. Show first-login server notice
    await _showServerNoticeIfNeeded();
  }

  /// Handler wired into the desktop system-tray "Check for updates" menu
  /// item. Forces a re-check of the GitHub releases API (bypasses the 1h
  /// cache) and surfaces the result via toast. The pre-existing
  /// update-available banner still fires for the "new version" path; this
  /// just adds the explicit "you are on the latest version" confirmation
  /// that's otherwise invisible when a check returns nothing new.
  Future<void> _handleTrayCheckForUpdates() async {
    if (!mounted) return;
    // Dev builds short-circuit inside Update.check(); be explicit so the
    // user isn't left wondering whether the click did anything.
    if (appVersion == 'dev') {
      ToastService.show(
        context,
        'Update check skipped on dev build',
        type: ToastType.info,
      );
      return;
    }
    ToastService.show(context, 'Checking for updates...', type: ToastType.info);
    await ref.read(updateProvider.notifier).check(force: true);
    if (!mounted) return;
    final update = ref.read(updateProvider);
    if (update.updateAvailable) {
      if (update.dismissed) {
        // User previously dismissed the banner for this version; the
        // explicit re-check is their signal that they actually want to
        // see it again, so surface a toast that points back at the
        // version (the banner stays hidden until the cache rolls).
        ToastService.show(
          context,
          'Update available: v${update.latestVersion}',
          type: ToastType.info,
        );
      }
      // Otherwise the persistent update banner already shows "vX is
      // available" with Update/Download/Later actions — a transient
      // toast on top of it would be redundant noise.
      return;
    }
    ToastService.show(
      context,
      'You are on the latest version',
      type: ToastType.success,
    );
  }

  Future<void> _showWhatsNewIfNeeded() async {
    if (!mounted) return;
    // Force AsyncNotifier.build() to run before reading .value — the
    // first read of an AsyncNotifierProvider returns AsyncLoading; we
    // need the resolved snapshot.
    await ref.read(releaseNotesProvider.future);
    if (!mounted) return;
    await maybeShowWhatsNew(context, ref);
  }

  void _startPendingRefreshLoop() {
    _pendingRefreshTimer?.cancel();
    _pendingRefreshTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (!mounted) return;
      ref.read(contactsProvider.notifier).loadPending();
    });
  }

  Future<void> _showServerNoticeIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool('seen_server_notice') ?? false;
    if (seen || !mounted) return;

    final serverUrl = ref.read(serverUrlProvider);
    final displayHost = Uri.tryParse(serverUrl)?.host ?? serverUrl;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Welcome to Echo',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'You\'re connected to the official Echo server at $displayHost\n\n'
          'Your messages are end-to-end encrypted. The server cannot read your messages.\n\n'
          'In the future, you\'ll be able to self-host your own Echo server.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Got it'),
          ),
        ],
      ),
    );

    await prefs.setBool('seen_server_notice', true);
  }

  void _selectConversation(Conversation conv, {String? messageId}) {
    setState(() {
      _selectedConversation = conv;
      _pendingMessageId = messageId;
      _narrowPanelIndex = 1;
      _showSettings = false;
      // Collapse the lounge so the selected chat is visible.
      // Only lock the auto-show when voice is already active (i.e., the user
      // is deliberately navigating away from an in-progress call).  When
      // voice is NOT yet active, leaving _userDismissedLounge false lets the
      // lounge auto-show the moment the user joins voice from this chat.
      _showingLounge = false;
      if (ref.read(voiceRtcProvider).isActive) {
        _userDismissedLounge = true;
      }
    });
    // Clear notifications for this conversation now that the user is viewing it.
    NotificationService().cancelConversationNotifications(conv.id);
  }

  void _showQuickSwitcher() {
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) =>
          QuickSwitcherOverlay(onSelect: (conv) => _selectConversation(conv)),
    );
  }

  void _showGlobalSearch() {
    showDialog(
      context: context,
      barrierColor: Colors.transparent,
      builder: (ctx) => GlobalSearchOverlay(
        onResultTap: (conversationId, messageId) {
          final conversations = ref.read(conversationsProvider).conversations;
          final conv = conversations
              .where((c) => c.id == conversationId)
              .firstOrNull;
          if (conv != null) _selectConversation(conv);
        },
        onContactTap: (userId, username) => _messageContact(userId, username),
      ),
    );
  }

  void _showKeyboardShortcuts() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.transparent,
      builder: (_) => const KeyboardShortcutsOverlay(),
    );
  }

  /// Called when the user taps a notification — find the conversation and select it.
  void _onNotificationTap(String conversationId) {
    if (!mounted || conversationId.isEmpty) return;
    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conv != null) {
      _selectConversation(conv);
    }
  }

  bool get _isDesktop => Responsive.isDesktop(context);

  void _openContacts() {
    if (_isDesktop) {
      _showContactsDialog();
    } else {
      context.push('/contacts');
    }
  }

  /// Opens the dedicated "New message" composer. Tapping a contact starts
  /// a DM and selects the resulting conversation. On desktop the composer
  /// is shown as a centered dialog; on mobile it pushes as a full screen.
  Future<void> _openNewMessage() async {
    if (_isDesktop) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final size = MediaQuery.of(dialogContext).size;
          return Dialog(
            backgroundColor: context.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: context.border),
            ),
            child: SizedBox(
              width: (size.width * 0.4).clamp(360, 520).toDouble(),
              height: (size.height * 0.7).clamp(440, 720).toDouble(),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: NewMessageScreen(
                  onStartConversation: (conv) {
                    Navigator.pop(dialogContext);
                    _selectConversation(conv);
                  },
                ),
              ),
            ),
          );
        },
      );
    } else {
      final result = await Navigator.of(context).push<Conversation>(
        MaterialPageRoute(
          builder: (_) => NewMessageScreen(
            onStartConversation: (conv) => Navigator.of(context).pop(conv),
          ),
          fullscreenDialog: true,
        ),
      );
      if (result != null && mounted) {
        _selectConversation(result);
      }
    }
  }

  void _openCreateGroup() {
    if (_isDesktop) {
      _showCreateGroupDialog();
    } else {
      context.push('/create-group');
    }
  }

  void _openDiscoverGroups() {
    if (_isDesktop) {
      _showDiscoverGroupsDialog();
    } else {
      context.push('/discover-groups');
    }
  }

  void _showDiscoverGroupsDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.4).clamp(320, 560).toDouble(),
            height: (size.height * 0.7).clamp(400, 720).toDouble(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: const DiscoverGroupsScreen(),
            ),
          ),
        );
      },
    );
  }

  /// Called from the Contacts tab in the sidebar when "Message" is tapped.
  Future<void> _messageContact(String userId, String username) async {
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(userId, username);
      if (!mounted) return;
      _selectConversation(conv);
    } on DmException catch (e) {
      if (!mounted) return;
      ToastService.show(context, e.message, type: ToastType.error);
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not start conversation',
        type: ToastType.error,
      );
    }
  }

  void _showContactsDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.4).clamp(320, 560).toDouble(),
            height: (size.height * 0.65).clamp(400, 680).toDouble(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: ContactsScreen(
                onStartConversation: (conv) {
                  Navigator.pop(dialogContext);
                  _selectConversation(conv);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _showCreateGroupDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.4).clamp(320, 560).toDouble(),
            height: (size.height * 0.65).clamp(400, 680).toDouble(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: const CreateGroupScreen(),
            ),
          ),
        );
      },
    );
  }

  void _showGroupInfo() {
    final conv = _selectedConversation;
    if (conv == null || !conv.isGroup) return;
    showGroupProfileSheet(context, ref, conv.id);
  }

  void _toggleMembers() {
    setState(() {
      _showMembers = !_showMembers;
    });
  }

  void _openSavedMessages() {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    if (isMobile) {
      context.push('/saved');
      return;
    }
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.45).clamp(340.0, 600.0),
            height: (size.height * 0.7).clamp(400.0, 720.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(12),
              child: SavedMessagesScreen(
                onNavigateToConversation: (convId, messageId) {
                  Navigator.pop(dialogContext);
                  final conversations = ref
                      .read(conversationsProvider)
                      .conversations;
                  final conv = conversations
                      .where((c) => c.id == convId)
                      .firstOrNull;
                  if (conv != null) {
                    _selectConversation(conv, messageId: messageId);
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _openSettings() {
    if (_isDesktop || !Responsive.isMobile(context)) {
      setState(() {
        _showSettings = true;
        _settingsSection = SettingsSection.profile;
      });
    } else {
      context.push('/settings');
    }
  }

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Log Out',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Are you sure you want to log out?',
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
            child: const Text('Log Out'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    unawaited(ref.read(cryptoProvider.notifier).resetState());
    ref.read(authProvider.notifier).logout();
    if (mounted) context.go('/login');
  }

  ConversationPanel _buildConversationPanel({VoidCallback? onCollapseSidebar}) {
    return ConversationPanel(
      selectedConversationId: _selectedConversation?.id,
      onConversationTap: _selectConversation,
      onNewChat: _openNewMessage,
      onNewGroup: _openCreateGroup,
      onDiscover: _openDiscoverGroups,
      onSavedMessages: _openSavedMessages,
      onCollapseSidebar: onCollapseSidebar,
      onSettings: _openSettings,
      onShowContacts: _openContacts,
      onGlobalSearch: _showGlobalSearch,
      onShowKeyboardShortcuts: _showKeyboardShortcuts,
      onMessageContact: _messageContact,
      externalSearchFocusNode: _searchFocusNode,
      onNavigateToLounge: () => setState(() {
        _showingLounge = true;
        _userDismissedLounge = false;
      }),
    );
  }

  /// Builds a collapsed sidebar showing only avatars.
  Widget _buildCollapsedSidebar() {
    final conversationsState = ref.watch(conversationsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';
    final serverUrl = ref.read(serverUrlProvider);
    final conversations = conversationsState.conversations;

    return Container(
      width: _sidebarCollapsedWidth,
      color: context.sidebarBg,
      child: Column(
        children: [
          // Header with expand button
          Container(
            height: 56,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.border, width: 1),
              ),
            ),
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                color: context.textSecondary,
                tooltip: 'Expand sidebar',
                onPressed: () => setState(() => _sidebarCollapsed = false),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ),
          ),
          // Conversation avatars
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: conversations.length,
              itemBuilder: (context, index) {
                final conv = conversations[index];
                final displayName = conv.displayName(myUserId);
                final isSelected = conv.id == _selectedConversation?.id;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Tooltip(
                    message: displayName,
                    preferBelow: false,
                    child: Semantics(
                      label: 'conversation: $displayName',
                      button: true,
                      child: GestureDetector(
                        onTap: () => _selectConversation(conv),
                        child: Center(
                          child: Container(
                            decoration: BoxDecoration(
                              shape: BoxShape.circle,
                              border: isSelected
                                  ? Border.all(color: context.accent, width: 2)
                                  : null,
                            ),
                            child: Builder(
                              builder: (_) {
                                final String? avatarUrl;
                                if (conv.isGroup) {
                                  avatarUrl = resolveAvatarUrl(
                                    conv.iconUrl,
                                    serverUrl,
                                  );
                                } else {
                                  final peer = conv.members
                                      .where((m) => m.userId != myUserId)
                                      .firstOrNull;
                                  avatarUrl = resolveAvatarUrl(
                                    peer?.avatarUrl,
                                    serverUrl,
                                  );
                                }
                                return buildAvatar(
                                  name: displayName,
                                  radius: 18,
                                  imageUrl: avatarUrl,
                                  bgColor: conv.isGroup
                                      ? groupAvatarColor(displayName)
                                      : null,
                                  fallbackIcon: conv.isGroup
                                      ? const Icon(
                                          Icons.group,
                                          size: 16,
                                          color: Colors.white,
                                        )
                                      : null,
                                );
                              },
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Settings icon at bottom
          Container(
            height: 60,
            decoration: BoxDecoration(
              color: context.mainBg,
              border: Border(top: BorderSide(color: context.border, width: 1)),
            ),
            child: Center(
              child: Builder(
                builder: (context) {
                  final updateState = ref.watch(updateProvider);
                  final showUpdateDot =
                      updateState.updateAvailable && !updateState.dismissed;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.settings_outlined, size: 18),
                        color: context.textSecondary,
                        tooltip: 'Settings',
                        onPressed: _openSettings,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                      ),
                      if (showUpdateDot)
                        Positioned(
                          top: 10,
                          right: 10,
                          child: _DotBadge(
                            ringColor: context.mainBg,
                            bgColor: context.accent,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Builds the settings sidebar panel (replaces conversations when settings open).
  Widget _buildSettingsSidebar(double width) {
    return Container(
      width: width,
      color: context.sidebarBg,
      child: Column(
        children: [
          // Header with back button
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  color: context.textSecondary,
                  tooltip: 'Back to conversations',
                  onPressed: () => setState(() => _showSettings = false),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Settings',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Settings nav list
          Expanded(
            child: SettingsRootView(
              selected: _settingsSection,
              onTap: (section) => setState(() => _settingsSection = section),
              onLogout: _logout,
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 600;
    final isDesktop = width >= 900;

    _listenForErrors();
    _syncSelectedConversation();

    Widget layout;
    if (isNarrow) {
      layout = _buildNarrowLayout();
    } else if (isDesktop) {
      layout = _buildDesktopLayout();
    } else {
      layout = _buildWideLayout();
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyK, control: true): () {
          _showQuickSwitcher();
        },
        const SingleActivator(
          LogicalKeyboardKey.keyF,
          control: true,
          shift: true,
        ): () {
          _showGlobalSearch();
        },
        const SingleActivator(LogicalKeyboardKey.slash, control: true): () {
          _showKeyboardShortcuts();
        },
      },
      child: Focus(autofocus: true, child: layout),
    );
  }

  void _listenForErrors() {
    ref.listen<ConversationsState>(conversationsProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ToastService.show(context, next.error!, type: ToastType.error);
      }
      // Update tray badge when total unread count changes.
      if (TrayService.isSupported) {
        final prevTotal =
            prev?.conversations.fold<int>(0, (s, c) => s + c.unreadCount) ?? 0;
        final nextTotal = next.conversations.fold<int>(
          0,
          (s, c) => s + c.unreadCount,
        );
        if (nextTotal != prevTotal) {
          unawaited(TrayService.instance.updateBadge(nextTotal));
        }
      }
    });

    ref.listen<CryptoState>(cryptoProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ToastService.show(
          context,
          'Encryption: ${next.error}',
          type: ToastType.error,
        );
      }
      if (next.keysWereRegenerated && !(prev?.keysWereRegenerated ?? false)) {
        ToastService.show(
          context,
          'Your encryption keys were regenerated. '
          'Previous encrypted messages may not be readable.',
          type: ToastType.error,
        );
      }
    });

    ref.listen<LiveKitVoiceState>(voiceRtcProvider, (prev, next) {
      if (next.error == null || next.error == prev?.error) return;
      ToastService.show(context, next.error!, type: ToastType.error);
      _handleVoiceDisconnectRedirect(next);
    });
  }

  void _handleVoiceDisconnectRedirect(LiveKitVoiceState next) {
    if (next.error == 'Voice disconnected. Please sign in again.' &&
        !ref.read(authProvider).isLoggedIn &&
        mounted) {
      context.go('/login');
    }
  }

  /// Keep the selected conversation in sync with provider state so that
  /// changes (e.g. encryption toggle) propagate to ChatPanel immediately.
  /// IMPORTANT: Do NOT clear _selectedConversation when fresh is null --
  /// the conversation may be temporarily absent during a list reload.
  void _syncSelectedConversation() {
    if (_selectedConversation == null) return;
    final convs = ref.watch(conversationsProvider).conversations;
    final fresh = convs
        .where((c) => c.id == _selectedConversation!.id)
        .firstOrNull;
    if (fresh != null && fresh != _selectedConversation) {
      _selectedConversation = fresh;
    }
    // If the conversation was permanently removed (e.g. user left it),
    // clear selection so mobile doesn't get stuck showing a stale panel.
    if (fresh == null && convs.isNotEmpty) {
      // Only clear if conversations have loaded (non-empty list means the
      // list isn't mid-refresh). Empty list during reload is ambiguous.
      _selectedConversation = null;
      _narrowPanelIndex = 0;
    }
  }

  /// Desktop layout: sidebar + flex chat + optional 280px members panel
  Widget _buildDesktopLayout() {
    final sidebarWidth = _sidebarWidth;

    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    _autoShowLoungeOnJoin(voiceActive);

    final rightPanel = _resolveRightPanel(voiceActive);
    final animatedSidebarWidth = _sidebarCollapsed
        ? _sidebarCollapsedWidth
        : sidebarWidth;

    // Show the overlay window controls when the right panel is not a
    // ChatPanel (which provides its own AppWindowButtons in its header).
    final myUserId = ref.watch(authProvider).userId ?? '';
    final titleBarText = (!_showSettings && _selectedConversation != null)
        ? _selectedConversation!.displayName(myUserId)
        : null;

    return Scaffold(
      body: Column(
        children: [
          AppTitleBar(title: titleBarText),
          Expanded(
            child: Stack(
              children: [
                Row(
                  children: [
                    _buildDesktopSidebar(sidebarWidth, animatedSidebarWidth),
                    _buildResizeHandle(),
                    Expanded(child: rightPanel),
                    ..._buildMembersPanel(),
                  ],
                ),
                if (voiceActive && !_showSettings)
                  _buildDesktopVoiceDock(animatedSidebarWidth),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Auto-show lounge on initial voice join; reset dismiss flag when voice
  /// becomes inactive so the next join auto-shows again.
  void _autoShowLoungeOnJoin(bool voiceActive) {
    if (voiceActive && !_showingLounge && !_userDismissedLounge) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final voiceLk = ref.read(voiceRtcProvider);
          DebugLogService.instance.log(
            LogLevel.info,
            'HomeScreen',
            'auto-showing lounge: '
                'channelId=${voiceLk.channelId ?? "none"} '
                'conversationId=${voiceLk.conversationId ?? "none"}',
          );
          setState(() => _showingLounge = true);
        }
      });
    }
    if (!voiceActive && _userDismissedLounge) {
      _userDismissedLounge = false;
    }
  }

  /// Determine the right-panel content based on settings, voice, or chat.
  Widget _resolveRightPanel(bool voiceActive) {
    if (_showSettings) {
      return SettingsContent(
        key: ValueKey(_settingsSection),
        section: _settingsSection,
      );
    }
    if (voiceActive && _showingLounge) {
      return VoiceLoungeScreen(
        onBackToChat: () {
          setState(() {
            _showingLounge = false;
            _userDismissedLounge = true;
          });
        },
      );
    }
    if (_selectedConversation != null) {
      return ChatPanel(
        conversation: _selectedConversation,
        onGroupInfo: _showGroupInfo,
        onMembersToggle: _selectedConversation?.isGroup == true
            ? _toggleMembers
            : null,
        hideVoiceDock: true,
        initialMessageId: _pendingMessageId,
        onShowLounge: () => setState(() {
          _showingLounge = true;
          _userDismissedLounge = false;
        }),
      );
    }
    return _buildEmptyState();
  }

  /// Desktop sidebar: either settings sidebar or conversation panel
  /// (collapsible with animated width).
  Widget _buildDesktopSidebar(double sidebarWidth, double animatedWidth) {
    if (_showSettings) return _buildSettingsSidebar(sidebarWidth);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: animatedWidth,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: _sidebarCollapsed
          ? _buildCollapsedSidebar()
          : _buildConversationPanel(
              onCollapseSidebar: () => setState(() => _sidebarCollapsed = true),
            ),
    );
  }

  /// Draggable resize handle between sidebar and content area.
  Widget _buildResizeHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: Semantics(
        label: 'Resize sidebar',
        child: GestureDetector(
          onHorizontalDragUpdate: (details) {
            if (_sidebarCollapsed) return;
            // Allow dragging below `_sidebarMinWidth` so users can pull the
            // handle through to compact mode and the drag-end handler can
            // snap to collapsed. The lower clamp keeps the sidebar from
            // disappearing entirely mid-drag (#739).
            setState(() {
              _sidebarWidth = (_sidebarWidth + details.delta.dx).clamp(
                _sidebarPullThroughWidth,
                _sidebarMaxWidth,
              );
            });
          },
          onHorizontalDragEnd: (details) {
            setState(() {
              if (_sidebarWidth < _sidebarMinWidth) {
                // User pulled past the min — snap to compact and restore the
                // expanded default for the next expand-from-compact toggle.
                _sidebarCollapsed = true;
                _sidebarWidth = _sidebarDefaultWidth;
              }
            });
          },
          onDoubleTap: () {
            setState(() {
              if (_sidebarCollapsed) {
                _sidebarCollapsed = false;
                _sidebarWidth = _sidebarDefaultWidth;
              } else {
                _sidebarCollapsed = true;
              }
            });
          },
          child: Container(
            width: 12,
            color: Colors.transparent,
            child: Center(child: Container(width: 1, color: context.border)),
          ),
        ),
      ),
    );
  }

  /// Optional 280px members panel on the right side.
  List<Widget> _buildMembersPanel() {
    if (_showSettings ||
        !_showMembers ||
        _selectedConversation == null ||
        !_selectedConversation!.isGroup) {
      return const [];
    }
    return [
      Container(width: 1, color: context.border),
      MembersPanel(
        conversation: _selectedConversation,
        onGroupLeft: () {
          setState(() {
            _selectedConversation = null;
            _showMembers = false;
            _narrowPanelIndex = 0;
          });
        },
      ),
    ];
  }

  /// Voice dock positioned above the user status bar.
  Widget _buildDesktopVoiceDock(double animatedSidebarWidth) {
    return AnimatedPositioned(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      bottom: 60,
      left: 0,
      width: animatedSidebarWidth,
      child: VoiceDock(
        width: animatedSidebarWidth,
        collapsed: _sidebarCollapsed,
        onNavigateToLounge: () {
          setState(() {
            _showingLounge = true;
            _userDismissedLounge = false;
          });
        },
      ),
    );
  }

  /// Tablet layout (600-899px): sidebar + flex chat
  Widget _buildWideLayout() {
    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    _autoShowLoungeOnJoin(voiceActive);

    Widget rightPanel;
    if (_showSettings) {
      rightPanel = SettingsContent(
        key: ValueKey(_settingsSection),
        section: _settingsSection,
      );
    } else if (voiceActive && _showingLounge) {
      rightPanel = VoiceLoungeScreen(
        onBackToChat: () {
          setState(() {
            _showingLounge = false;
            _userDismissedLounge = true;
          });
        },
      );
    } else if (_selectedConversation != null) {
      rightPanel = ChatPanel(
        conversation: _selectedConversation,
        onGroupInfo: _showGroupInfo,
        initialMessageId: _pendingMessageId,
        onShowLounge: () => setState(() {
          _showingLounge = true;
          _userDismissedLounge = false;
        }),
      );
    } else {
      rightPanel = _buildEmptyState();
    }

    final myUserId = ref.watch(authProvider).userId ?? '';
    final titleBarText = (!_showSettings && _selectedConversation != null)
        ? _selectedConversation!.displayName(myUserId)
        : null;

    return Scaffold(
      body: Column(
        children: [
          AppTitleBar(title: titleBarText),
          Expanded(
            child: Row(
              children: [
                // Left sidebar
                if (_showSettings)
                  _buildSettingsSidebar(300)
                else
                  SizedBox(width: 300, child: _buildConversationPanel()),
                // Thin vertical divider
                Container(width: 1, color: context.border),
                // Right: content area
                Expanded(child: rightPanel),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Build the narrow chat panel with voice banner and edge-swipe support.
  Widget _buildNarrowChatPanel(LiveKitVoiceState voiceRtc, bool voiceActive) {
    // Show voice lounge when voice is active and user hasn't dismissed it
    if (voiceActive && _showingLounge) {
      return Scaffold(
        body: SafeArea(
          child: VoiceLoungeScreen(
            onBackToChat: () => setState(() {
              _showingLounge = false;
              _userDismissedLounge = true;
            }),
          ),
        ),
      );
    }

    Widget chatContent = ChatPanel(
      conversation: _selectedConversation,
      onGroupInfo: _showGroupInfo,
      onBack: () => setState(() => _narrowPanelIndex = 0),
      initialMessageId: _pendingMessageId,
      onShowLounge: () => setState(() {
        _showingLounge = true;
        _userDismissedLounge = false;
      }),
    );

    // Note: a "● <channel> — Tap to view voice" rejoin banner used to sit
    // between the chat and a dismissed lounge.  It has been removed because
    // the persistent VoiceDock at the bottom of the sidebar already shows
    // the active voice channel name + status indicator + controls and is
    // tappable to reopen the lounge -- the banner duplicated that affordance.

    return Scaffold(
      body: SafeArea(
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _narrowPanelIndex = 0);
          },
          child: GestureDetector(
            onHorizontalDragStart: (startDetails) {
              _swipeStartX = startDetails.globalPosition.dx;
            },
            onHorizontalDragUpdate: (details) {
              if (_swipeStartX != null &&
                  _swipeStartX! < _edgeSwipeZone &&
                  details.globalPosition.dx - _swipeStartX! >
                      _edgeSwipeThreshold) {
                _swipeStartX = null;
                setState(() => _narrowPanelIndex = 0);
              }
            },
            onHorizontalDragEnd: (_) {},
            child: chatContent,
          ),
        ),
      ),
    );
  }

  Widget _buildNarrowLayout() {
    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    _autoShowLoungeOnJoin(voiceActive);

    // Voice lounge takes precedence over any tab on mobile narrow.  Without
    // this gate, joining voice from Discover/Contacts/Settings left the user
    // staring at that tab while the lounge state was already true.
    if (voiceActive && _showingLounge) {
      return Scaffold(
        body: SafeArea(
          child: VoiceLoungeScreen(
            onBackToChat: () => setState(() {
              _showingLounge = false;
              _userDismissedLounge = true;
            }),
          ),
        ),
      );
    }

    // When on the Chats tab AND a conversation is open, render the chat
    // full-screen with no bottom tab bar. Pressing back returns to the
    // conversation list with the tab bar visible.
    if (_mobileTabIndex == 0 &&
        _narrowPanelIndex == 1 &&
        _selectedConversation != null) {
      return _buildNarrowChatPanel(voiceRtc, voiceActive);
    }

    final Widget body;
    switch (_mobileTabIndex) {
      case 1:
        body = const DiscoverGroupsScreen();
      case 2:
        body = const ContactsScreen();
      case 3:
        body = const SettingsScreen();
      case 0:
      default:
        body = SafeArea(child: _buildConversationPanel());
    }

    return Scaffold(
      body: Column(
        children: [
          Expanded(child: body),
          // Show the voice footer between the content and the tab bar when
          // the user is in a call but has dismissed the lounge overlay.
          if (voiceActive && !_showingLounge)
            VoiceFooter(
              onNavigateToLounge: () => setState(() {
                _showingLounge = true;
                _userDismissedLounge = false;
              }),
            ),
        ],
      ),
      bottomNavigationBar: _buildMobileTabBar(),
    );
  }

  /// Bottom tab bar shown on the mobile narrow viewport. Switching tabs
  /// preserves each tab's local state via the parent state holder, and
  /// resets the chat-detail navigation when switching away from Chats.
  Widget _buildMobileTabBar() {
    final unreadTotal = ref
        .watch(conversationsProvider)
        .conversations
        .fold<int>(0, (s, c) => s + c.unreadCount);
    final updateState = ref.watch(updateProvider);
    final showUpdateDot = updateState.updateAvailable && !updateState.dismissed;

    final tabs = <_MobileTabSpec>[
      _MobileTabSpec(
        label: 'Chats',
        outlinedIcon: Icons.chat_bubble_outline,
        filledIcon: Icons.chat_bubble,
        badge: unreadTotal,
      ),
      const _MobileTabSpec(
        label: 'Discover',
        outlinedIcon: Icons.explore_outlined,
        filledIcon: Icons.explore,
      ),
      const _MobileTabSpec(
        label: 'Contacts',
        outlinedIcon: Icons.people_outline,
        filledIcon: Icons.people,
      ),
      _MobileTabSpec(
        label: 'Settings',
        outlinedIcon: Icons.settings_outlined,
        filledIcon: Icons.settings,
        showDot: showUpdateDot,
      ),
    ];

    return Material(
      color: context.sidebarBg,
      child: SafeArea(
        top: false,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.border, width: 1)),
          ),
          child: Row(
            children: List.generate(tabs.length, (i) {
              final isActive = i == _mobileTabIndex;
              final tab = tabs[i];
              return Expanded(
                child: Semantics(
                  selected: isActive,
                  button: true,
                  // "Chats tab", "Discover tab", etc. The trailing word matches
                  // the e2e a11y selectors (`getByRole('button', { name: /chats
                  // tab/i })`) and reads naturally to screen readers.
                  label: '${tab.label} tab',
                  child: InkWell(
                    onTap: () {
                      if (i == _mobileTabIndex) return;
                      setState(() {
                        _mobileTabIndex = i;
                        if (i != 0) {
                          _narrowPanelIndex = 0;
                        }
                      });
                    },
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Stack(
                          clipBehavior: Clip.none,
                          children: [
                            Icon(
                              isActive ? tab.filledIcon : tab.outlinedIcon,
                              size: 24,
                              color: isActive
                                  ? context.accent
                                  : context.textMuted,
                            ),
                            if (tab.badge > 0)
                              Positioned(
                                top: -3,
                                right: -8,
                                child: _UnreadBadge(
                                  count: tab.badge,
                                  ringColor: context.sidebarBg,
                                  bgColor: context.accent,
                                ),
                              )
                            else if (tab.showDot)
                              Positioned(
                                top: -2,
                                right: -2,
                                child: _DotBadge(
                                  ringColor: context.sidebarBg,
                                  bgColor: context.accent,
                                ),
                              ),
                          ],
                        ),
                        const SizedBox(height: 3),
                        Text(
                          tab.label,
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: isActive
                                ? FontWeight.w600
                                : FontWeight.w500,
                            color: isActive
                                ? context.accent
                                : context.textMuted,
                            letterSpacing: 0.1,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              );
            }),
          ),
        ),
      ),
    );
  }

  double? _swipeStartX;

  Widget _buildEmptyState() {
    return Container(
      color: context.chatBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.forum_rounded,
              size: 64,
              color: context.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 24),
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
              'Choose a conversation from the sidebar or start a new chat',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
            const SizedBox(height: 24),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                FilledButton.icon(
                  onPressed: _openContacts,
                  icon: const Icon(Icons.person_add_outlined, size: 18),
                  label: const Text('Add Contact'),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.accent,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: _openDiscoverGroups,
                  icon: const Icon(Icons.explore_outlined, size: 18),
                  label: const Text('Browse Groups'),
                  style: OutlinedButton.styleFrom(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 20,
                      vertical: 12,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MobileTabSpec {
  final String label;
  final IconData outlinedIcon;
  final IconData filledIcon;
  final int badge;

  /// Show a small accent-coloured dot (no count) on top of the icon. Used to
  /// surface low-frequency, non-critical signals — e.g. an available update
  /// (#792). [badge] takes precedence when both are set.
  final bool showDot;

  const _MobileTabSpec({
    required this.label,
    required this.outlinedIcon,
    required this.filledIcon,
    this.badge = 0,
    this.showDot = false,
  });
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  final Color ringColor;
  final Color bgColor;
  const _UnreadBadge({
    required this.count,
    required this.ringColor,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: 4),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: ringColor, width: 2),
      ),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

/// Small dot indicator (no count). Used for low-frequency, non-critical
/// signals like an available update on the Settings icon (#792).
class _DotBadge extends StatelessWidget {
  final Color ringColor;
  final Color bgColor;
  const _DotBadge({required this.ringColor, required this.bgColor});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'update available',
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: 1.5),
        ),
      ),
    );
  }
}
