import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../models/contact.dart';
import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../widgets/avatar_utils.dart' show buildAvatar;
import 'user_profile_screen.dart';

/// A user returned from the /api/users/search endpoint.
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

  factory _SearchUser.fromJson(Map<String, dynamic> json) {
    return _SearchUser(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}

class ContactsScreen extends ConsumerStatefulWidget {
  /// When provided, tapping "Message" on a contact will call this callback
  /// instead of navigating away. Used when ContactsScreen is shown in a dialog.
  final void Function(Conversation)? onStartConversation;

  const ContactsScreen({super.key, this.onStartConversation});

  @override
  ConsumerState<ContactsScreen> createState() => _ContactsScreenState();
}

class _ContactsScreenState extends ConsumerState<ContactsScreen> {
  bool _isStartingDm = false;

  final _searchController = TextEditingController();
  final _searchFocusNode = FocusNode();
  Timer? _debounce;

  List<_SearchUser> _searchResults = [];
  bool _isSearching = false;
  bool _hasSearched = false;
  String? _searchError;

  /// User IDs that have been locally dismissed from pending requests.
  final Set<String> _dismissedPending = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(contactsProvider.notifier).loadContacts();
      ref.read(contactsProvider.notifier).loadPending();
    });
    _searchController.addListener(_onSearchChanged);
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _searchController.removeListener(_onSearchChanged);
    _searchController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  void _onSearchChanged() {
    final query = _searchController.text.trim();
    _debounce?.cancel();

    if (query.length < 2) {
      setState(() {
        _searchResults = [];
        _isSearching = false;
        _hasSearched = false;
      });
      return;
    }

    _debounce = Timer(const Duration(milliseconds: 400), () {
      _performSearch(query);
    });
  }

  Future<void> _performSearch(String query) async {
    if (!mounted) return;
    setState(() => _isSearching = true);

    try {
      final serverUrl = ref.read(serverUrlProvider);
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse(
                '$serverUrl/api/users/search?q=${Uri.encodeComponent(query)}',
              ),
              headers: {
                'Content-Type': 'application/json',
                'Authorization': 'Bearer $token',
              },
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final users = (data['users'] as List)
            .map((e) => _SearchUser.fromJson(e as Map<String, dynamic>))
            .toList();
        setState(() {
          _searchResults = users;
          _isSearching = false;
          _hasSearched = true;
          _searchError = null;
        });
      } else {
        setState(() {
          _searchResults = [];
          _isSearching = false;
          _hasSearched = true;
        });
      }
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _searchResults = [];
        _isSearching = false;
        _hasSearched = true;
        _searchError = 'Search failed \u2014 check your connection';
      });
    }
  }

  Future<void> _messageContact(String userId, String username) async {
    if (_isStartingDm) return;
    setState(() => _isStartingDm = true);

    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(userId, username);

      if (!mounted) return;

      if (widget.onStartConversation != null) {
        widget.onStartConversation!(conv);
      } else {
        context.go('/home?conversation=${conv.id}');
      }
    } on DmException catch (e) {
      if (!mounted) return;
      ToastService.show(context, e.message, type: ToastType.error);
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not start conversation',
        type: ToastType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isStartingDm = false);
      }
    }
  }

  /// Determine the relationship status of a search result user.
  /// Returns 'contact', 'pending', or null (no relationship).
  String? _contactStatus(String userId) {
    final contacts = ref.read(contactsProvider);
    final isContact = contacts.contacts.any((c) => c.userId == userId);
    if (isContact) return 'contact';
    final isPending = contacts.pendingRequests.any((c) => c.userId == userId);
    if (isPending) return 'pending';
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final contactsState = ref.watch(contactsProvider);
    final isActive = _searchController.text.trim().length >= 2;

    ref.listen<ContactsState>(contactsProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ToastService.show(context, next.error!, type: ToastType.error);
      }
    });

    return Scaffold(
      appBar: AppBar(title: const Text('Contacts')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: Column(
            children: [
              _buildSearchBar(context),
              Expanded(
                child: isActive
                    ? _buildSearchResults(context)
                    : _buildContactsList(context, contactsState),
              ),
            ],
          ),
        ),
      ),
      floatingActionButton: FloatingActionButton(
        onPressed: () {
          _searchFocusNode.requestFocus();
        },
        child: const Icon(Icons.person_add_outlined),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Search bar
  // ---------------------------------------------------------------------------

  Widget _buildSearchBar(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
      child: TextField(
        controller: _searchController,
        focusNode: _searchFocusNode,
        style: TextStyle(color: context.textPrimary, fontSize: 14),
        decoration: InputDecoration(
          hintText: 'Search by username, email, or phone...',
          prefixIcon: Icon(Icons.search, color: context.textMuted, size: 20),
          suffixIcon: _searchController.text.isNotEmpty
              ? IconButton(
                  icon: Icon(Icons.close, color: context.textMuted, size: 18),
                  onPressed: () {
                    _searchController.clear();
                    _searchFocusNode.unfocus();
                  },
                )
              : null,
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Search results view
  // ---------------------------------------------------------------------------

  Widget _buildSearchResults(BuildContext context) {
    if (_isSearching) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(32),
          child: CircularProgressIndicator(),
        ),
      );
    }

    if (_hasSearched && _searchResults.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                _searchError != null ? Icons.cloud_off : Icons.search_off,
                size: 32,
                color: context.textMuted.withValues(alpha: 0.5),
              ),
              const SizedBox(height: 12),
              Text(
                _searchError ?? 'No users found',
                style: TextStyle(color: context.textMuted, fontSize: 14),
                textAlign: TextAlign.center,
              ),
              if (_searchError != null) ...[
                const SizedBox(height: 12),
                TextButton.icon(
                  onPressed: () =>
                      _performSearch(_searchController.text.trim()),
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                ),
              ],
            ],
          ),
        ),
      );
    }

    if (!_hasSearched) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(48),
          child: Text(
            'Type to search by username, email, or phone...',
            style: TextStyle(color: context.textMuted, fontSize: 14),
          ),
        ),
      );
    }

    final serverUrl = ref.watch(serverUrlProvider);
    final currentUserId = ref.watch(authProvider).userId;

    return ListView.builder(
      padding: const EdgeInsets.symmetric(vertical: 8),
      itemCount: _searchResults.length,
      itemBuilder: (context, index) {
        final user = _searchResults[index];

        // Don't show the current user in results.
        if (user.userId == currentUserId) {
          return const SizedBox.shrink();
        }

        final status = _contactStatus(user.userId);
        final avatarImageUrl = user.avatarUrl != null
            ? '$serverUrl${user.avatarUrl}'
            : null;

        return _SearchResultCard(
          user: user,
          avatarImageUrl: avatarImageUrl,
          status: status,
          onAdd: () {
            ref.read(contactsProvider.notifier).sendRequest(user.username);
            ToastService.show(context, 'Request sent to @${user.username}');
          },
          onTap: () {
            UserProfileScreen.show(context, ref, user.userId);
          },
        );
      },
    );
  }

  // ---------------------------------------------------------------------------
  // Default contacts list (when not searching)
  // ---------------------------------------------------------------------------

  Widget _buildContactsList(BuildContext context, ContactsState contactsState) {
    final isInitialLoading =
        contactsState.isLoading &&
        contactsState.contacts.isEmpty &&
        contactsState.pendingRequests.isEmpty;

    if (isInitialLoading) {
      return const Center(child: CircularProgressIndicator());
    }

    return RefreshIndicator(
      onRefresh: () async {
        await ref.read(contactsProvider.notifier).loadContacts();
        await ref.read(contactsProvider.notifier).loadPending();
      },
      child: ListView(
        padding: const EdgeInsets.symmetric(vertical: 8),
        children: [
          _buildPendingRequestsSection(context, contactsState),
          _buildContactsSection(context, contactsState),
          _buildEmptyState(contactsState),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Pending requests section
  // ---------------------------------------------------------------------------

  Widget _buildPendingRequestsSection(
    BuildContext context,
    ContactsState contactsState,
  ) {
    final visible = contactsState.pendingRequests
        .where((c) => !_dismissedPending.contains(c.userId))
        .toList();

    if (visible.isEmpty) return const SizedBox.shrink();

    final serverUrl = ref.watch(serverUrlProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'PENDING REQUESTS',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: context.accent),
          ),
        ),
        ...visible.map((contact) {
          return _PendingRequestTile(
            contact: contact,
            serverUrl: serverUrl,
            onAccept: () {
              ref.read(contactsProvider.notifier).acceptRequest(contact.id);
            },
            onDecline: () {
              setState(() {
                _dismissedPending.add(contact.userId);
              });
            },
          );
        }),
        Divider(indent: 16, endIndent: 16, color: context.border),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Contacts section
  // ---------------------------------------------------------------------------

  Widget _buildContactsSection(
    BuildContext context,
    ContactsState contactsState,
  ) {
    if (contactsState.contacts.isEmpty) return const SizedBox.shrink();

    final serverUrl = ref.watch(serverUrlProvider);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'YOUR CONTACTS',
            style: Theme.of(
              context,
            ).textTheme.labelLarge?.copyWith(color: context.accent),
          ),
        ),
        ...contactsState.contacts.map((contact) {
          return ListTile(
            leading: buildAvatar(
              name: contact.username,
              radius: 20,
              imageUrl: contact.avatarUrl != null
                  ? '$serverUrl${contact.avatarUrl}'
                  : null,
            ),
            title: GestureDetector(
              onTap: () => UserProfileScreen.show(context, ref, contact.userId),
              child: Text(
                contact.displayName ?? contact.username,
                style: TextStyle(color: context.textPrimary),
              ),
            ),
            subtitle: contact.displayName != null
                ? Text(
                    '@${contact.username}',
                    style: TextStyle(color: context.textSecondary),
                  )
                : null,
            trailing: _buildMessageButton(contact.userId, contact.username),
          );
        }),
      ],
    );
  }

  Widget _buildMessageButton(String userId, String username) {
    return SizedBox(
      height: 32,
      width: 90,
      child: Material(
        color: context.accentLight,
        borderRadius: BorderRadius.circular(6),
        child: InkWell(
          borderRadius: BorderRadius.circular(6),
          onTap: _isStartingDm ? null : () => _messageContact(userId, username),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12),
            child: Center(
              child: Text(
                'Message',
                style: TextStyle(
                  color: context.accent,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState(ContactsState contactsState) {
    final visiblePending = contactsState.pendingRequests
        .where((c) => !_dismissedPending.contains(c.userId))
        .toList();

    if (contactsState.contacts.isNotEmpty || visiblePending.isNotEmpty) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.all(48),
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.people_outline, size: 48, color: context.textMuted),
            const SizedBox(height: 12),
            Text(
              'No contacts yet',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 15,
                fontWeight: FontWeight.w500,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Search for users above to add them',
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
          ],
        ),
      ),
    );
  }
}

// =============================================================================
// Search result card widget
// =============================================================================

class _SearchResultCard extends StatelessWidget {
  final _SearchUser user;
  final String? avatarImageUrl;
  final String? status; // 'contact', 'pending', or null
  final VoidCallback onAdd;
  final VoidCallback onTap;

  const _SearchResultCard({
    required this.user,
    required this.avatarImageUrl,
    required this.status,
    required this.onAdd,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Row(
          children: [
            buildAvatar(
              name: user.username,
              radius: 20,
              imageUrl: avatarImageUrl,
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    user.displayName ?? user.username,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    '@${user.username}',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
            _buildTrailing(context),
          ],
        ),
      ),
    );
  }

  Widget _buildTrailing(BuildContext context) {
    if (status == 'contact') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: context.accentLight,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'Contact',
          style: TextStyle(
            color: context.accent,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    if (status == 'pending') {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
        decoration: BoxDecoration(
          color: context.surfaceHover,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Text(
          'Pending',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 12,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    // No relationship -- show Add button.
    return SizedBox(
      height: 32,
      child: FilledButton.icon(
        onPressed: onAdd,
        icon: const Icon(Icons.person_add_outlined, size: 16),
        label: const Text('Add', style: TextStyle(fontSize: 13)),
        style: FilledButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 12),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
        ),
      ),
    );
  }
}

// =============================================================================
// Pending request tile with Accept + Decline
// =============================================================================

class _PendingRequestTile extends StatelessWidget {
  final Contact contact;
  final String serverUrl;
  final VoidCallback onAccept;
  final VoidCallback onDecline;

  const _PendingRequestTile({
    required this.contact,
    required this.serverUrl,
    required this.onAccept,
    required this.onDecline,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          buildAvatar(
            name: contact.username,
            radius: 20,
            imageUrl: contact.avatarUrl != null
                ? '$serverUrl${contact.avatarUrl}'
                : null,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  contact.displayName ?? contact.username,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 1),
                Text(
                  'Wants to connect',
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ),
          SizedBox(
            height: 32,
            child: OutlinedButton(
              onPressed: onDecline,
              style: OutlinedButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: const Text('Decline', style: TextStyle(fontSize: 12)),
            ),
          ),
          const SizedBox(width: 8),
          SizedBox(
            height: 32,
            child: FilledButton(
              onPressed: onAccept,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 12),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
              child: const Text('Accept', style: TextStyle(fontSize: 12)),
            ),
          ),
        ],
      ),
    );
  }
}
