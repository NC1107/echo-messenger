import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/contact.dart';
import '../models/conversation.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../widgets/avatar_utils.dart';
import '../widgets/settings/section_header.dart';

/// Modal-style "New message" composer.
///
/// Shows a Cancel / title header, a chip-style "To:" field that filters the
/// suggestion list as the user types, and a list of suggested contacts. Tap
/// a contact to start (or resume) a DM with them — the resolved
/// [Conversation] is passed to [onStartConversation].
///
/// The chip multi-select pattern is rendered for visual parity with the
/// design mockups. Confirming with multiple recipients is reserved for
/// future group-creation flow; tapping a single contact starts a DM
/// immediately.
class NewMessageScreen extends ConsumerStatefulWidget {
  /// Called once a contact is chosen and the DM has been resolved.
  /// Typically pops this screen and navigates the parent into the chat.
  final void Function(Conversation conversation)? onStartConversation;

  const NewMessageScreen({super.key, this.onStartConversation});

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  String _query = '';
  final Set<String> _selectedUserIds = {};
  bool _starting = false;

  @override
  void initState() {
    super.initState();
    // Auto-focus the chip input so the keyboard pops on mobile.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
      ref.read(contactsProvider.notifier).loadContacts();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onQueryChanged(String value) {
    if (value == _query) return;
    setState(() => _query = value);
  }

  Future<void> _startDm(Contact contact) async {
    if (_starting) return;
    setState(() => _starting = true);
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(contact.userId, contact.username);
      if (!mounted) return;
      if (widget.onStartConversation != null) {
        widget.onStartConversation!(conv);
      } else {
        Navigator.of(context).pop(conv);
      }
    } finally {
      if (mounted) setState(() => _starting = false);
    }
  }

  List<Contact> _filtered(List<Contact> source) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return source;
    return source.where((c) {
      final name = (c.displayName ?? c.username).toLowerCase();
      final handle = c.username.toLowerCase();
      return name.contains(q) || handle.contains(q);
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final state = ref.watch(contactsProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    final onlineUsers = ref.watch(
      websocketProvider.select((s) => s.onlineUsers),
    );

    final suggestions = _filtered(state.contacts);

    return Scaffold(
      backgroundColor: context.mainBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: 8),
            _buildToField(context),
            if (suggestions.isNotEmpty) ...[
              const SectionHeader('Suggested'),
              Expanded(
                child: ListView.builder(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  itemCount: suggestions.length,
                  itemBuilder: (_, i) => _ContactRow(
                    contact: suggestions[i],
                    serverUrl: serverUrl,
                    isOnline: onlineUsers.contains(suggestions[i].userId),
                    isSelected: _selectedUserIds.contains(
                      suggestions[i].userId,
                    ),
                    onTap: () => _startDm(suggestions[i]),
                  ),
                ),
              ),
            ] else
              Expanded(child: _buildEmptyState(context, state)),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
      child: SizedBox(
        height: 44,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => Navigator.of(context).pop(),
                style: TextButton.styleFrom(
                  foregroundColor: context.accent,
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                ),
                child: const Text(
                  'Cancel',
                  style: TextStyle(fontSize: 15, fontWeight: FontWeight.w500),
                ),
              ),
            ),
            Text(
              'New message',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildToField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 13, right: 8),
            child: Text(
              'To:',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          ),
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: context.cardRowBg,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: _searchFocusNode.hasFocus
                      ? context.accent
                      : Colors.transparent,
                  width: 1,
                ),
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              // Lay out: pill chips (if any) on the left, then a flexible
              // text field that fills the remaining row width. A bare Wrap
              // with a minWidth-constrained TextField caused an empty pill
              // shape to render before any recipient was selected.
              child: Row(
                children: [
                  if (_selectedUserIds.isNotEmpty) ...[
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _selectedUserIds.map((uid) {
                        final contact = ref
                            .read(contactsProvider)
                            .contacts
                            .where((c) => c.userId == uid)
                            .firstOrNull;
                        final name =
                            contact?.displayName ?? contact?.username ?? uid;
                        return _RecipientChip(
                          name: name,
                          onRemove: () =>
                              setState(() => _selectedUserIds.remove(uid)),
                        );
                      }).toList(),
                    ),
                    const SizedBox(width: 6),
                  ],
                  Expanded(
                    child: TextField(
                      controller: _searchController,
                      focusNode: _searchFocusNode,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 14,
                      ),
                      decoration: InputDecoration(
                        hintText: _selectedUserIds.isEmpty
                            ? 'Type a name or @handle'
                            : '',
                        hintStyle: TextStyle(
                          color: context.textMuted,
                          fontSize: 14,
                        ),
                        isDense: true,
                        border: InputBorder.none,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                      ),
                      onChanged: _onQueryChanged,
                      onTap: () => setState(() {}),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context, ContactsState state) {
    if (state.isLoading) {
      return Center(
        child: CircularProgressIndicator(color: context.accent, strokeWidth: 2),
      );
    }
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.person_search_outlined,
              size: 48,
              color: context.textMuted.withValues(alpha: 0.5),
            ),
            const SizedBox(height: 12),
            Text(
              _query.isEmpty
                  ? 'No contacts yet'
                  : 'No contacts match "$_query"',
              style: TextStyle(color: context.textSecondary, fontSize: 14),
              textAlign: TextAlign.center,
            ),
          ],
        ),
      ),
    );
  }
}

class _ContactRow extends StatelessWidget {
  final Contact contact;
  final String serverUrl;
  final bool isOnline;
  final bool isSelected;
  final VoidCallback onTap;

  const _ContactRow({
    required this.contact,
    required this.serverUrl,
    required this.isOnline,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = contact.displayName?.isNotEmpty == true
        ? contact.displayName!
        : contact.username;
    final resolvedAvatar = resolveAvatarUrl(contact.avatarUrl, serverUrl);

    return Material(
      color: isSelected ? context.accentLight : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              Stack(
                clipBehavior: Clip.none,
                children: [
                  buildAvatar(
                    name: displayName,
                    radius: 22,
                    imageUrl: resolvedAvatar,
                  ),
                  // Presence dot — green when online, muted grey otherwise.
                  // Always visible so the row weight is consistent.
                  Positioned(
                    right: -1,
                    bottom: -1,
                    child: Container(
                      width: 12,
                      height: 12,
                      decoration: BoxDecoration(
                        color: isOnline
                            ? EchoTheme.online
                            : const Color(0xFF6B6B6F),
                        shape: BoxShape.circle,
                        border: Border.all(color: context.mainBg, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      displayName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: context.textPrimary,
                        fontSize: 15,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '@${contact.username}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: context.textMuted, fontSize: 13),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, color: context.accent, size: 22),
            ],
          ),
        ),
      ),
    );
  }
}

class _RecipientChip extends StatelessWidget {
  final String name;
  final VoidCallback onRemove;

  const _RecipientChip({required this.name, required this.onRemove});

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.fromLTRB(10, 4, 6, 4),
      decoration: BoxDecoration(
        color: context.accentLight,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            name,
            style: TextStyle(
              color: context.accent,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            child: Icon(Icons.close, size: 14, color: context.accent),
          ),
        ],
      ),
    );
  }
}
