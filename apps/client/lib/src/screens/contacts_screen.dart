import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/websocket_provider.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  const ContactsScreen({super.key});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
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

    final contactsNotifier = ref.read(contactsProvider.notifier);
    contactsNotifier.loadContacts();
    contactsNotifier.loadPending();

    final isConnected = ref.read(websocketProvider);
    if (!isConnected) {
      ref.read(websocketProvider.notifier).connect();
    }
  }

  void _logout() {
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    ref.read(authProvider.notifier).logout();
  }

  void _showAddContactDialog() {
    final controller = TextEditingController();
    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Add Contact'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'Username',
            border: OutlineInputBorder(),
          ),
          onSubmitted: (value) {
            final username = value.trim();
            if (username.isNotEmpty) {
              ref.read(contactsProvider.notifier).sendRequest(username);
              Navigator.pop(dialogContext);
            }
          },
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              final username = controller.text.trim();
              if (username.isNotEmpty) {
                ref.read(contactsProvider.notifier).sendRequest(username);
                Navigator.pop(dialogContext);
              }
            },
            child: const Text('Add'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final contactsState = ref.watch(contactsProvider);
    final isWsConnected = ref.watch(websocketProvider);
    final cryptoState = ref.watch(cryptoProvider);

    ref.listen<ContactsState>(contactsProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(next.error!)),
        );
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
              color: isWsConnected ? Colors.green : Colors.grey,
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
            icon: const Icon(Icons.refresh),
            tooltip: 'Refresh',
            onPressed: () {
              ref.read(contactsProvider.notifier).loadContacts();
              ref.read(contactsProvider.notifier).loadPending();
            },
          ),
          IconButton(
            icon: const Icon(Icons.logout),
            tooltip: 'Logout',
            onPressed: _logout,
          ),
        ],
      ),
      body: contactsState.isLoading &&
              contactsState.contacts.isEmpty &&
              contactsState.pendingRequests.isEmpty
          ? const Center(child: CircularProgressIndicator())
          : RefreshIndicator(
              onRefresh: () async {
                await ref.read(contactsProvider.notifier).loadContacts();
                await ref.read(contactsProvider.notifier).loadPending();
              },
              child: ListView(
                padding: const EdgeInsets.symmetric(vertical: 8),
                children: [
                  if (contactsState.pendingRequests.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        'Pending Requests',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                    ...contactsState.pendingRequests.map(
                      (contact) => ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            contact.username[0].toUpperCase(),
                          ),
                        ),
                        title: Text(contact.username),
                        subtitle: const Text('Wants to connect'),
                        trailing: FilledButton.tonal(
                          onPressed: () {
                            ref
                                .read(contactsProvider.notifier)
                                .acceptRequest(contact.id);
                          },
                          child: const Text('Accept'),
                        ),
                      ),
                    ),
                    const Divider(indent: 16, endIndent: 16),
                  ],
                  if (contactsState.contacts.isNotEmpty) ...[
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                      child: Text(
                        'Contacts',
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                              color: Theme.of(context).colorScheme.primary,
                            ),
                      ),
                    ),
                    ...contactsState.contacts.map(
                      (contact) => ListTile(
                        leading: CircleAvatar(
                          child: Text(
                            contact.username[0].toUpperCase(),
                          ),
                        ),
                        title: Text(contact.displayName ?? contact.username),
                        subtitle: contact.displayName != null
                            ? Text('@${contact.username}')
                            : null,
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () {
                          context.push(
                            '/chat/${contact.userId}?username=${Uri.encodeComponent(contact.username)}',
                          );
                        },
                      ),
                    ),
                  ],
                  if (contactsState.contacts.isEmpty &&
                      contactsState.pendingRequests.isEmpty)
                    const Padding(
                      padding: EdgeInsets.all(48),
                      child: Center(
                        child: Text(
                          'No contacts yet.\nTap + to add someone.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      ),
                    ),
                ],
              ),
            ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddContactDialog,
        child: const Icon(Icons.person_add),
      ),
    );
  }
}
