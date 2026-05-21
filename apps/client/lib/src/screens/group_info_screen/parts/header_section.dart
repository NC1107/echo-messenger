// `setState` is `@protected` on `State`, so extensions trip
// `invalid_use_of_protected_member`. These parts are in the same library as
// the parent `_GroupInfoScreenState` (via `part of`) so the access is safe.
// ignore_for_file: invalid_use_of_protected_member

part of '../../group_info_screen.dart';

/// Header section: group avatar (with upload affordance), editable group name,
/// member count line (with optional E2EE pill), and description editor.
extension _HeaderSection on _GroupInfoScreenState {
  Future<void> _saveGroupName() async {
    final newTitle = _nameController.text.trim();
    if (newTitle.isEmpty) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await http.put(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}'),
        headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
        body: jsonEncode({'title': newTitle}),
      );
      if ((response.statusCode == 200) && mounted) {
        setState(() => _isEditingName = false);
        await _loadGroupInfo();
        await ref.read(conversationsProvider.notifier).loadConversations();
      }
    } catch (e) {
      debugPrint('[GroupInfo] _saveGroupName failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to update group name',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _saveDescription() async {
    final newDesc = _descriptionController.text.trim();

    final token = ref.read(authProvider).token;
    if (token == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await http.put(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}'),
        headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
        body: jsonEncode({'description': newDesc}),
      );
      if ((response.statusCode == 200) && mounted) {
        setState(() => _isEditingDescription = false);
        // Re-fetch conversations from server (which now includes description)
        // and re-sync our local _conversation field from the refreshed
        // provider state — without this, the screen kept rendering the
        // pre-save Conversation object even though the DB was up to date.
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (!mounted) return;
        final refreshed = ref
            .read(conversationsProvider)
            .conversations
            .where((c) => c.id == widget.conversationId)
            .firstOrNull;
        if (refreshed != null) {
          setState(() => _conversation = refreshed);
        }
      }
    } catch (e) {
      debugPrint('[GroupInfo] _saveDescription failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to update description',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _uploadGroupAvatar() async {
    final result = await FilePicker.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    // Show the crop dialog; fall through with original bytes if cancelled.
    final croppedBytes = mounted
        ? await showAvatarCropDialog(context, file.bytes!)
        : null;
    if (croppedBytes == null) return; // user cancelled

    final serverUrl = ref.read(serverUrlProvider);

    try {
      final uploader = UploadClient(ref.read(authProvider.notifier));
      final result = await uploader.uploadFile(
        serverUrl: serverUrl,
        path: '/api/groups/${widget.conversationId}/avatar',
        bytes: croppedBytes,
        fileName: 'avatar.jpg',
        mimeType: 'image/jpeg',
        method: 'PUT',
        fieldName: 'avatar',
      );
      if (!mounted) return;

      if (result.ok) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        await _loadGroupInfo(force: true);
        if (mounted) {
          ToastService.show(
            context,
            'Group avatar updated',
            type: ToastType.success,
          );
        }
      } else {
        ToastService.show(
          context,
          result.errorMessage ??
              'Failed to upload avatar (${result.statusCode})',
          type: ToastType.error,
        );
      }
    } catch (e) {
      debugPrint('[GroupInfo] _uploadGroupAvatar failed: $e');
      if (mounted) {
        ToastService.show(context, 'Upload error: $e', type: ToastType.error);
      }
    }
  }

  Widget _buildGroupAvatar({required bool isOwnerOrAdmin, String? iconUrl}) {
    final serverUrl = ref.read(serverUrlProvider);
    final ticket = ref.read(mediaTicketProvider);
    final hasIcon = iconUrl != null && iconUrl.isNotEmpty;

    Widget avatar;
    if (hasIcon) {
      final fullUrl = ticket != null && ticket.isNotEmpty
          ? '$serverUrl$iconUrl?ticket=$ticket'
          : '$serverUrl$iconUrl';
      avatar = CircleAvatar(
        radius: 56,
        backgroundColor: Theme.of(context).colorScheme.tertiary,
        backgroundImage: NetworkImage(fullUrl),
        onBackgroundImageError: (_, _) {},
        child: null,
      );
    } else {
      avatar = CircleAvatar(
        radius: 56,
        backgroundColor: Theme.of(context).colorScheme.tertiary,
        child: const Icon(Icons.group_outlined, size: 40),
      );
    }

    return Center(
      child: GestureDetector(
        onTap: isOwnerOrAdmin ? _uploadGroupAvatar : null,
        child: Stack(
          children: [
            avatar,
            if (isOwnerOrAdmin)
              Positioned(
                bottom: 0,
                right: 0,
                child: Container(
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primary,
                    shape: BoxShape.circle,
                  ),
                  child: Icon(
                    Icons.camera_alt_outlined,
                    size: 16,
                    color: Theme.of(context).colorScheme.onPrimary,
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildGroupNameSection({
    required String displayName,
    required bool isOwnerOrAdmin,
  }) {
    if (_isEditingName) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 48),
        child: Row(
          children: [
            Expanded(
              child: TextField(
                controller: _nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  hintText: 'Group name',
                  isDense: true,
                ),
                onSubmitted: (_) => _saveGroupName(),
              ),
            ),
            IconButton(
              icon: const Icon(Icons.check),
              tooltip: 'Save group name',
              onPressed: _saveGroupName,
            ),
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: 'Cancel editing',
              onPressed: () => setState(() => _isEditingName = false),
            ),
          ],
        ),
      );
    }
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(displayName, style: Theme.of(context).textTheme.headlineSmall),
          if (isOwnerOrAdmin)
            IconButton(
              icon: const Icon(Icons.edit_outlined, size: 18),
              tooltip: 'Edit group name',
              onPressed: () {
                _nameController.text = displayName;
                setState(() => _isEditingName = true);
              },
            ),
        ],
      ),
    );
  }

  Widget _buildMemberCount(int count) {
    final isEncrypted = _conversation?.isEncrypted ?? false;
    final memberLabel = '$count member${count == 1 ? '' : 's'}';
    return Center(
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (isEncrypted) ...[
            Icon(Icons.lock, size: 12, color: context.textMuted),
            const SizedBox(width: 6),
            Text(
              'End-to-end encrypted · $memberLabel',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            const SizedBox(width: 8),
            // Group E2EE is wired but session-key distribution can stall
            // ("Securing message…", #434).  Label it so testers don't file
            // duplicates -- remove once #591 lands server-side enforcement.
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: context.accentLight,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: context.accent, width: 0.5),
              ),
              child: Text(
                'Experimental',
                style: TextStyle(
                  color: context.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
          ] else
            Text(
              memberLabel,
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
        ],
      ),
    );
  }

  Widget _buildDescriptionSection({
    required Conversation conv,
    required bool isOwnerOrAdmin,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Row(
            children: [
              Text(
                'Description',
                style: Theme.of(context).textTheme.labelLarge?.copyWith(
                  color: Theme.of(context).colorScheme.primary,
                ),
              ),
              const Spacer(),
              if (isOwnerOrAdmin && !_isEditingDescription)
                IconButton(
                  icon: const Icon(Icons.edit_outlined, size: 18),
                  tooltip: 'Edit description',
                  onPressed: () {
                    _descriptionController.text = conv.description ?? '';
                    setState(() => _isEditingDescription = true);
                  },
                ),
            ],
          ),
        ),
        if (_isEditingDescription)
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _descriptionController,
                    autofocus: true,
                    decoration: const InputDecoration(
                      hintText: 'Group description',
                      isDense: true,
                    ),
                    onSubmitted: (_) => _saveDescription(),
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.check),
                  tooltip: 'Save description',
                  onPressed: _saveDescription,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
                  tooltip: 'Cancel editing',
                  onPressed: () =>
                      setState(() => _isEditingDescription = false),
                ),
              ],
            ),
          )
        else
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Text(
              conv.description?.isNotEmpty == true
                  ? conv.description!
                  : 'No description',
              style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                color: conv.description?.isNotEmpty == true
                    ? Theme.of(context).colorScheme.onSurface
                    : Theme.of(context).colorScheme.onSurfaceVariant,
              ),
            ),
          ),
      ],
    );
  }
}
