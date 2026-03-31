import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/websocket_provider.dart';

class ConversationsScreen extends ConsumerStatefulWidget {
  const ConversationsScreen({super.key});

  @override
  ConsumerState<ConversationsScreen> createState() =>
      _ConversationsScreenState();
}

class _ConversationsScreenState extends ConsumerState<ConversationsScreen> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _initData();
    });
  }

  Future<void> _initData() async {
    // Initialize crypto (generate keys, upload to server)
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

  void _showNewChatOptions() {
    showModalBottomSheet(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(Icons.person),
              title: const Text('New Chat'),
              subtitle: const Text('Start a conversation with a contact'),
              onTap: () {
                Navigator.pop(sheetContext);
                context.push('/contacts');
              },
            ),
            ListTile(
              leading: const Icon(Icons.group_add),
              title: const Text('New Group'),
              subtitle: const Text('Create a group conversation'),
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

  String _formatTimestamp(String? timestamp) {
    if (timestamp == null || timestamp.isEmpty) return '';
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final diff = now.difference(dt);

      if (diff.inDays > 0) {
        if (diff.inDays == 1) return 'Yesterday';
        if (diff.inDays < 7) {
          const days = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
          return days[dt.weekday - 1];
        }
        return '${dt.day}/${dt.month}/${dt.year}';
      }

      final hour = dt.hour.toString().padLeft(2, '0');
      final minute = dt.minute.toString().padLeft(2, '0');
      return '$hour:$minute';
    } catch (_) {
      return '';
    }
  }

  @override
  Widget build(BuildContext context) {
    final conversationsState = ref.watch(conversationsProvider);
    final wsState = ref.watch(websocketProvider);
    final cryptoState = ref.watch(cryptoProvider);
    final authState = ref.watch(authProvider);
    final myUserId = authState.userId ?? '';
    final myUsername = authState.username ?? '';

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
            backgroundColor: Theme.of(context).colorScheme.error,
            duration: const Duration(seconds: 10),
          ),
        );
      }
    });

    return Scaffold(
      appBar: AppBar(
        title: Row(
          children: [
            const Text('Echo'),
            const SizedBox(width: 8),
            Icon(
              Icons.circle,
              size: 10,
              color: wsState.isConnected ? Colors.green : Colors.grey,
            ),
            const SizedBox(width: 4),
            Icon(
              cryptoState.isInitialized ? Icons.lock : Icons.lock_open,
              size: 14,
              color: cryptoState.isInitialized ? Colors.green : Colors.orange,
            ),
          ],
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.people),
            tooltip: 'Contacts',
            onPressed: () => context.push('/contacts'),
          ),
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_vert),
            tooltip: 'More',
            onSelected: (value) {
              switch (value) {
                case 'refresh':
                  ref.read(conversationsProvider.notifier).loadConversations();
                case 'logout':
                  _logout();
              }
            },
            itemBuilder: (context) => [
              if (myUsername.isNotEmpty)
                PopupMenuItem(
                  enabled: false,
                  child: Text(
                    myUsername,
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onSurface,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
              if (myUsername.isNotEmpty) const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'refresh',
                child: Row(
                  children: [
                    Icon(Icons.refresh, size: 20),
                    SizedBox(width: 8),
                    Text('Refresh'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'logout',
                child: Row(
                  children: [
                    Icon(Icons.logout, size: 20),
                    SizedBox(width: 8),
                    Text('Logout'),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
      body: conversationsState.isLoading &&
              conversationsState.conversations.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await ref
                    .read(conversationsProvider.notifier)
                    .loadConversations();
              },
              child: conversationsState.conversations.isEmpty
                  ? ListView(
                      children: const [
                        Padding(
                          padding: EdgeInsets.all(48),
                          child: Center(
                            child: Text(
                              'No conversations yet.\nTap + to start chatting.',
                              textAlign: TextAlign.center,
                              style: TextStyle(color: Colors.grey),
                            ),
                          ),
                        ),
                      ],
                    )
                  : ListView.builder(
                      itemCount: conversationsState.conversations.length,
                      itemBuilder: (context, index) {
                        final conv = conversationsState.conversations[index];
                        final displayName = conv.displayName(myUserId);
                        final initials = displayName.isNotEmpty
                            ? displayName[0].toUpperCase()
                            : '?';
                        final timeStr =
                            _formatTimestamp(conv.lastMessageTimestamp);

                        String? snippet = conv.lastMessage;
                        // Preview text is already handled by the provider
                        // (decrypted or replaced with placeholder)
                        if (snippet != null &&
                            conv.isGroup &&
                            conv.lastMessageSender != null) {
                          snippet =
                              '${conv.lastMessageSender}: $snippet';
                        }

                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: conv.isGroup
                                ? Theme.of(context).colorScheme.tertiary
                                : null,
                            child: conv.isGroup
                                ? const Icon(Icons.group, size: 20)
                                : Text(initials),
                          ),
                          title: Row(
                            children: [
                              Expanded(
                                child: Text(
                                  displayName,
                                  overflow: TextOverflow.ellipsis,
                                  style: conv.unreadCount > 0
                                      ? const TextStyle(
                                          fontWeight: FontWeight.bold)
                                      : null,
                                ),
                              ),
                              if (timeStr.isNotEmpty)
                                Text(
                                  timeStr,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: conv.unreadCount > 0
                                        ? Theme.of(context)
                                            .colorScheme
                                            .primary
                                        : Colors.grey,
                                  ),
                                ),
                            ],
                          ),
                          subtitle: snippet != null
                              ? Text(
                                  snippet,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: conv.unreadCount > 0
                                      ? const TextStyle(
                                          fontWeight: FontWeight.w500)
                                      : null,
                                )
                              : null,
                          trailing: conv.unreadCount > 0
                              ? Container(
                                  padding: const EdgeInsets.all(6),
                                  decoration: BoxDecoration(
                                    color:
                                        Theme.of(context).colorScheme.primary,
                                    shape: BoxShape.circle,
                                  ),
                                  child: Text(
                                    conv.unreadCount > 99
                                        ? '99+'
                                        : conv.unreadCount.toString(),
                                    style: TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Theme.of(context)
                                          .colorScheme
                                          .onPrimary,
                                    ),
                                  ),
                                )
                              : null,
                          onTap: () {
                            if (conv.isGroup) {
                              context.push(
                                '/chat-group/${conv.id}'
                                '?name=${Uri.encodeComponent(displayName)}',
                              );
                            } else {
                              // For 1:1 chats, find the peer user ID
                              final peer = conv.members
                                  .where((m) => m.userId != myUserId)
                                  .firstOrNull;
                              if (peer != null) {
                                context.push(
                                  '/chat/${peer.userId}'
                                  '?username=${Uri.encodeComponent(peer.username)}'
                                  '&conversationId=${conv.id}',
                                );
                              } else {
                                // Fallback: use group route
                                context.push(
                                  '/chat-group/${conv.id}'
                                  '?name=${Uri.encodeComponent(displayName)}',
                                );
                              }
                            }
                          },
                        );
                      },
                    ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showNewChatOptions,
        child: const Icon(Icons.add),
      ),
    );
  }
}
