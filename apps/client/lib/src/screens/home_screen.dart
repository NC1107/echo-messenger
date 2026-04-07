import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:url_launcher/url_launcher.dart';

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
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/chat_panel.dart';
import '../widgets/conversation_panel.dart'
    show ConversationPanel, buildAvatar, groupAvatarColor;
import '../widgets/members_panel.dart';
import '../utils/web_lifecycle.dart';
import '../widgets/voice_dock.dart';
import 'contacts_screen.dart';
import 'voice_lounge_screen.dart';
import 'create_group_screen.dart';
import 'discover_groups_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen>
    with WidgetsBindingObserver {
  Conversation? _selectedConversation;
  bool _showMembers = false;
  Timer? _pendingRefreshTimer;
  late final LiveKitVoiceNotifier _voiceRtcNotifier;

  // For narrow screen navigation
  int _narrowPanelIndex = 0; // 0 = conv list, 1 = chat

  // Voice lounge: when true and voice is active, show lounge instead of chat
  bool _showingLounge = true;

  // Settings inline state
  bool _showSettings = false;
  SettingsSection _settingsSection = SettingsSection.account;

  // Collapsible sidebar state
  bool _sidebarCollapsed = false;

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
    // Web: leave voice call on tab close
    registerBeforeUnload(() {
      _voiceRtcNotifier.leaveChannel();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    unregisterBeforeUnload();
    _pendingRefreshTimer?.cancel();
    _searchFocusNode.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      ref.read(contactsProvider.notifier).loadPending(force: true);
    } else if (state == AppLifecycleState.detached ||
        state == AppLifecycleState.paused) {
      // Leave voice call when app is closed or backgrounded
      _voiceRtcNotifier.leaveChannel();
    }
  }

  Future<void> _initData() async {
    // 1. Initialize crypto (awaited -- must complete before anything else)
    final cryptoNotifier = ref.read(cryptoProvider.notifier);
    await cryptoNotifier.initAndUploadKeys();

    // 2. Connect WebSocket
    final wsState = ref.read(websocketProvider);
    if (!wsState.isConnected) {
      ref.read(websocketProvider.notifier).connect();
    }

    // Clean up any stale voice session from a previous run.
    _voiceRtcNotifier.leaveChannel();

    // 3. Load conversations AFTER crypto and WS are set up
    await ref.read(conversationsProvider.notifier).loadConversations();

    // 4. Load contacts for pending badge
    ref.read(contactsProvider.notifier).loadContacts();
    ref.read(contactsProvider.notifier).loadPending(force: true);
    _startPendingRefreshLoop();

    // 5. Load privacy preferences used for read-receipt/plaintext behavior.
    await ref.read(privacyProvider.notifier).load();

    // 6. Check for app updates (non-blocking)
    ref.read(updateProvider.notifier).check();

    // 7. Show first-login server notice
    await _showServerNoticeIfNeeded();
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

  void _selectConversation(Conversation conv) {
    setState(() {
      _selectedConversation = conv;
      _narrowPanelIndex = 1;
      _showSettings = false;
    });
  }

  bool get _isDesktop => MediaQuery.of(context).size.width >= 900;

  void _openContacts() {
    if (_isDesktop) {
      _showContactsDialog();
    } else {
      context.push('/contacts');
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
      builder: (dialogContext) => Dialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        child: SizedBox(
          width: 480,
          height: 640,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: const DiscoverGroupsScreen(),
          ),
        ),
      ),
    );
  }

  /// Called from the Contacts tab in the sidebar when "Message" is tapped.
  Future<void> _messageContact(String userId, String username) async {
    final conv = await ref
        .read(conversationsProvider.notifier)
        .getOrCreateDm(userId, username);
    if (!mounted) return;
    if (conv != null) {
      _selectConversation(conv);
    } else {
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
      builder: (dialogContext) => Dialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        child: SizedBox(
          width: 480,
          height: 600,
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
      ),
    );
  }

  void _showCreateGroupDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        child: SizedBox(
          width: 480,
          height: 600,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(12),
            child: const CreateGroupScreen(),
          ),
        ),
      ),
    );
  }

  void _showGroupInfo() {
    final conv = _selectedConversation;
    if (conv == null || !conv.isGroup) return;
    context.push('/group-info/${conv.id}');
  }

  void _toggleMembers() {
    setState(() {
      _showMembers = !_showMembers;
    });
  }

  void _openSettings() {
    if (_isDesktop || MediaQuery.of(context).size.width >= 600) {
      setState(() {
        _showSettings = true;
        _settingsSection = SettingsSection.account;
      });
    } else {
      context.push('/settings');
    }
  }

  void _logout() {
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    ref.read(authProvider.notifier).logout();
    context.go('/login');
  }

  ConversationPanel _buildConversationPanel({VoidCallback? onCollapseSidebar}) {
    return ConversationPanel(
      selectedConversationId: _selectedConversation?.id,
      onConversationTap: _selectConversation,
      onNewChat: _openContacts,
      onNewGroup: _openCreateGroup,
      onDiscover: _openDiscoverGroups,
      onCollapseSidebar: onCollapseSidebar,
      onSettings: _openSettings,
      onShowContacts: _openContacts,
      onMessageContact: _messageContact,
      externalSearchFocusNode: _searchFocusNode,
    );
  }

  /// Builds a collapsed sidebar showing only avatars.
  Widget _buildCollapsedSidebar() {
    final conversationsState = ref.watch(conversationsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';
    final serverUrl = ref.read(serverUrlProvider);
    final conversations = conversationsState.conversations;

    return Container(
      width: 60,
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
                              final peer = conv.members
                                  .where((m) => m.userId != myUserId)
                                  .firstOrNull;
                              final peerAvatarUrl =
                                  (!conv.isGroup && peer?.avatarUrl != null)
                                  ? '$serverUrl${peer!.avatarUrl}'
                                  : null;
                              return buildAvatar(
                                name: displayName,
                                radius: 18,
                                imageUrl: peerAvatarUrl,
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
              child: IconButton(
                icon: const Icon(Icons.settings_outlined, size: 18),
                color: context.textSecondary,
                tooltip: 'Settings',
                onPressed: _openSettings,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
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
            child: SettingsNavList(
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
          _searchFocusNode.requestFocus();
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
    });

    ref.listen<CryptoState>(cryptoProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ToastService.show(
          context,
          'Encryption: ${next.error}',
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
  }

  /// Desktop layout: sidebar + flex chat + optional 280px members panel
  Widget _buildDesktopLayout() {
    const sidebarWidth = 320.0;

    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    // Auto-show lounge when voice becomes active
    if (voiceActive && !_showingLounge) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _showingLounge = true);
      });
    }

    // Determine what the right panel shows
    Widget rightPanel;
    if (_showSettings) {
      rightPanel = SettingsContent(
        key: ValueKey(_settingsSection),
        section: _settingsSection,
      );
    } else if (voiceActive && _showingLounge) {
      rightPanel = VoiceLoungeScreen(
        onBackToChat: () {
          setState(() => _showingLounge = false);
        },
      );
    } else if (_selectedConversation != null) {
      rightPanel = ChatPanel(
        conversation: _selectedConversation,
        onGroupInfo: _showGroupInfo,
        onMembersToggle: _selectedConversation?.isGroup == true
            ? _toggleMembers
            : null,
        hideVoiceDock: true,
      );
    } else {
      rightPanel = _buildEmptyState();
    }

    final animatedSidebarWidth = _sidebarCollapsed ? 60.0 : sidebarWidth;
    final showVoiceDock = voiceActive;

    return Scaffold(
      body: Stack(
        children: [
          Row(
            children: [
              // Left sidebar with animated width
              if (_showSettings)
                _buildSettingsSidebar(sidebarWidth)
              else
                AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOut,
                  width: animatedSidebarWidth,
                  clipBehavior: Clip.hardEdge,
                  decoration: const BoxDecoration(),
                  child: _sidebarCollapsed
                      ? _buildCollapsedSidebar()
                      : _buildConversationPanel(
                          onCollapseSidebar: () =>
                              setState(() => _sidebarCollapsed = true),
                        ),
                ),
              // Thin vertical divider
              Container(width: 1, color: context.border),
              // Center: content area (flex) + optional update banner
              Expanded(
                child: Column(
                  children: [
                    _buildUpdateBanner(),
                    Expanded(child: rightPanel),
                  ],
                ),
              ),
              // Right: members panel (optional, 280px)
              if (!_showSettings &&
                  _showMembers &&
                  _selectedConversation != null &&
                  _selectedConversation!.isGroup) ...[
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
              ],
            ],
          ),
          // Discord-style voice dock -- always above user status bar (60px)
          if (showVoiceDock)
            Positioned(
              bottom: 60,
              left: 0,
              child: VoiceDock(width: animatedSidebarWidth),
            ),
        ],
      ),
    );
  }

  /// Tablet layout (600-899px): sidebar + flex chat
  Widget _buildWideLayout() {
    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    Widget rightPanel;
    if (_showSettings) {
      rightPanel = SettingsContent(
        key: ValueKey(_settingsSection),
        section: _settingsSection,
      );
    } else if (voiceActive && _showingLounge) {
      rightPanel = VoiceLoungeScreen(
        onBackToChat: () {
          setState(() => _showingLounge = false);
        },
      );
    } else if (_selectedConversation != null) {
      rightPanel = ChatPanel(
        conversation: _selectedConversation,
        onGroupInfo: _showGroupInfo,
      );
    } else {
      rightPanel = _buildEmptyState();
    }

    return Scaffold(
      body: Row(
        children: [
          // Left sidebar
          if (_showSettings)
            _buildSettingsSidebar(300)
          else
            SizedBox(width: 300, child: _buildConversationPanel()),
          // Thin vertical divider
          Container(width: 1, color: context.border),
          // Right: content area + optional update banner
          Expanded(
            child: Column(
              children: [
                _buildUpdateBanner(),
                Expanded(child: rightPanel),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildNarrowLayout() {
    if (_narrowPanelIndex == 1 && _selectedConversation != null) {
      return Scaffold(
        body: Column(
          children: [
            Container(
              height: 56,
              color: context.chatBg,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_outlined, size: 20),
                    color: context.textSecondary,
                    onPressed: () {
                      setState(() => _narrowPanelIndex = 0);
                    },
                  ),
                ],
              ),
            ),
            Expanded(
              child: ChatPanel(
                conversation: _selectedConversation,
                onGroupInfo: _showGroupInfo,
              ),
            ),
          ],
        ),
      );
    }

    return Scaffold(body: _buildConversationPanel());
  }

  Widget _buildUpdateBanner() {
    final update = ref.watch(updateProvider);

    // Nothing to show
    if (!update.updateAvailable &&
        update.status != UpdateStatus.downloading &&
        update.status != UpdateStatus.readyToInstall &&
        update.status != UpdateStatus.installing &&
        update.status != UpdateStatus.error) {
      return const SizedBox.shrink();
    }
    if (update.dismissed &&
        update.status != UpdateStatus.downloading &&
        update.status != UpdateStatus.readyToInstall &&
        update.status != UpdateStatus.installing) {
      return const SizedBox.shrink();
    }

    String label;
    Widget action;
    Widget? trailing;
    Widget? progress;

    switch (update.status) {
      case UpdateStatus.downloading:
        final pct = (update.downloadProgress * 100).toInt();
        label = 'Downloading update... $pct%';
        action = TextButton(
          onPressed: () => ref.read(updateProvider.notifier).cancelDownload(),
          child: Text(
            'Cancel',
            style: TextStyle(color: context.textMuted, fontSize: 13),
          ),
        );
        trailing = null;
        progress = LinearProgressIndicator(
          value: update.downloadProgress,
          color: context.accent,
          backgroundColor: context.border,
          minHeight: 3,
        );
      case UpdateStatus.readyToInstall:
        label = 'Echo v${update.latestVersion} ready to install';
        action = FilledButton.icon(
          onPressed: () => ref.read(updateProvider.notifier).applyUpdate(),
          icon: const Icon(Icons.restart_alt, size: 16),
          label: const Text(
            'Restart to Update',
            style: TextStyle(fontSize: 12),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: context.accent,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          ),
        );
        trailing = TextButton(
          onPressed: () => ref.read(updateProvider.notifier).dismiss(),
          child: Text(
            'Later',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        );
        progress = null;
      case UpdateStatus.installing:
        label = 'Installing update...';
        action = const SizedBox(
          width: 16,
          height: 16,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
        trailing = null;
        progress = null;
      case UpdateStatus.error:
        label = 'Update failed';
        action = TextButton(
          onPressed: () => ref.read(updateProvider.notifier).downloadUpdate(),
          child: Text(
            'Retry',
            style: TextStyle(color: context.accent, fontSize: 13),
          ),
        );
        trailing = IconButton(
          icon: Icon(Icons.close, size: 16, color: context.textMuted),
          onPressed: () => ref.read(updateProvider.notifier).dismiss(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        );
        progress = null;
      default: // idle with updateAvailable
        label = 'Echo v${update.latestVersion} is available';
        action = TextButton(
          onPressed: update.assetDownloadUrl != null
              ? () => ref.read(updateProvider.notifier).downloadUpdate()
              : () {
                  final url = update.downloadUrl;
                  if (url != null) launchUrl(Uri.parse(url));
                },
          child: Text(
            update.assetDownloadUrl != null ? 'Update' : 'Download',
            style: TextStyle(
              color: context.accent,
              fontSize: 13,
              fontWeight: FontWeight.w700,
            ),
          ),
        );
        trailing = IconButton(
          icon: Icon(Icons.close, size: 16, color: context.textMuted),
          onPressed: () => ref.read(updateProvider.notifier).dismiss(),
          padding: EdgeInsets.zero,
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
        );
        progress = null;
    }

    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 8),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: context.surface,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(color: context.border),
                ),
                child: Row(
                  children: [
                    Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: context.accent.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Icon(
                        Icons.system_update,
                        size: 14,
                        color: context.accent,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        label,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    action,
                    // ignore: use_null_aware_elements
                    if (trailing != null) trailing,
                  ],
                ),
              ),
              if (progress != null)
                ClipRRect(
                  borderRadius: const BorderRadius.only(
                    bottomLeft: Radius.circular(10),
                    bottomRight: Radius.circular(10),
                  ),
                  child: progress,
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Container(
      color: context.chatBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 56,
              color: context.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 20),
            Text(
              'Select a conversation',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Pick someone from the left to start chatting',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
