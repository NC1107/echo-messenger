import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/contact.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../widgets/avatar_utils.dart' show buildAvatar, resolveAvatarUrl;

class CreateGroupScreen extends ConsumerStatefulWidget {
  const CreateGroupScreen({super.key});

  @override
  ConsumerState<CreateGroupScreen> createState() => _CreateGroupScreenState();
}

class _CreateGroupScreenState extends ConsumerState<CreateGroupScreen> {
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();
  final Set<String> _selectedUserIds = {};
  bool _isCreating = false;
  bool _isPublic = false;
  bool _isEncrypted = false;

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
    _descriptionController.dispose();
    super.dispose();
  }

  Future<void> _createGroup() async {
    final name = _nameController.text.trim();
    if (name.isEmpty) {
      ToastService.show(
        context,
        'Please enter a group name',
        type: ToastType.warning,
      );
      return;
    }
    setState(() => _isCreating = true);

    final description = _descriptionController.text.trim();

    final conversationId = await ref
        .read(conversationsProvider.notifier)
        .createGroup(
          name,
          _selectedUserIds.toList(),
          description: description.isNotEmpty ? description : null,
          isPublic: _isPublic,
          isEncrypted: _isEncrypted,
        );

    if (!mounted) return;
    setState(() => _isCreating = false);

    if (conversationId != null && conversationId.isNotEmpty) {
      ToastService.show(context, 'Group created', type: ToastType.success);
      if (Navigator.canPop(context)) {
        Navigator.pop(context);
      }
      context.go('/home?conversation=$conversationId');
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
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              _buildNameField(),
              _buildDescriptionField(),
              const SizedBox(height: 16),
              _buildVisibilityToggle(),
              const SizedBox(height: 16),
              _buildEncryptionToggle(),
              const SizedBox(height: 16),
              _buildMembersHeader(),
              const SizedBox(height: 8),
              Expanded(child: _buildContactsList(contactsState)),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildNameField() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: TextField(
        controller: _nameController,
        decoration: const InputDecoration(
          labelText: 'Group Name',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.group_outlined),
        ),
        textInputAction: TextInputAction.next,
      ),
    );
  }

  Widget _buildDescriptionField() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _descriptionController,
        decoration: const InputDecoration(
          labelText: 'Description (optional)',
          border: OutlineInputBorder(),
          prefixIcon: Icon(Icons.description_outlined),
        ),
        textInputAction: TextInputAction.done,
        maxLines: 2,
        minLines: 1,
      ),
    );
  }

  Widget _buildVisibilityToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Semantics(
            label: 'visibility toggle',
            child: SegmentedButton<bool>(
              segments: const [
                ButtonSegment<bool>(
                  value: false,
                  label: Text('Private'),
                  icon: Icon(Icons.lock_outline, size: 16),
                ),
                ButtonSegment<bool>(
                  value: true,
                  label: Text('Public'),
                  icon: Icon(Icons.public, size: 16),
                ),
              ],
              selected: {_isPublic},
              onSelectionChanged: (selection) {
                setState(() => _isPublic = selection.first);
              },
              style: SegmentedButton.styleFrom(
                selectedBackgroundColor: context.accentLight,
                selectedForegroundColor: context.accent,
              ),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            _isPublic
                ? 'Anyone can discover and join'
                : 'Only invited members can join',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  /// "End-to-end encryption (Experimental)" toggle. Defaults to off
  /// because the group-key envelope path has known stability issues
  /// under identity-key drift — a plaintext group is the safe default
  /// until the wedged-envelope recovery story stabilises.
  Widget _buildEncryptionToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Semantics(
        label: 'encryption toggle',
        child: SwitchListTile(
          value: _isEncrypted,
          onChanged: (v) => setState(() => _isEncrypted = v),
          contentPadding: EdgeInsets.zero,
          title: Row(
            children: [
              const Text('End-to-end encryption'),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: EchoTheme.warning.withValues(alpha: 0.18),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: const Text(
                  'Experimental',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w600,
                    color: EchoTheme.warning,
                    letterSpacing: 0.4,
                  ),
                ),
              ),
            ],
          ),
          subtitle: Text(
            _isEncrypted
                ? 'On (beta): end-to-end encrypted with a per-member group '
                      'key. No server-side search; new joiners may need a '
                      'key refresh.'
                : 'Off: server can read messages, supports search and '
                      'moderation. Your account auth still protects access.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          activeThumbColor: context.accent,
        ),
      ),
    );
  }

  Widget _buildMembersHeader() {
    return Padding(
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
    );
  }

  Widget _buildContactsList(ContactsState contactsState) {
    if (contactsState.isLoading && contactsState.contacts.isEmpty) {
      return const Center(child: CircularProgressIndicator());
    }
    if (contactsState.contacts.isEmpty) {
      return const Center(
        child: Text(
          'No contacts available.\nAdd contacts first.',
          textAlign: TextAlign.center,
          style: TextStyle(color: Colors.grey),
        ),
      );
    }
    return ListView.builder(
      itemCount: contactsState.contacts.length,
      itemBuilder: (context, index) {
        final contact = contactsState.contacts[index];
        final isSelected = _selectedUserIds.contains(contact.userId);
        return _buildContactTile(contact, isSelected);
      },
    );
  }

  Widget _buildContactTile(Contact contact, bool isSelected) {
    return Semantics(
      label: 'select contact ${contact.username}',
      selected: isSelected,
      button: true,
      child: CheckboxListTile(
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
        secondary: buildAvatar(
          name: contact.username,
          radius: 20,
          imageUrl: resolveAvatarUrl(
            contact.avatarUrl,
            ref.read(serverUrlProvider),
          ),
        ),
        title: Text(contact.displayName ?? contact.username),
        subtitle: contact.displayName != null
            ? Text('@${contact.username}')
            : null,
      ),
    );
  }
}
