import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/conversation.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/chat_panel.dart';
import '../widgets/conversation_panel.dart';
import '../widgets/members_panel.dart';
import 'contacts_screen.dart';
import 'create_group_screen.dart';

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

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initData();
    });
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

  void _showDiscoverSnackbar() {
    if (mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('Coming soon')));
    }
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

  ConversationPanel _buildConversationPanel() {
    return ConversationPanel(
      selectedConversationId: _selectedConversation?.id,
      onConversationTap: _selectConversation,
      onNewChat: _openContacts,
      onNewGroup: _openCreateGroup,
      onDiscover: _showDiscoverSnackbar,
      onSettings: () => context.push('/settings'),
      onShowContacts: _openContacts,
      onMessageContact: _messageContact,
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

    if (isNarrow) {
      return _buildNarrowLayout();
    }
    if (isDesktop) {
      return _buildDesktopLayout();
    }
    return _buildWideLayout();
  }

  /// Desktop layout: 320px sidebar + flex chat + optional 280px members panel
  Widget _buildDesktopLayout() {
    return Scaffold(
      body: Row(
        children: [
          // Left sidebar: conversations (320px)
          SizedBox(width: 320, child: _buildConversationPanel()),
          // Thin vertical divider
          Container(width: 1, color: EchoTheme.border),
          // Center: chat area (flex)
          Expanded(
            child: _selectedConversation != null
                ? ChatPanel(
                    conversation: _selectedConversation,
                    onGroupInfo: _showGroupInfo,
                    onMembersToggle: _selectedConversation?.isGroup == true
                        ? _toggleMembers
                        : null,
                  )
                : _buildEmptyState(),
          ),
          // Right: members panel (optional, 280px)
          if (_showMembers &&
              _selectedConversation != null &&
              _selectedConversation!.isGroup) ...[
            Container(width: 1, color: EchoTheme.border),
            MembersPanel(conversation: _selectedConversation),
          ],
        ],
      ),
    );
  }

  /// Tablet layout (600-899px): 300px sidebar + flex chat
  Widget _buildWideLayout() {
    return Scaffold(
      body: Row(
        children: [
          // Left sidebar: conversations
          SizedBox(width: 300, child: _buildConversationPanel()),
          // Thin vertical divider
          Container(width: 1, color: EchoTheme.border),
          // Right: chat area
          Expanded(
            child: _selectedConversation != null
                ? ChatPanel(
                    conversation: _selectedConversation,
                    onGroupInfo: _showGroupInfo,
                  )
                : _buildEmptyState(),
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
