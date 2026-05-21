import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../models/contact.dart';
import '../models/conversation.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/fuzzy_score.dart';
import '../widgets/settings/section_header.dart';
import '../widgets/user_avatar.dart';

// ---------------------------------------------------------------------------
// NewMessageScreen
//
// Chip-based new-chat composer.
//
// UX flow:
//   1. User types a name or @handle in the text field.
//   2. An autocomplete dropdown shows matching contacts.
//   3. Selecting a suggestion OR pressing Enter materialises the typed text
//      as a chip; the field clears ready for the next recipient.
//   4. Each chip has an × to remove it.
//   5. Bottom action area:
//      - 0 chips  → disabled "Start chat" button
//      - 1 chip   → "Start chat with @username" → getOrCreateDm → navigate
//      - 2+ chips → inline group-name step appears; "Create group" calls
//                   createGroup → navigate
// ---------------------------------------------------------------------------

/// Modal-style "New message" composer with chip-based recipient selection.
///
/// Pass [onStartConversation] to receive the resolved [Conversation] and
/// handle navigation yourself (desktop dialog path). When omitted the screen
/// pops with the [Conversation] as its route result (mobile full-screen path).
class NewMessageScreen extends ConsumerStatefulWidget {
  /// Called once a conversation has been resolved or created. Typically pops
  /// this screen and selects the conversation in the parent.
  final void Function(Conversation conversation)? onStartConversation;

  const NewMessageScreen({super.key, this.onStartConversation});

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  // ── recipient chips ────────────────────────────────────────────────────────

  /// Ordered list of selected contacts (preserves insertion order).
  final List<Contact> _chips = [];

  // ── recipient search field ─────────────────────────────────────────────────

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _searchLayerLink = LayerLink();
  OverlayEntry? _overlayEntry;
  String _query = '';

  // ── group name step (shown when 2+ chips) ─────────────────────────────────

  final _groupNameController = TextEditingController();
  final _groupNameFocusNode = FocusNode();

