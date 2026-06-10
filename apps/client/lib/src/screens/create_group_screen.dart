import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../models/contact.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../services/upload_client.dart';
import '../theme/echo_theme.dart';
import '../widgets/avatar_crop_dialog.dart';
import '../widgets/avatar_utils.dart' show buildAvatar, resolveAvatarUrl;
import '../widgets/empty_state.dart';
import '../widgets/loading_indicator.dart';

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
  // #1131: default new groups to encrypted now that bootstrap-retry is
  // event-driven — peers no longer wait out a 5-minute TTL on the first
  // send to a brand-new invitee.
  bool _isEncrypted = true;
  Uint8List? _pickedAvatarBytes;

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

    final String conversationId;
    try {
      conversationId = await ref
          .read(conversationsProvider.notifier)
          .createGroup(
            name,
            _selectedUserIds.toList(),
            description: description.isNotEmpty ? description : null,
            isPublic: _isPublic,
            isEncrypted: _isEncrypted,
          );
    } on GroupException catch (e) {
      if (!mounted) return;
      setState(() => _isCreating = false);
      ToastService.show(context, e.message, type: ToastType.error);
      return;
    }

    // Upload the picked avatar (if any) before navigating so the user
    // lands on a chat that already shows their chosen icon.  Failures
    // here are non-fatal — the toast inside the helper explains and the
    // user can re-pick from Group Info.
    if (_pickedAvatarBytes != null) {
      await _uploadGroupAvatarAfterCreate(conversationId);
    }

    if (!mounted) return;
    setState(() => _isCreating = false);

    ToastService.show(context, 'Group created', type: ToastType.success);
    if (Navigator.canPop(context)) {
      Navigator.pop(context);
    }
    context.go('/home?conversation=$conversationId');
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
          // Inner SingleChildScrollView so the avatar picker + form fields
          // don't overflow on short viewports (phone landscape, dialog
          // wrappers); the members list keeps its own Expanded inside so
          // it still consumes the remaining space cleanly.
          child: LayoutBuilder(
            builder: (context, constraints) {
              return SingleChildScrollView(
                child: ConstrainedBox(
                  constraints: BoxConstraints(minHeight: constraints.maxHeight),
                  child: IntrinsicHeight(
                    child: Column(
                      children: [
                        const SizedBox(height: 16),
                        _buildAvatarPicker(),
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
            },
          ),
        ),
      ),
    );
  }

  Widget _buildAvatarPicker() {
    return Semantics(
      label: 'pick group avatar',
      button: true,
      child: GestureDetector(
        onTap: _isCreating ? null : _pickGroupAvatar,
        child: Center(
          child: Stack(
            children: [
              Container(
                width: 96,
                height: 96,
                padding: const EdgeInsets.all(3),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  border: Border.all(color: context.accent, width: 2),
                ),
                child: CircleAvatar(
                  radius: 44,
                  backgroundColor: context.surface,
                  backgroundImage: _pickedAvatarBytes != null
                      ? MemoryImage(_pickedAvatarBytes!)
                      : null,
                  child: _pickedAvatarBytes == null
                      ? Icon(
                          Icons.groups_outlined,
                          size: 36,
                          color: context.textMuted,
                        )
                      : null,
                ),
              ),
              Positioned(
                bottom: 0,
                right: 0,
                child: CircleAvatar(
                  radius: 14,
                  backgroundColor: context.accent,
                  child: Icon(
                    Icons.camera_alt,
                    size: 14,
                    color: context.surface,
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _pickGroupAvatar() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;
    final file = result.files.first;
    if (file.bytes == null) return;
    if (!mounted) return;
    final cropped = await showAvatarCropDialog(context, file.bytes!);
    if (cropped == null) return;
    if (!mounted) return;
    setState(() => _pickedAvatarBytes = cropped);
  }

  /// PUT the picked avatar bytes to `/api/groups/<id>/avatar` right after
  /// the group is created. Best-effort: a failure here surfaces a toast
  /// but does NOT block navigation into the new group — the user can
  /// re-upload from Group Info if it didn't take.
  Future<void> _uploadGroupAvatarAfterCreate(String groupId) async {
    final bytes = _pickedAvatarBytes;
    if (bytes == null) return;
    try {
      final uploader = UploadClient(ref.read(authProvider.notifier));
      final result = await uploader.uploadFile(
        serverUrl: ref.read(serverUrlProvider),
        path: '/api/groups/$groupId/avatar',
        bytes: bytes,
        fileName: 'avatar.jpg',
        mimeType: 'image/jpeg',
        method: 'PUT',
        fieldName: 'avatar',
      );
      if (!mounted) return;
      if (!result.ok) {
        ToastService.show(
          context,
          result.errorMessage ??
              'Avatar upload failed (${result.statusCode}). '
                  'You can retry from Group Info.',
          type: ToastType.warning,
        );
      }
    } catch (e) {
      debugPrint('[CreateGroup] avatar upload failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Avatar upload failed. You can retry from Group Info.',
          type: ToastType.warning,
        );
      }
    }
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
    // Aligned with the E2E encryption SwitchListTile below so the two
    // toggles read as one consistent block. `value` here is "is private?"
    // (the inverse of the underlying `_isPublic`) so the affordance reads
    // as a positive privacy choice rather than a hidden public flip.
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Semantics(
        label: 'private group toggle',
        child: SwitchListTile(
          value: !_isPublic,
          onChanged: (private) => setState(() => _isPublic = !private),
          contentPadding: EdgeInsets.zero,
          title: const Text('Private group'),
          subtitle: Text(
            _isPublic
                ? 'Off: anyone can discover and join.'
                : 'On: only invited members can join.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          activeThumbColor: context.accent,
        ),
      ),
    );
  }

  /// End-to-end encryption toggle. Default is ON now that the
  /// event-driven bootstrap retry (#1131) clears the brand-new-invitee
  /// "waiting for keys" failure within seconds of their first login —
  /// no more 5-minute TTL wait on the sender's side.
  Widget _buildEncryptionToggle() {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Semantics(
        label: 'encryption toggle',
        child: SwitchListTile(
          value: _isEncrypted,
          onChanged: (v) => setState(() => _isEncrypted = v),
          contentPadding: EdgeInsets.zero,
          title: const Text('End-to-end encryption'),
          subtitle: Text(
            _isEncrypted
                ? 'On: end-to-end encrypted; no server-side search.'
                : 'Off: server can read messages and run search/moderation.',
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
      return const CenteredLoadingIndicator();
    }
    if (contactsState.contacts.isEmpty) {
      return const EmptyState(
        icon: Icons.person_outline,
        title: 'No contacts available.',
        body: 'Add contacts first.',
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
