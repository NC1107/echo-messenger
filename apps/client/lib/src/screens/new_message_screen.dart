import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../models/contact.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../utils/fuzzy_score.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/empty_state.dart';
import '../widgets/settings/section_header.dart';
import '../widgets/user_avatar.dart';

/// "New chat" composer: one search box over a tappable list.
///
/// - Default (DM) mode: tapping a contact row opens the DM immediately — no
///   chips, no second confirm. A pinned "New group" row switches to group mode.
/// - When the query matches no local contact, an inline "Search on Echo" finds
///   users by @username and lets you send a contact request right here.
/// - Group mode: rows become checkboxes; a bottom bar creates the group.
///
/// Pass [onStartConversation] to receive the resolved [Conversation] (desktop
/// dialog path); when omitted the screen pops with the conversation (mobile).
class NewMessageScreen extends ConsumerStatefulWidget {
  final void Function(Conversation conversation)? onStartConversation;

  const NewMessageScreen({super.key, this.onStartConversation});

  @override
  ConsumerState<NewMessageScreen> createState() => _NewMessageScreenState();
}

enum _Mode { dm, group }

class _NewMessageScreenState extends ConsumerState<NewMessageScreen> {
  _Mode _mode = _Mode.dm;

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  final _searchFieldKey = GlobalKey();
  String _query = '';

  // Group multi-select (userId -> Contact, preserves insertion order).
  final Map<String, Contact> _selected = {};
  final _groupNameController = TextEditingController();

  // Server "search on Echo" (add brand-new contacts inline).
  Timer? _debounce;
  List<_SearchUser> _serverResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  final Set<String> _requested = {}; // usernames we've sent a request to

  bool _isBusy = false;

