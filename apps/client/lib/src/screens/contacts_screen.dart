import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/conversation.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/conversation_panel.dart' show buildAvatar;
import 'user_profile_screen.dart';

class ContactsScreen extends ConsumerStatefulWidget {
  /// When provided, tapping "Message" on a contact will call this callback
  /// instead of navigating away. Used when ContactsScreen is shown in a dialog.
  final void Function(Conversation)? onStartConversation;

  const ContactsScreen({super.key, this.onStartConversation});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  bool _isStartingDm = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(contactsProvider.notifier).loadContacts();
      ref.read(contactsProvider.notifier).loadPending();
    });
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

  Future<void> _messageContact(String userId, String username) async {
    if (_isStartingDm) return;
    setState(() => _isStartingDm = true);

    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(userId, username);

      if (!mounted) return;

      if (conv != null) {
        if (widget.onStartConversation != null) {
          widget.onStartConversation!(conv);
        } else {
          context.go('/home');
        }
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Could not start conversation')),
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isStartingDm = false);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final contactsState = ref.watch(contactsProvider);

    ref.listen<ContactsState>(contactsProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(next.error!)));
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child:
              contactsState.isLoading &&
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
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ),
                        ...contactsState.pendingRequests.map((contact) {
                          final serverUrl = ref.watch(serverUrlProvider);
                          return ListTile(
                            leading: buildAvatar(
                              name: contact.username,
                              radius: 20,
                              imageUrl: contact.avatarUrl != null
                                  ? '$serverUrl${contact.avatarUrl}'
                                  : null,
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
                          );
                        }),
                        const Divider(indent: 16, endIndent: 16),
                      ],
                      if (contactsState.contacts.isNotEmpty) ...[
                        Padding(
                          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                          child: Text(
                            'Contacts',
                            style: Theme.of(context).textTheme.labelLarge
                                ?.copyWith(
                                  color: Theme.of(context).colorScheme.primary,
                                ),
                          ),
                        ),
                        ...contactsState.contacts.map((contact) {
                          final serverUrl = ref.watch(serverUrlProvider);
                          return ListTile(
                            leading: buildAvatar(
                              name: contact.username,
                              radius: 20,
                              imageUrl: contact.avatarUrl != null
                                  ? '$serverUrl${contact.avatarUrl}'
                                  : null,
                            ),
                            title: GestureDetector(
                              onTap: () => UserProfileScreen.show(
                                context,
                                ref,
                                contact.userId,
                              ),
                              child: Text(
                                contact.displayName ?? contact.username,
                              ),
                            ),
                            subtitle: contact.displayName != null
                                ? Text('@${contact.username}')
                                : null,
                            trailing: SizedBox(
                              height: 32,
                              width: 90,
                              child: Material(
                                color: context.accentLight,
                                borderRadius: BorderRadius.circular(6),
                                child: InkWell(
                                  borderRadius: BorderRadius.circular(6),
                                  onTap: _isStartingDm
                                      ? null
                                      : () => _messageContact(
                                          contact.userId,
                                          contact.username,
                                        ),
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 12,
                                    ),
                                    child: Center(
                                      child: Text(
                                        'Message',
                                        style: TextStyle(
                                          color: context.accent,
                                          fontSize: 13,
                                          fontWeight: FontWeight.w500,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          );
                        }),
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
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: _showAddContactDialog,
        child: const Icon(Icons.person_add_outlined),
      ),
    );
  }
}
