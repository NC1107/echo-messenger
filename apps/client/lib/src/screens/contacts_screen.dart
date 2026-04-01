import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/contacts_provider.dart';

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
      appBar: AppBar(
        title: const Text('Contacts'),
      ),
      body:
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
                        style: Theme.of(context).textTheme.labelLarge?.copyWith(
                          color: Theme.of(context).colorScheme.primary,
                        ),
                      ),
                    ),
                    ...contactsState.pendingRequests.map(
                      (contact) => ListTile(
                        leading: CircleAvatar(
                          child: Text(contact.username[0].toUpperCase()),
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
                          child: Text(contact.username[0].toUpperCase()),
                        ),
                        title: Text(contact.displayName ?? contact.username),
                        subtitle: contact.displayName != null
                            ? Text('@${contact.username}')
                            : null,
                        trailing: const Icon(Icons.chevron_right_outlined),
                        onTap: () {
                          // Navigate back to home -- the user can select the conversation there
                          context.go('/home');
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
        child: const Icon(Icons.person_add_outlined),
      ),
    );
  }
}
