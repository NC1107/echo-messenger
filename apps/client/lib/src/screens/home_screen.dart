import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/chat_panel.dart';
import '../widgets/conversation_panel.dart';
import '../widgets/server_rail.dart';

class HomeScreen extends ConsumerStatefulWidget {
  const HomeScreen({super.key});

  @override
  ConsumerState<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends ConsumerState<HomeScreen> {
  Conversation? _selectedConversation;
  String? _selectedGroupId;
  bool _dmSelected = true;

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
    // Initialize crypto
    final cryptoNotifier = ref.read(cryptoProvider.notifier);
    await cryptoNotifier.initAndUploadKeys();

    // Load conversations
    ref.read(conversationsProvider.notifier).loadConversations();

    // Connect WebSocket
    final wsState = ref.read(websocketProvider);
    if (!wsState.isConnected) {
      ref.read(websocketProvider.notifier).connect();
    }
  }

  void _logout() {
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    ref.read(authProvider.notifier).logout();
  }

  void _selectConversation(Conversation conv) {
    setState(() {
      _selectedConversation = conv;
      _narrowPanelIndex = 1;
    });
  }

  void _selectDm() {
    setState(() {
      _dmSelected = true;
      _selectedGroupId = null;
    });
  }

  void _selectGroup(Conversation group) {
    setState(() {
      _dmSelected = false;
      _selectedGroupId = group.id;
      _selectedConversation = group;
      _narrowPanelIndex = 1;
    });
  }

  void _showNewChatOptions() {
    showModalBottomSheet(
      context: context,
      backgroundColor: EchoTheme.panelBg,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading:
                  const Icon(Icons.person, color: EchoTheme.textSecondary),
              title: const Text('New Chat',
                  style: TextStyle(color: EchoTheme.textPrimary)),
              subtitle: const Text('Start a conversation with a contact',
                  style: TextStyle(color: EchoTheme.textMuted)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/contacts');
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_add,
                  color: EchoTheme.textSecondary),
              title: const Text('New Group',
                  style: TextStyle(color: EchoTheme.textPrimary)),
              subtitle: const Text('Create a group conversation',
                  style: TextStyle(color: EchoTheme.textMuted)),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/create-group');
              },
            ),
          ],
        ),
      ),
    );
  }

  void _showGroupInfo() {
    final conv = _selectedConversation;
    if (conv == null || !conv.isGroup) return;
    context.push('/group-info/${conv.id}');
  }

  @override
  Widget build(BuildContext context) {
    final width = MediaQuery.of(context).size.width;
    final isNarrow = width < 600;

    // Listen for errors
    ref.listen<ConversationsState>(conversationsProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(next.error!)));
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
    return _buildWideLayout();
  }

  Widget _buildWideLayout() {
    return Scaffold(
      body: Row(
        children: [
          // Server rail
          ServerRail(
            dmSelected: _dmSelected,
            selectedGroupId: _selectedGroupId,
            onDmTap: _selectDm,
            onGroupTap: _selectGroup,
            onCreateTap: _showNewChatOptions,
            onSettingsTap: _logout,
          ),
          // Conversation panel
          ConversationPanel(
            selectedConversationId: _selectedConversation?.id,
            filterGroupId: _dmSelected ? null : _selectedGroupId,
            onConversationTap: _selectConversation,
            onNewChat: _showNewChatOptions,
          ),
          // Chat panel
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

  Widget _buildNarrowLayout() {
    if (_narrowPanelIndex == 1 && _selectedConversation != null) {
      // Show chat with back button
      return Scaffold(
        body: Column(
          children: [
            // Custom back bar
            Container(
              height: 48,
              color: EchoTheme.chatBg,
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.arrow_back, size: 20),
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

    // Show conversation list
    return Scaffold(
      body: Row(
        children: [
          ServerRail(
            dmSelected: _dmSelected,
            selectedGroupId: _selectedGroupId,
            onDmTap: _selectDm,
            onGroupTap: _selectGroup,
            onCreateTap: _showNewChatOptions,
            onSettingsTap: _logout,
          ),
          Expanded(
            child: ConversationPanel(
              selectedConversationId: _selectedConversation?.id,
              filterGroupId: _dmSelected ? null : _selectedGroupId,
              onConversationTap: _selectConversation,
              onNewChat: _showNewChatOptions,
            ),
          ),
        ],
      ),
    );
  }
}