  @override
  void initState() {
    super.initState();
    _searchController.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _searchFocusNode.requestFocus();
      ref.read(contactsProvider.notifier).loadContacts();
    });
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController
      ..removeListener(_onQueryChanged)
      ..dispose();
    _searchFocusNode.dispose();
    _groupNameController.dispose();
    super.dispose();
  }

  void _onQueryChanged() {
    final q = _searchController.text.trim();
    if (q == _query) return;
    setState(() {
      _query = q;
      // Reset any prior Echo search; it re-runs only when the user asks.
      _serverResults = [];
      _hasSearched = false;
    });
  }

  // ── filtering ──────────────────────────────────────────────────────────────

  List<Contact> _filteredContacts(List<Contact> source) {
    if (_query.isEmpty) return source;
    final scored = <({Contact contact, double score})>[];
    for (final c in source) {
      final byName = fuzzyScore(_query, c.displayName ?? c.username);
      final byHandle = fuzzyScore(_query, c.username);
      final best = byName > byHandle ? byName : byHandle;
      if (best > 0.2) scored.add((contact: c, score: best));
    }
    scored.sort((a, b) => b.score.compareTo(a.score));
    return scored.map((e) => e.contact).toList();
  }

  // ── mode + selection ─────────────────────────────────────────────────────

  void _enterGroupMode() => setState(() => _mode = _Mode.group);

  Future<void> _exitGroupMode() async {
    if (_selected.isNotEmpty) {
      final discard = await showEchoConfirmDialog(
        context,
        title: 'Discard group?',
        content: const Text('You\'ve selected people for a new group.'),
        confirmLabel: 'Discard',
        destructive: true,
      );
      if (!discard || !mounted) return;
    }
    setState(() {
      _mode = _Mode.dm;
      _selected.clear();
      _groupNameController.clear();
    });
  }

  void _toggleSelect(Contact c) {
    setState(() {
      if (_selected.containsKey(c.userId)) {
        _selected.remove(c.userId);
      } else {
        _selected[c.userId] = c;
      }
    });
  }

  // ── actions ──────────────────────────────────────────────────────────────

  Future<void> _startDm(String userId, String username) async {
    if (_isBusy) return;
    setState(() => _isBusy = true);
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(userId, username);
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
    if (_isBusy || _selected.isEmpty) return;
    setState(() => _isBusy = true);
    try {
      final members = _selected.values.toList();
      final typed = _groupNameController.text.trim();
      final name = typed.isNotEmpty ? typed : _defaultGroupName(members);
      final String convId;
      try {
        convId = await ref
            .read(conversationsProvider.notifier)
            .createGroup(name, members.map((c) => c.userId).toList());
      } on GroupException catch (e) {
        if (!mounted) return;
        ToastService.show(context, e.message, type: ToastType.error);
        return;
      }
      if (!mounted) return;
      final existing = ref
          .read(conversationsProvider)
          .conversations
          .where((c) => c.id == convId)
          .firstOrNull;
      _deliver(
        existing ??
            Conversation(
              id: convId,
              name: name,
              isGroup: true,
              members: members
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

  String _defaultGroupName(List<Contact> members) {
    final names = members
        .map((c) => c.displayName ?? c.username)
        .take(3)
        .join(', ');
    return members.length > 3 ? '$names +${members.length - 3}' : names;
  }

  Future<void> _searchEcho() async {
    final q = _query;
    if (q.length < 2 || _isSearching) return;
    setState(() => _isSearching = true);
    try {
      final serverUrl = ref.read(serverUrlProvider);
      final res = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse(
                '$serverUrl/api/users/search?q=${Uri.encodeComponent(q)}',
              ),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (!mounted) return;
      var users = <_SearchUser>[];
      if (res.statusCode == 200) {
        final data = jsonDecode(res.body) as Map<String, dynamic>;
        users = (data['users'] as List? ?? [])
            .map((e) => _SearchUser.fromJson(e as Map<String, dynamic>))
            .toList();
      }
      setState(() {
        _serverResults = users;
        _hasSearched = true;
        _isSearching = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isSearching = false;
        _hasSearched = true;
      });
      ToastService.show(context, 'Search failed', type: ToastType.error);
    }
  }

  Future<void> _sendRequest(String username) async {
    setState(() => _requested.add(username));
    try {
      await ref.read(contactsProvider.notifier).sendRequest(username);
      if (mounted) {
        ToastService.show(context, 'Request sent to @$username');
      }
    } catch (e) {
      if (!mounted) return;
      setState(() => _requested.remove(username));
      ToastService.show(
        context,
        'Could not send request',
        type: ToastType.error,
      );
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
    final isGroup = _mode == _Mode.group;
    return Scaffold(
      backgroundColor: context.mainBg,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _buildHeader(context, isGroup),
            _buildSearchField(context),
            Expanded(
              child: isGroup
                  ? _buildGroupBody(context, contactsState)
                  : _buildDmBody(context, contactsState),
            ),
            if (isGroup) _buildGroupActionBar(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context, bool isGroup) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(4, 8, 8, 4),
      child: Row(
        children: [
          Semantics(
            label: isGroup ? 'Back to new chat' : 'Close',
            button: true,
            child: IconButton(
              icon: Icon(isGroup ? Icons.arrow_back : Icons.close),
              onPressed: () {
                if (isGroup) {
                  _exitGroupMode();
                } else {
                  Navigator.of(context).maybePop();
                }
              },
            ),
          ),
          Text(
            isGroup ? 'New group' : 'New chat',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSearchField(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
      child: TextField(
        key: _searchFieldKey,
        controller: _searchController,
        focusNode: _searchFocusNode,
        style: TextStyle(color: context.textPrimary, fontSize: 15),
        decoration: InputDecoration(
          prefixIcon: Icon(Icons.search, color: context.textMuted, size: 20),
          hintText: 'Search name or @username',
          hintStyle: TextStyle(color: context.textMuted, fontSize: 15),
          filled: true,
          fillColor: context.cardRowBg,
          isDense: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(12),
            borderSide: BorderSide.none,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 12),
        ),
        textInputAction: TextInputAction.search,
        onSubmitted: (_) {
          if (_mode == _Mode.dm && _query.length >= 2) _searchEcho();
        },
      ),
    );
  }

  // ── DM body ────────────────────────────────────────────────────────────────

  Widget _buildDmBody(BuildContext context, ContactsState state) {
    if (state.isLoading && state.contacts.isEmpty) {
      return Center(
        child: CircularProgressIndicator(color: context.accent, strokeWidth: 2),
      );
    }
    final filtered = _filteredContacts(state.contacts);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (_query.isEmpty)
          _buildNewGroupRow(context)
        else if (filtered.isEmpty && !_hasSearched)
          _buildNoLocalMatch(context),
        if (filtered.isNotEmpty) ...[
          const SectionHeader('Contacts'),
          ...filtered.map(
            (c) => _PickRow(
              userId: c.userId,
              username: c.username,
              displayName: c.displayName,
              avatarUrl: c.avatarUrl,
              onTap: _isBusy ? null : () => _startDm(c.userId, c.username),
            ),
          ),
        ],
        if (_query.isEmpty && state.contacts.isEmpty)
          const Padding(
            padding: EdgeInsets.only(top: 32),
            child: EmptyState(
              icon: Icons.person_add_alt_1_outlined,
              title: 'No contacts yet — search a @username to add someone',
            ),
          ),
        if (_query.length >= 2) _buildEchoSearchSection(context, state),
      ],
    );
  }

  Widget _buildNewGroupRow(BuildContext context) {
    return Semantics(
      button: true,
      label: 'New group',
      child: ListTile(
        leading: CircleAvatar(
          backgroundColor: context.accentLight,
          child: Icon(Icons.group_add_outlined, color: context.accent),
        ),
        title: Text(
          'New group',
          style: TextStyle(
            color: context.textPrimary,
            fontWeight: FontWeight.w600,
          ),
        ),
        trailing: Icon(Icons.chevron_right, color: context.textMuted),
        onTap: _enterGroupMode,
      ),
    );
  }

  Widget _buildNoLocalMatch(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Text(
        'No contacts match "$_query".',
        style: TextStyle(color: context.textMuted, fontSize: 14),
      ),
    );
  }

  Widget _buildEchoSearchSection(BuildContext context, ContactsState state) {
    if (!_hasSearched) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
        child: Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _isSearching ? null : _searchEcho,
            icon: _isSearching
                ? SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: context.accent,
                    ),
                  )
                : const Icon(Icons.public, size: 18),
            label: Text('Search "$_query" on Echo'),
          ),
        ),
      );
    }
    final contactIds = state.contacts.map((c) => c.userId).toSet();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SectionHeader('On Echo'),
        if (_serverResults.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              'No one found for "$_query".',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          )
        else
          ..._serverResults.map(
            (u) => _PickRow(
              userId: u.userId,
              username: u.username,
              displayName: u.displayName,
              avatarUrl: u.avatarUrl,
              trailing: _echoTrailing(context, u, contactIds),
            ),
          ),
      ],
    );
  }

  Widget _echoTrailing(
    BuildContext context,
    _SearchUser u,
    Set<String> contactIds,
  ) {
    if (contactIds.contains(u.userId)) {
      return TextButton(
        onPressed: _isBusy ? null : () => _startDm(u.userId, u.username),
        child: const Text('Message'),
      );
    }
    if (_requested.contains(u.username)) {
      return Text(
        'Requested',
        style: TextStyle(color: context.textMuted, fontSize: 13),
      );
    }
    return TextButton.icon(
      onPressed: () => _sendRequest(u.username),
      icon: const Icon(Icons.person_add_alt_1, size: 16),
      label: const Text('Add'),
    );
  }

  // ── group body + action bar ───────────────────────────────────────────────

  Widget _buildGroupBody(BuildContext context, ContactsState state) {
    final filtered = _filteredContacts(state.contacts);
    return ListView(
      padding: const EdgeInsets.only(bottom: 16),
      children: [
        if (_selected.isNotEmpty) _buildSelectionSummary(context),
        const SectionHeader('Contacts'),
        if (filtered.isEmpty)
          Padding(
            padding: const EdgeInsets.all(16),
            child: Text(
              _query.isEmpty
                  ? 'No contacts yet.'
                  : 'No contacts match "$_query".',
              style: TextStyle(color: context.textMuted, fontSize: 14),
            ),
          )
        else
          ...filtered.map(
            (c) => _PickRow(
              userId: c.userId,
              username: c.username,
              displayName: c.displayName,
              avatarUrl: c.avatarUrl,
              selected: _selected.containsKey(c.userId),
              trailing: Checkbox(
                value: _selected.containsKey(c.userId),
                onChanged: (_) => _toggleSelect(c),
              ),
              onTap: () => _toggleSelect(c),
            ),
          ),
      ],
    );
  }

  Widget _buildSelectionSummary(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
      child: Text(
        '${_selected.length} selected',
        style: TextStyle(
          color: context.textSecondary,
          fontSize: 13,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }

  Widget _buildGroupActionBar(BuildContext context) {
    final count = _selected.length;
    return Padding(
      padding: EdgeInsets.fromLTRB(
        16,
        8,
        16,
        16 + MediaQuery.of(context).viewInsets.bottom,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          TextField(
            controller: _groupNameController,
            style: TextStyle(color: context.textPrimary, fontSize: 14),
            decoration: InputDecoration(
              hintText: 'Group name (optional)',
              hintStyle: TextStyle(color: context.textMuted, fontSize: 14),
              filled: true,
              fillColor: context.cardRowBg,
              isDense: true,
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 12,
                vertical: 12,
              ),
            ),
          ),
          const SizedBox(height: 10),
          FilledButton(
            onPressed: (count >= 1 && !_isBusy) ? _createGroup : null,
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
                    count == 0 ? 'Create group' : 'Create group · $count',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
          ),
        ],
      ),
    );
  }
}

