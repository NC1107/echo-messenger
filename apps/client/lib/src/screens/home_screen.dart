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
import '../providers/chat_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/chat_panel.dart';
import '../widgets/conversation_panel.dart'
    show ConversationPanel, buildAvatar, groupAvatarColor;
import '../widgets/members_panel.dart';
import 'contacts_screen.dart';
import 'create_group_screen.dart';
import 'discover_groups_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Conversation? _selectedConversation;
  bool _showMembers = false;

  // For narrow screen navigation
  int _narrowPanelIndex = 0; // 0 = conv list, 1 = chat

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
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initData();
    });
  }

  @override
  void dispose() {
    _searchFocusNode.dispose();
    super.dispose();
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

    // 3. Load conversations AFTER crypto and WS are set up
    await ref.read(conversationsProvider.notifier).loadConversations();

    // 4. Load contacts for pending badge
    ref.read(contactsProvider.notifier).loadContacts();
    ref.read(contactsProvider.notifier).loadPending();

    // 5. Show first-login server notice
    await _showServerNoticeIfNeeded();
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
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
        ),
        title: const Text(
          'Welcome to Echo',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'You\'re connected to the official Echo server at $displayHost\n\n'
          'Your messages are end-to-end encrypted. The server cannot read your messages.\n\n'
          'In the future, you\'ll be able to self-host your own Echo server.',
          style: const TextStyle(
            color: EchoTheme.textSecondary,
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
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not start conversation')),
      );
    }
  }

  void _showContactsDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) => Dialog(
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
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
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
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

  ConversationPanel _buildConversationPanel() {
    return ConversationPanel(
      selectedConversationId: _selectedConversation?.id,
      onConversationTap: _selectConversation,
      onNewChat: _openContacts,
      onNewGroup: _openCreateGroup,
      onDiscover: _openDiscoverGroups,
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
    final conversations = conversationsState.conversations;

    return Container(
      width: 60,
      color: EchoTheme.sidebarBg,
      child: Column(
        children: [
          // Header with expand button
          Container(
            height: 56,
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                color: EchoTheme.textSecondary,
                tooltip: 'Expand sidebar',
                onPressed: () => setState(() => _sidebarCollapsed = false),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 36, minHeight: 36),
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
                                ? Border.all(color: EchoTheme.accent, width: 2)
                                : null,
                          ),
                          child: buildAvatar(
                            name: displayName,
                            radius: 18,
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
            decoration: const BoxDecoration(
              color: EchoTheme.mainBg,
              border: Border(
                top: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.settings_outlined, size: 18),
                color: EchoTheme.textSecondary,
                tooltip: 'Settings',
                onPressed: _openSettings,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
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
      color: EchoTheme.sidebarBg,
      child: Column(
        children: [
          // Header with back button
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              border: Border(
                bottom: BorderSide(color: EchoTheme.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  color: EchoTheme.textSecondary,
                  tooltip: 'Back to conversations',
                  onPressed: () => setState(() => _showSettings = false),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
                  ),
                ),
                const SizedBox(width: 8),
                const Text(
                  'Settings',
                  style: TextStyle(
                    color: EchoTheme.textPrimary,
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

    // Listen for errors
    ref.listen<ConversationsState>(conversationsProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    ref.listen<CryptoState>(cryptoProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Encryption: ${next.error}'),
            backgroundColor: EchoTheme.danger,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    });

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

  /// Desktop layout: sidebar + flex chat + optional 280px members panel
  Widget _buildDesktopLayout() {
    final sidebarWidth = 320.0;

    // Determine what the right panel shows
    Widget rightPanel;
    if (_showSettings) {
      rightPanel = SettingsContent(
        key: ValueKey(_settingsSection),
        section: _settingsSection,
      );
    } else if (_selectedConversation != null) {
      rightPanel = ChatPanel(
        conversation: _selectedConversation,
        onGroupInfo: _showGroupInfo,
        onMembersToggle: _selectedConversation?.isGroup == true
            ? _toggleMembers
            : null,
      );
    } else {
      rightPanel = _buildEmptyState();
    }

    return Scaffold(
      body: Row(
        children: [
          // Left sidebar
          if (_sidebarCollapsed)
            _buildCollapsedSidebar()
          else if (_showSettings)
            _buildSettingsSidebar(sidebarWidth)
          else
            SizedBox(
              width: sidebarWidth,
              child: Stack(
                children: [
                  _buildConversationPanel(),
                  // Collapse button at bottom of header
                  Positioned(
                    top: 16,
                    right: 4,
                    child: IconButton(
                      icon: const Icon(Icons.chevron_left, size: 18),
                      color: EchoTheme.textMuted,
                      tooltip: 'Collapse sidebar',
                      onPressed: () => setState(() => _sidebarCollapsed = true),
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(
                        minWidth: 24,
                        minHeight: 24,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          // Thin vertical divider
          Container(width: 1, color: EchoTheme.border),
          // Center: content area (flex)
          Expanded(child: rightPanel),
          // Right: members panel (optional, 280px)
          if (!_showSettings &&
              _showMembers &&
              _selectedConversation != null &&
              _selectedConversation!.isGroup) ...[
            Container(width: 1, color: EchoTheme.border),
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
    );
  }

  /// Tablet layout (600-899px): sidebar + flex chat
  Widget _buildWideLayout() {
    Widget rightPanel;
    if (_showSettings) {
      rightPanel = SettingsContent(
        key: ValueKey(_settingsSection),
        section: _settingsSection,
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
          Container(width: 1, color: EchoTheme.border),
          // Right: content area
          Expanded(child: rightPanel),
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
              color: EchoTheme.chatBg,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back_outlined, size: 20),
                    color: EchoTheme.textSecondary,
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

  Widget _buildEmptyState() {
    return Container(
      color: EchoTheme.chatBg,
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.chat_bubble_outline_rounded,
              size: 56,
              color: EchoTheme.textMuted.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 20),
            const Text(
              'Select a conversation',
              style: TextStyle(
                color: EchoTheme.textSecondary,
                fontSize: 18,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 8),
            const Text(
              'Pick someone from the left to start chatting',
              style: TextStyle(color: EchoTheme.textMuted, fontSize: 14),
            ),
          ],
        ),
      ),
    );
  }
}
