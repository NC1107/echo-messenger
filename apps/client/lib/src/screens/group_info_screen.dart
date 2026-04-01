import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';

class GroupInfoScreen extends ConsumerStatefulWidget {
  final String conversationId;

  const GroupInfoScreen({super.key, required this.conversationId});

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  Conversation? _conversation;
  bool _isLoading = true;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadGroupInfo();
    });
  }

  Future<void> _loadGroupInfo() async {
    // Try to find the conversation in the existing state first
    final conversations = ref.read(conversationsProvider).conversations;
    final existing = conversations
        .where((c) => c.id == widget.conversationId)
        .firstOrNull;

    if (existing != null) {
      setState(() {
        _conversation = existing;
        _isLoading = false;
      });
      return;
    }

    // Otherwise fetch from server
    final token = ref.read(authProvider).token;
    if (token == null) return;

    try {
      final serverUrl = ref.read(serverUrlProvider);
      final response = await http.get(
        Uri.parse('$serverUrl/api/conversations/${widget.conversationId}'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _conversation = Conversation.fromJson(data);
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (_) {
      if (mounted) setState(() => _isLoading = false);
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
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('All contacts are already in this group')),
      );
      return;
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Add Member'),
        children: available
            .map(
              (contact) => SimpleDialogOption(
                onPressed: () => Navigator.pop(dialogContext, contact.userId),
                child: ListTile(
                  leading: CircleAvatar(
                    child: Text(contact.username[0].toUpperCase()),
                  ),
                  title: Text(contact.displayName ?? contact.username),
                ),
              ),
            )
            .toList(),
      ),
    );

    if (selected == null) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}/members'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
        body: jsonEncode({'user_id': selected}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        await _loadGroupInfo();
        if (mounted) {
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Member added')));
        }
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to add member')));
      }
    }
  }

  Future<void> _leaveGroup() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Leave Group'),
        content: const Text('Are you sure you want to leave this group?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Leave'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}/leave'),
        headers: {
          'Authorization': 'Bearer $token',
          'Content-Type': 'application/json',
        },
      );

      if ((response.statusCode == 200 || response.statusCode == 204) &&
          mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) context.go('/home');
      }
    } catch (_) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('Failed to leave group')));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final myUserId = ref.watch(authProvider).userId ?? '';

    if (_isLoading) {
      return Scaffold(
        appBar: AppBar(title: const Text('Group Info')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    if (_conversation == null) {
      return Scaffold(
        appBar: AppBar(title: const Text('Group Info')),
        body: const Center(child: Text('Could not load group information')),
      );
    }

    final conv = _conversation!;
    final displayName = conv.displayName(myUserId);

    return Scaffold(
      appBar: AppBar(title: const Text('Group Info')),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            children: [
              const SizedBox(height: 24),
              Center(
                child: CircleAvatar(
                  radius: 40,
                  backgroundColor: Theme.of(context).colorScheme.tertiary,
                  child: const Icon(Icons.group_outlined, size: 40),
                ),
              ),
              const SizedBox(height: 16),
              Center(
                child: Text(
                  displayName,
                  style: Theme.of(context).textTheme.headlineSmall,
                ),
              ),
              Center(
                child: Text(
                  '${conv.members.length} members',
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.grey),
                ),
              ),
              const SizedBox(height: 24),
              const Divider(),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                child: Row(
                  children: [
                    Text(
                      'Members',
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
              ...conv.members.map(
                (member) => ListTile(
                  leading: CircleAvatar(
                    child: Text(member.username[0].toUpperCase()),
                  ),
                  title: Text(member.username),
                  subtitle: member.userId == myUserId
                      ? const Text('You')
                      : null,
                ),
              ),
              const Divider(),
              const SizedBox(height: 16),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: () {
                    final link =
                        'https://echo-messenger.us/#/join/${widget.conversationId}';
                    Clipboard.setData(ClipboardData(text: link));
                    ScaffoldMessenger.of(context).showSnackBar(
                      const SnackBar(
                        content: Text('Invite link copied to clipboard'),
                      ),
                    );
                  },
                  icon: const Icon(Icons.link_outlined),
                  label: const Text('Copy Invite Link'),
                ),
              ),
              const SizedBox(height: 12),
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: OutlinedButton.icon(
                  onPressed: _leaveGroup,
                  icon: const Icon(Icons.logout_outlined),
                  label: const Text('Leave Group'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: Theme.of(context).colorScheme.error,
                  ),
                ),
              ),
              const SizedBox(height: 24),
            ],
          ),
        ),
      ),
    );
  }
}