  // ── async guards ───────────────────────────────────────────────────────────

  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
      ref.read(contactsProvider.notifier).loadContacts();
    });
    _searchFocusNode.addListener(_onSearchFocusChange);
  }

  @override
  void dispose() {
    _removeOverlay();
    _searchController.dispose();
    _searchFocusNode
      ..removeListener(_onSearchFocusChange)
      ..dispose();
    _groupNameController.dispose();
    _groupNameFocusNode.dispose();
    super.dispose();
  }

  // ── overlay / dropdown management ─────────────────────────────────────────

  void _onSearchFocusChange() {
    if (!_searchFocusNode.hasFocus) {
      _removeOverlay();
    }
  }

  void _removeOverlay() {
    _overlayEntry?.remove();
    _overlayEntry = null;
  }

  void _showOverlay(List<Contact> suggestions) {
    _removeOverlay();
    if (suggestions.isEmpty) return;

    final entry = OverlayEntry(
      builder: (ctx) => Positioned(
        width: _overlayWidth(ctx),
        child: CompositedTransformFollower(
          link: _searchLayerLink,
          showWhenUnlinked: false,
          offset: const Offset(0, 48),
          child: Material(
            elevation: 6,
            color: Theme.of(context).colorScheme.surface,
            borderRadius: BorderRadius.circular(10),
            child: _DropdownList(
              suggestions: suggestions,
              selectedIds: _chips.map((c) => c.userId).toSet(),
              onSelect: _selectSuggestion,
            ),
          ),
        ),
      ),
    );

    Overlay.of(context).insert(entry);
    _overlayEntry = entry;
  }

  double _overlayWidth(BuildContext ctx) {
    final box = _searchLayerLink.leader?.offset != null
        ? ctx.findRenderObject()
        : null;
    if (box == null) return 300;
    return (MediaQuery.of(context).size.width - 32).clamp(260, 480);
  }

  // ── chip logic ─────────────────────────────────────────────────────────────

  /// Materialise the currently typed query as a chip (if it matches a contact
  /// or if there are filtered suggestions, pick the first one).
  void _commitCurrentQuery() {
    final q = _searchController.text.trim();
    if (q.isEmpty) return;

    final contacts = ref.read(contactsProvider).contacts;
    final filtered = _filterContacts(contacts, q);

    // Prefer an exact username / displayName match, otherwise the top fuzzy hit.
    final match = filtered.isNotEmpty ? filtered.first : null;
    if (match != null) {
      _addChip(match);
    }
    // If nothing matched, silently clear — we only materialise known contacts.
    _clearSearch();
  }

  void _selectSuggestion(Contact contact) {
    _addChip(contact);
    _clearSearch();
    _searchFocusNode.requestFocus();
  }

  void _addChip(Contact contact) {
    if (_chips.any((c) => c.userId == contact.userId)) return;
    setState(() => _chips.add(contact));
    _removeOverlay();
  }

  void _removeChip(Contact contact) {
    setState(() => _chips.removeWhere((c) => c.userId == contact.userId));
  }

  void _clearSearch() {
    _searchController.clear();
    setState(() => _query = '');
    _removeOverlay();
  }

  // ── filtering ──────────────────────────────────────────────────────────────

  List<Contact> _filterContacts(List<Contact> source, String q) {
    if (q.isEmpty) return source;
    // Exclude already-selected contacts from the dropdown.
    final selectedIds = _chips.map((c) => c.userId).toSet();
    final scored = <({Contact contact, double score})>[];
    for (final c in source) {
      if (selectedIds.contains(c.userId)) continue;
      final nameScore = fuzzyScore(q, c.displayName ?? c.username);
      final handleScore = fuzzyScore(q, c.username);
      final best = nameScore > handleScore ? nameScore : handleScore;
      if (best > 0.2) scored.add((contact: c, score: best));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => e.contact).toList();
  }

  // ── action handlers ────────────────────────────────────────────────────────

  Future<void> _startDm() async {
    if (_isBusy || _chips.length != 1) return;
    final contact = _chips.first;
    setState(() => _isBusy = true);
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(contact.userId, contact.username);
      if (!mounted) return;
      _deliver(conv);
    } on DmException catch (e) {
      if (!mounted) return;
      ToastService.show(context, e.message, type: ToastType.error);
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  Future<void> _createGroup() async {
    if (_isBusy || _chips.length < 2) return;
    final name = _groupNameController.text.trim();
    if (name.isEmpty) {
      ToastService.show(
        context,
        'Enter a group name first',
        type: ToastType.warning,
      );
      _groupNameFocusNode.requestFocus();
      return;
    }
    setState(() => _isBusy = true);
    try {
      final memberIds = _chips.map((c) => c.userId).toList();
      final convId = await ref
          .read(conversationsProvider.notifier)
          .createGroup(name, memberIds);
      if (!mounted) return;
      if (convId == null || convId.isEmpty) {
        ToastService.show(
          context,
          'Failed to create group',
          type: ToastType.error,
        );
        return;
      }
      // Find the newly created conversation in state.
      final conv = ref
          .read(conversationsProvider)
          .conversations
          .where((c) => c.id == convId)
          .firstOrNull;
      _deliver(
        conv ??
            Conversation(
              id: convId,
              name: name,
              isGroup: true,
              members: _chips
                  .map(
                    (c) => ConversationMember(
                      userId: c.userId,
                      username: c.username,
                    ),
                  )
                  .toList(),
            ),
      );
    } finally {
      if (mounted) setState(() => _isBusy = false);
    }
  }

  void _deliver(Conversation conv) {
    if (widget.onStartConversation != null) {
      widget.onStartConversation!(conv);
    } else {
      Navigator.of(context).pop(conv);
    }
  }

  // ── build ──────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final contactsState = ref.watch(contactsProvider);

    final suggestions = _filterContacts(contactsState.contacts, _query);

    // Keep the dropdown in sync whenever filtered suggestions change.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      if (_query.isNotEmpty && _searchFocusNode.hasFocus) {
        _showOverlay(suggestions);
      } else {
        _removeOverlay();
      }
    });

    final showGroupStep = _chips.length >= 2;

    return Scaffold(
      backgroundColor: context.mainBg,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context),
            const SizedBox(height: 8),
            _buildChipField(context),
            if (showGroupStep) ...[
              const SizedBox(height: 12),
              _buildGroupNameField(context),
            ],
            if (!showGroupStep && suggestions.isNotEmpty) ...[
              const SectionHeader('Suggested'),
              Expanded(
                child: _ContactList(
                  contacts: suggestions,
                  selectedIds: _chips.map((c) => c.userId).toSet(),
                  onSelect: _selectSuggestion,
                ),
              ),
            ] else if (!showGroupStep)
              Expanded(child: _buildEmptyState(context, contactsState)),
            if (showGroupStep) const Spacer(),
            _buildActionBar(context),
          ],
        ),
      ),
    );
  }

  // ── sub-widgets ────────────────────────────────────────────────────────────

  Widget _buildHeader(BuildContext context) {
    return Semantics(
      header: true,
      label: 'New message dialog',
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 0),
        child: SizedBox(
          height: 44,
          child: Stack(
            alignment: Alignment.center,
            children: [
              Align(
                alignment: Alignment.centerLeft,
                child: Tooltip(
                  message: 'Cancel',
                  child: TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    style: TextButton.styleFrom(
                      foregroundColor: context.accent,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                    ),
                    child: const Text(
                      'Cancel',
                      style: TextStyle(
                        fontSize: 15,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
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
      ),
    );
  }

  /// The chip wrap + search text field row.
  Widget _buildChipField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 0),
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
            child: CompositedTransformTarget(
              link: _searchLayerLink,
              child: Container(
                constraints: const BoxConstraints(minHeight: 50),
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
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: [
                    ..._chips.map(
                      (c) => _RecipientChip(
                        key: ValueKey(c.userId),
                        name: c.displayName ?? c.username,
                        onRemove: () => _removeChip(c),
                      ),
                    ),
                    // Inline text field at the end of the chip row.
                    ConstrainedBox(
                      constraints: const BoxConstraints(minWidth: 120),
                      child: IntrinsicWidth(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 14,
                          ),
                          decoration: InputDecoration(
                            hintText: _chips.isEmpty
                                ? 'Type a name or @handle'
                                : '',
                            hintStyle: TextStyle(
                              color: context.textMuted,
                              fontSize: 14,
                            ),
                            isDense: true,
                            border: InputBorder.none,
                            contentPadding: const EdgeInsets.symmetric(
                              vertical: 8,
                            ),
                          ),
                          onChanged: (v) {
                            setState(() => _query = v.trim());
                          },
                          onTap: () => setState(() {}),
                          // Enter key materialises a chip.
                          onSubmitted: (_) => _commitCurrentQuery(),
                          textInputAction: TextInputAction.done,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildGroupNameField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: TextField(
        controller: _groupNameController,
        focusNode: _groupNameFocusNode,
        autofocus: true,
        style: TextStyle(color: context.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          labelText: 'Group name',
          labelStyle: TextStyle(color: context.textMuted, fontSize: 14),
          hintText: 'e.g. Team Rocket',
          hintStyle: TextStyle(color: context.textMuted, fontSize: 13),
          filled: true,
          fillColor: context.cardRowBg,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide.none,
          ),
          focusedBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: context.accent),
          ),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
        onSubmitted: (_) => _createGroup(),
        textInputAction: TextInputAction.done,
      ),
    );
  }

  Widget _buildActionBar(BuildContext context) {
    final count = _chips.length;

    final bool enabled = count >= 1 && !_isBusy;
    final String label;
    final VoidCallback? onPressed;

    if (count == 0) {
      label = 'Start chat';
      onPressed = null;
    } else if (count == 1) {
      final name = _chips.first.displayName ?? _chips.first.username;
      label = 'Start chat with @$name';
      onPressed = enabled ? _startDm : null;
    } else {
      label = 'Create group';
      onPressed = enabled ? _createGroup : null;
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
      child: FilledButton(
        onPressed: onPressed,
        style: FilledButton.styleFrom(
          minimumSize: const Size.fromHeight(48),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: _isBusy
            ? SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: context.onAccent,
                ),
              )
            : Text(
                label,
                style: const TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
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

// ---------------------------------------------------------------------------
// _ContactList  — scrollable list of autocomplete suggestions / all contacts
// ---------------------------------------------------------------------------

class _ContactList extends StatelessWidget {
  final List<Contact> contacts;
  final Set<String> selectedIds;
  final ValueChanged<Contact> onSelect;

  const _ContactList({
    required this.contacts,
    required this.selectedIds,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      itemCount: contacts.length,
      itemBuilder: (_, i) => _ContactRow(
        contact: contacts[i],
        isSelected: selectedIds.contains(contacts[i].userId),
        onTap: () => onSelect(contacts[i]),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _DropdownList  — overlay dropdown shown while typing
// ---------------------------------------------------------------------------

class _DropdownList extends StatelessWidget {
  final List<Contact> suggestions;
  final Set<String> selectedIds;
  final ValueChanged<Contact> onSelect;

  const _DropdownList({
    required this.suggestions,
    required this.selectedIds,
    required this.onSelect,
  });

  @override
  Widget build(BuildContext context) {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxHeight: 240),
      child: ListView.builder(
        padding: const EdgeInsets.symmetric(vertical: 4),
        shrinkWrap: true,
        itemCount: suggestions.length,
        itemBuilder: (_, i) => _ContactRow(
          contact: suggestions[i],
          isSelected: selectedIds.contains(suggestions[i].userId),
          onTap: () => onSelect(suggestions[i]),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// _ContactRow
// ---------------------------------------------------------------------------

class _ContactRow extends StatelessWidget {
  final Contact contact;
  final bool isSelected;
  final VoidCallback onTap;

  const _ContactRow({
    required this.contact,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    final displayName = contact.displayName?.isNotEmpty == true
        ? contact.displayName!
        : contact.username;

    return Material(
      color: isSelected ? context.accentLight : Colors.transparent,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
          child: Row(
            children: [
              UserAvatar(
                userId: contact.userId,
                username: displayName,
                avatarUrl: contact.avatarUrl,
                radius: 22,
                showPresence: true,
                openProfileOnTap: false,
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

// ---------------------------------------------------------------------------
// _RecipientChip
// ---------------------------------------------------------------------------

class _RecipientChip extends StatelessWidget {
  final String name;
  final VoidCallback onRemove;

  const _RecipientChip({super.key, required this.name, required this.onRemove});

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
            '@$name',
            style: TextStyle(
              color: context.accent,
              fontSize: 13,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(width: 4),
          GestureDetector(
            onTap: onRemove,
            behavior: HitTestBehavior.opaque,
            child: Semantics(
              label: 'remove $name',
              button: true,
              child: Icon(Icons.close, size: 14, color: context.accent),
            ),
          ),
        ],
      ),
    );
  }
}
