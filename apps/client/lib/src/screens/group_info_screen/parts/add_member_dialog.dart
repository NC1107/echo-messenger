// ignore_for_file: invalid_use_of_protected_member

part of '../../group_info_screen.dart';

/// Add-member flow: fuzzy-filtered contact picker dialog + server submit,
/// invoked from the `_addMember` entrypoint on the members section header.
extension _AddMemberDialog on _GroupInfoScreenState {
  /// Filters available contacts by fuzzy-search query.
  List<Contact> _filterAvailableContacts(
    List<Contact> available,
    String query,
  ) {
    if (query.isEmpty) return available;
    final scored = <({Contact contact, double score})>[];
    for (final c in available) {
      final nameScore = fuzzyScore(query, c.displayName ?? c.username);
      final handleScore = fuzzyScore(query, c.username);
      final best = nameScore > handleScore ? nameScore : handleScore;
      if (best > 0.2) scored.add((contact: c, score: best));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => e.contact).toList();
  }

  /// Builds a dialog for member selection with search functionality.
  Future<String?> _showAddMemberDialog(List<Contact> available) {
    final searchController = TextEditingController();
    return showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (ctx, setDialogState) {
            final query = searchController.text.trim();
            final filtered = _filterAvailableContacts(available, query);
            final serverUrl = ref.read(serverUrlProvider);
            return Dialog(
              backgroundColor: context.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: context.border),
              ),
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 480),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    // Title and close button
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Text(
                            'Add Member',
                            style: TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                              color: context.textPrimary,
                            ),
                          ),
                          SizedBox(
                            width: 44,
                            height: 44,
                            child: IconButton(
                              onPressed: () => Navigator.of(ctx).pop(),
                              icon: Icon(
                                Icons.close,
                                size: 20,
                                color: context.textSecondary,
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    // Search field
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: TextField(
                        controller: searchController,
                        autofocus: true,
                        decoration: InputDecoration(
                          hintText: 'Search contacts...',
                          hintStyle: TextStyle(color: context.textSecondary),
                          prefixIcon: Icon(
                            Icons.search,
                            size: 18,
                            color: context.textSecondary,
                          ),
                          isDense: true,
                          contentPadding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 10,
                          ),
                          filled: true,
                          fillColor: context.surface,
                          enabledBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: context.border),
                          ),
                          focusedBorder: OutlineInputBorder(
                            borderRadius: BorderRadius.circular(8),
                            borderSide: BorderSide(color: context.accent),
                          ),
                        ),
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 14,
                        ),
                        onChanged: (_) => setDialogState(() {}),
                      ),
                    ),
                    const SizedBox(height: 8),
                    Divider(height: 8, color: context.border),
                    // Contact list
                    Expanded(
                      child: filtered.isEmpty
                          ? Center(
                              child: Text(
                                'No contacts found',
                                style: TextStyle(color: context.textMuted),
                              ),
                            )
                          : ListView.builder(
                              shrinkWrap: true,
                              itemCount: filtered.length,
                              itemBuilder: (listCtx, idx) {
                                final contact = filtered[idx];
                                return SizedBox(
                                  height: 56,
                                  child: InkWell(
                                    onTap: () => Navigator.pop(
                                      dialogContext,
                                      contact.userId,
                                    ),
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 16,
                                        vertical: 8,
                                      ),
                                      child: Row(
                                        children: [
                                          buildAvatar(
                                            name: contact.username,
                                            radius: 20,
                                            imageUrl: resolveAvatarUrl(
                                              contact.avatarUrl,
                                              serverUrl,
                                            ),
                                          ),
                                          const SizedBox(width: 12),
                                          Expanded(
                                            child: Text(
                                              contact.displayName ??
                                                  contact.username,
                                              style: TextStyle(
                                                fontSize: 14,
                                                color: context.textPrimary,
                                              ),
                                              maxLines: 1,
                                              overflow: TextOverflow.ellipsis,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            );
          },
        );
      },
    );
  }

  /// Sends the add-member request to the server.
  Future<void> _submitAddMember(String userId) async {
    final token = ref.read(authProvider).token;
    if (token == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}/members'),
        headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
        body: jsonEncode({'user_id': userId}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        await _loadGroupInfo(force: true);
        if (mounted) {
          ToastService.show(context, 'Member added', type: ToastType.success);
        }
      }
    } catch (e) {
      debugPrint('[GroupInfo] _submitAddMember failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to add member',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _addMember() async {
    // Load contacts for selection
    await ref.read(contactsProvider.notifier).loadContacts();
    if (!mounted) return;

    final contacts = ref.read(contactsProvider).contacts;
    final existingMemberIds =
        _conversation?.members.map((m) => m.userId).toSet() ?? {};
    final available = contacts
        .where((c) => !existingMemberIds.contains(c.userId))
        .toList();

    if (available.isEmpty) {
      ToastService.show(
        context,
        'All contacts are already in this group',
        type: ToastType.info,
      );
      return;
    }

    final selected = await _showAddMemberDialog(available);
    if (selected == null) return;

    await _submitAddMember(selected);
  }
}
