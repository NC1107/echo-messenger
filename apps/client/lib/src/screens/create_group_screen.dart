import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final Set<String> _selectedUserIds = {};
  bool _isCreating = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(contactsProvider.notifier).loadContacts();
    });
  }

  @override
  void dispose() {
    _nameController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please enter a group name')),
      );
      return;
    }
    if (_selectedUserIds.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Please select at least one member')),
      );
      return;
    }

    setState(() => _isCreating = true);

    final conversationId = await ref
        .read(conversationsProvider.notifier)
        .createGroup(name, _selectedUserIds.toList());

    if (!mounted) return;
    setState(() => _isCreating = false);

    if (conversationId != null && conversationId.isNotEmpty) {
      // Navigate back to home (the new group will appear in the list)
      context.go('/home');
    }
  }

  @override
  Widget build(BuildContext context) {
    final contactsState = ref.watch(contactsProvider);

    return Scaffold(
      appBar: AppBar(
        title: const Text('Create Group'),
        actions: [
          TextButton(
            onPressed: _isCreating ? null : _createGroup,
            child: _isCreating
                ? const SizedBox(
                    height: 20,
                    width: 20,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Create'),
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _nameController,
              decoration: const InputDecoration(
                labelText: 'Group Name',
                border: OutlineInputBorder(),
                prefixIcon: Icon(Icons.group),
              ),
              textInputAction: TextInputAction.done,
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Text(
                  'Select Members',
                  style: Theme.of(context).textTheme.labelLarge?.copyWith(
                        color: Theme.of(context).colorScheme.primary,
                      ),
                ),
                const SizedBox(width: 8),
                if (_selectedUserIds.isNotEmpty)
                  Chip(
                    label: Text('${_selectedUserIds.length} selected'),
                    visualDensity: VisualDensity.compact,
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: contactsState.isLoading && contactsState.contacts.isEmpty
                ? const Center(child: CircularProgressIndicator())
                : contactsState.contacts.isEmpty
                    ? const Center(
                        child: Text(
                          'No contacts available.\nAdd contacts first.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey),
                        ),
                      )
                    : ListView.builder(
                        itemCount: contactsState.contacts.length,
                        itemBuilder: (context, index) {
                          final contact = contactsState.contacts[index];
                          final isSelected =
                              _selectedUserIds.contains(contact.userId);

                          return CheckboxListTile(
                            value: isSelected,
                            onChanged: (checked) {
                              setState(() {
                                if (checked == true) {
                                  _selectedUserIds.add(contact.userId);
                                } else {
                                  _selectedUserIds.remove(contact.userId);
                                }
                              });
                            },
                            secondary: CircleAvatar(
                              child:
                                  Text(contact.username[0].toUpperCase()),
                            ),
                            title: Text(
                                contact.displayName ?? contact.username),
                            subtitle: contact.displayName != null
                                ? Text('@${contact.username}')
                                : null,
                          );
                        },
                      ),
          ),
        ],
      ),
    );
  }
}
