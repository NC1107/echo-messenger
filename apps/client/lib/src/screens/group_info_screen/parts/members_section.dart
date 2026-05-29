// ignore_for_file: invalid_use_of_protected_member

part of '../../group_info_screen.dart';

/// Member roster: grouped sections (Owner / Admin / Members), per-row context
/// menu wiring (right-click, long-press, "..." button), DM open, unblock,
/// kick, ban.
extension _MembersSection on _GroupInfoScreenState {
  Future<void> _kickMember(ConversationMember member) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Remove Member',
      content: 'Remove ${member.username} from this group?',
      confirmLabel: 'Remove',
      destructive: true,
    );
    if (!confirmed) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await http.delete(
        Uri.parse(
          '$serverUrl/api/groups/${widget.conversationId}'
          '/members/${member.userId}',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200 && mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        await _loadGroupInfo(force: true);
        if (mounted) {
          ToastService.show(
            context,
            '${member.username} removed',
            type: ToastType.success,
          );
        }
      }
    } catch (e) {
      debugPrint('[GroupInfo] _kickMember failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to remove member',
          type: ToastType.error,
        );
      }
    }
  }

  /// Promote a member to admin or demote an admin back to member.
  ///
  /// Only the owner may call this; the server enforces the same rule.
  /// Optimistic update: role flipped locally immediately and rolled back on
  /// failure so the UI stays responsive on slow connections.
  Future<void> _changeRole(ConversationMember member) async {
    final currentRole = member.role ?? 'member';
    final isPromoting = currentRole != 'admin';
    final newRole = isPromoting ? 'admin' : 'member';
    final actionLabel = isPromoting ? 'Make admin' : 'Remove admin';

    final confirmed = await showEchoConfirmDialog(
      context,
      title: actionLabel,
      content: isPromoting
          ? 'Make ${member.username} an admin of this group?'
          : 'Remove admin from ${member.username}?',
      confirmLabel: actionLabel,
      destructive: false,
    );
    if (!confirmed) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await http.patch(
        Uri.parse(
          '$serverUrl/api/groups/${widget.conversationId}'
          '/members/${member.userId}/role',
        ),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: '{"role":"$newRole"}',
      );
      if (response.statusCode == 200 && mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        await _loadGroupInfo(force: true);
        if (mounted) {
          ToastService.show(
            context,
            isPromoting
                ? '${member.username} is now an admin'
                : '${member.username} is no longer an admin',
            type: ToastType.success,
          );
        }
      } else if (mounted) {
        ToastService.show(
          context,
          'Failed to change role (${response.statusCode})',
          type: ToastType.error,
        );
      }
    } catch (e) {
      debugPrint('[GroupInfo] _changeRole failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to change role',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _banMember(ConversationMember member) async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Ban Member',
      content:
          'Ban ${member.username} from this group? '
          'They will not be able to rejoin.',
      confirmLabel: 'Ban',
      destructive: true,
    );
    if (!confirmed) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await http.post(
        Uri.parse(
          '$serverUrl/api/groups/${widget.conversationId}'
          '/ban/${member.userId}',
        ),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200 && mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        await _loadGroupInfo(force: true);
        if (mounted) {
          ToastService.show(
            context,
            '${member.username} banned',
            type: ToastType.success,
          );
        }
      }
    } catch (e) {
      debugPrint('[GroupInfo] _banMember failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to ban member',
          type: ToastType.error,
        );
      }
    }
  }

  /// Trailing "..." affordance on a member row. Routes through
  /// [EchoContextMenu] so the menu items match right-click and
  /// long-press paths exactly. Hidden when the menu would be empty
  /// (target is self with no admin actions on offer).
  Widget? _buildMemberActions({
    required ConversationMember member,
    required bool isOwnerOrAdmin,
    required bool viewerIsOwner,
    required bool isMe,
    required String role,
  }) {
    if (isMe) return null;
    return Builder(
      builder: (btnContext) => IconButton(
        icon: Icon(
          Icons.more_vert,
          size: 18,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
        tooltip: 'Member actions',
        onPressed: () {
          final box = btnContext.findRenderObject() as RenderBox?;
          final origin =
              box?.localToGlobal(Offset(0, box.size.height)) ?? Offset.zero;
          _openMemberContextMenu(
            anchor: origin,
            member: member,
            role: role,
            viewerIsAdminOrOwner: isOwnerOrAdmin,
            viewerIsOwner: viewerIsOwner,
            isMe: isMe,
          );
        },
      ),
    );
  }

  /// Build a [MemberTarget] for [member] and open the centralised
  /// context menu at [anchor]. Used by all three triggers
  /// (right-click on row, long-press on row, "..." button).
  ///
  /// PR-4 scope is migration only: Add/Remove Contact + Block stay
  /// off until contacts_provider grows the matching methods. Unblock
  /// already exists, so it's wired conditionally on the live
  /// blocked-users list.
  void _openMemberContextMenu({
    required Offset anchor,
    required ConversationMember member,
    required String role,
    required bool viewerIsAdminOrOwner,
    required bool viewerIsOwner,
    required bool isMe,
  }) {
    final isBlocked = _isMemberBlocked(member.userId);
    final canModerate = viewerIsAdminOrOwner && !isMe && role != 'owner';
    // Only the owner can promote/demote; never for self or the owner target.
    final canChangeRole = viewerIsOwner && !isMe && role != 'owner';
    final targetIsAdmin = role == 'admin';

    final target = MemberTarget(
      userId: member.userId,
      username: member.username,
      isSelf: isMe,
      targetIsOwner: role == 'owner',
      viewerIsAdminOrOwner: viewerIsAdminOrOwner,
      viewerIsOwner: viewerIsOwner,
      targetIsAdmin: targetIsAdmin,
      onViewProfile: () => showUserProfileSheet(context, ref, member.userId),
      onSendMessage: isMe ? null : () => _openDmWithMember(member),
      onUnblock: (isMe || !isBlocked)
          ? null
          : () => _unblockMember(member.userId),
      onCopyUsername: () =>
          _copyToClipboardWithToast(member.username, 'Username copied'),
      onCopyUserId: () =>
          _copyToClipboardWithToast(member.userId, 'User ID copied'),
      onKick: canModerate ? () => _kickMember(member) : null,
      onBan: canModerate ? () => _banMember(member) : null,
      onChangeRole: canChangeRole ? () => _changeRole(member) : null,
    );

    EchoContextMenu.open(
      context: context,
      target: target,
      anchor: anchor,
      model: buildMemberMenu(target),
    );
  }

  bool _isMemberBlocked(String userId) {
    return ref
        .read(contactsProvider)
        .blockedUsers
        .any((u) => u.blockedId == userId);
  }

  Future<void> _openDmWithMember(ConversationMember member) async {
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(member.userId, member.username);
      if (!mounted) return;
      context.go('/home?conversation=${conv.id}');
    } catch (_) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Failed to open conversation',
        type: ToastType.error,
      );
    }
  }

  Future<void> _unblockMember(String userId) async {
    await ref.read(contactsProvider.notifier).unblockUser(userId);
  }

  void _copyToClipboardWithToast(String text, String successMessage) {
    copyToClipboard(context, text, successMessage: successMessage);
  }

  /// Single roster row. Matches the desktop members panel styling (#769):
  /// avatar -> online dot -> role icon + username + role pill, activity line
  /// underneath ("online" / "away" / "You").
  Widget _buildMemberTile({
    required ConversationMember member,
    required String myUserId,
    required bool isOwnerOrAdmin,
    required bool viewerIsOwner,
  }) {
    final isMe = member.userId == myUserId;
    final role = member.role ?? 'member';
    // "You" trumps the presence label on the row that represents the
    // viewer themselves; everyone else gets the standard activity line.
    final String activity;
    if (isMe) {
      activity = 'You';
    } else {
      final presence = ref.watch(userPresenceProvider(member.userId));
      activity = presenceLabel(presence.status, isOnline: presence.isOnline);
    }

    return InkWell(
      onTap: () {
        // Tapping a row opens the member's profile sheet, matching the
        // desktop members panel.
        // Avoid for self -- you can already see your own settings.
        if (!isMe) {
          showUserProfileSheet(context, ref, member.userId);
        }
      },
      onSecondaryTapDown: (details) => _openMemberContextMenu(
        anchor: details.globalPosition,
        member: member,
        role: role,
        viewerIsAdminOrOwner: isOwnerOrAdmin,
        viewerIsOwner: viewerIsOwner,
        isMe: isMe,
      ),
      onLongPress: () => _openMemberContextMenu(
        anchor: Offset.zero,
        member: member,
        role: role,
        viewerIsAdminOrOwner: isOwnerOrAdmin,
        viewerIsOwner: viewerIsOwner,
        isMe: isMe,
      ),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            // The outer InkWell owns the tap; UserAvatar renders the
            // avatar + presence dot in one go.
            UserAvatar(
              userId: member.userId,
              username: member.username,
              avatarUrl: member.avatarUrl,
              radius: 18,
              showPresence: true,
              openProfileOnTap: false,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    children: [
                      if (role == 'owner' || role == 'admin') ...[
                        MemberRoleIcon(role: role),
                        const SizedBox(width: 4),
                      ],
                      Flexible(
                        child: Text(
                          member.username,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      MemberRoleBadge(
                        role: role,
                        margin: const EdgeInsets.only(left: 6),
                      ),
                    ],
                  ),
                  const SizedBox(height: 2),
                  Text(
                    activity,
                    style: TextStyle(color: context.textMuted, fontSize: 11),
                  ),
                ],
              ),
            ),
            _buildMemberActions(
                  member: member,
                  isOwnerOrAdmin: isOwnerOrAdmin,
                  viewerIsOwner: viewerIsOwner,
                  isMe: isMe,
                  role: role,
                ) ??
                const SizedBox.shrink(),
          ],
        ),
      ),
    );
  }

  /// Member roster grouped by role (Owner / Admin / Members), matching the
  /// desktop members panel (#769). Each section header is uppercase with a
  /// muted color + letter-spacing; rows sort alphabetically within a section.
  List<Widget> _buildMembersSection({
    required Conversation conv,
    required String myUserId,
    required bool isOwnerOrAdmin,
    required bool viewerIsOwner,
  }) {
    int sortByName(ConversationMember a, ConversationMember b) =>
        a.username.toLowerCase().compareTo(b.username.toLowerCase());

    final owners = conv.members.where((m) => m.role == 'owner').toList()
      ..sort(sortByName);
    final admins = conv.members.where((m) => m.role == 'admin').toList()
      ..sort(sortByName);
    final regulars =
        conv.members
            .where((m) => m.role != 'owner' && m.role != 'admin')
            .toList()
          ..sort(sortByName);

    Widget sectionHeader(String label) => Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: Text(
        label,
        style: TextStyle(
          color: context.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w700,
          letterSpacing: 0.6,
        ),
      ),
    );

    Iterable<Widget> renderGroup(
      String label,
      List<ConversationMember> group,
    ) sync* {
      if (group.isEmpty) return;
      yield sectionHeader('$label — ${group.length}');
      for (final m in group) {
        yield _buildMemberTile(
          member: m,
          myUserId: myUserId,
          isOwnerOrAdmin: isOwnerOrAdmin,
          viewerIsOwner: viewerIsOwner,
        );
      }
    }

    return [
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(
          children: [
            Text(
              '${conv.members.length} ${conv.members.length == 1 ? 'member' : 'members'}',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.person_add_outlined),
              tooltip: 'Add member',
              onPressed: _addMember,
            ),
          ],
        ),
      ),
      ...renderGroup('OWNER', owners),
      ...renderGroup('ADMIN', admins),
      ...renderGroup('MEMBERS', regulars),
    ];
  }
}