/// A user returned from /api/users/search.
class _SearchUser {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;

  const _SearchUser({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarUrl,
  });

  factory _SearchUser.fromJson(Map<String, dynamic> json) => _SearchUser(
    userId: json['user_id'] as String,
    username: json['username'] as String,
    displayName: json['display_name'] as String?,
    avatarUrl: json['avatar_url'] as String?,
  );
}

// ---------------------------------------------------------------------------
// _PickRow — one tappable contact/search row with an optional trailing slot.
// Used for DM (no trailing → whole row opens the DM), group (checkbox), and
// Echo search (Add / Requested / Message), so all three list contexts stay
// visually identical instead of hand-rolling three near-duplicate rows.
// ---------------------------------------------------------------------------

class _PickRow extends StatelessWidget {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final Widget? trailing;
  final VoidCallback? onTap;
  final bool selected;

  const _PickRow({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarUrl,
    this.trailing,
    this.onTap,
    this.selected = false,
  });

  @override
  Widget build(BuildContext context) {
    final name = (displayName?.isNotEmpty ?? false) ? displayName! : username;
    return Semantics(
      button: onTap != null,
      label: name,
      child: Material(
        color: selected ? context.accentLight : Colors.transparent,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                UserAvatar(
                  userId: userId,
                  username: name,
                  avatarUrl: avatarUrl,
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
                        name,
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
                        '@$username',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                ?trailing,
              ],
            ),
          ),
        ),
      ),
    );
  }
}
