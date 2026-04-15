import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';

import '../models/conversation.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../widgets/avatar_utils.dart' show buildAvatar, resolveAvatarUrl;

const _kJsonHeaders = {'Content-Type': 'application/json'};
const _kGroupInfoTitle = 'Group Info';

class GroupInfoScreen extends ConsumerStatefulWidget {
  final String conversationId;

  const GroupInfoScreen({super.key, required this.conversationId});

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  Conversation? _conversation;
  bool _isLoading = true;
  bool _isEditingName = false;
  bool _isEditingDescription = false;
  int? _disappearingTtl; // null = off
  final _nameController = TextEditingController();
  final _descriptionController = TextEditingController();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadGroupInfo();
      ref.read(channelsProvider.notifier).loadChannels(widget.conversationId);
    });
  }

  Future<void> _loadGroupInfo({bool force = false}) async {
    if (!force) {
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
    }

    // Otherwise fetch from server
    try {
      final serverUrl = ref.read(serverUrlProvider);
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse(
                '$serverUrl/api/conversations/${widget.conversationId}',
              ),
              headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
            ),
          );

      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _conversation = Conversation.fromJson(data);
          _disappearingTtl = data['disappearing_ttl_seconds'] as int?;
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() => _isLoading = false);
      }
    } catch (e) {
      debugPrint('[GroupInfo] _loadGroupInfo failed: $e');
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
      ToastService.show(
        context,
        'All contacts are already in this group',
        type: ToastType.info,
      );
      return;
    }

    final selected = await showDialog<String>(
      context: context,
      builder: (dialogContext) => SimpleDialog(
        title: const Text('Add Member'),
        children: available.map((contact) {
          final serverUrl = ref.read(serverUrlProvider);
          return SimpleDialogOption(
            onPressed: () => Navigator.pop(dialogContext, contact.userId),
            child: ListTile(
              leading: buildAvatar(
                name: contact.username,
                radius: 20,
                imageUrl: resolveAvatarUrl(contact.avatarUrl, serverUrl),
              ),
              title: Text(contact.displayName ?? contact.username),
            ),
          );
        }).toList(),
      ),
    );

    if (selected == null) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await http.post(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}/members'),
        headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
        body: jsonEncode({'user_id': selected}),
      );

      if (response.statusCode == 200 || response.statusCode == 201) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        await _loadGroupInfo(force: true);
        if (mounted) {
          ToastService.show(context, 'Member added', type: ToastType.success);
        }
      }
    } catch (e) {
      debugPrint('[GroupInfo] _addMember failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to add member',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _deleteGroup() async {
    final groupName = _conversation?.name ?? 'this group';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Group'),
        content: Text(
          'Are you sure you want to delete "$groupName"? '
          'This will permanently remove all messages and members. '
          'This action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final token = ref.read(authProvider).token;
    if (token == null) return;
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await http.delete(
        Uri.parse('$serverUrl/api/groups/${widget.conversationId}'),
        headers: {'Authorization': 'Bearer $token'},
      );
      if (response.statusCode == 200 && mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) {
          Navigator.pop(context);
          ToastService.show(context, 'Group deleted', type: ToastType.success);
        }
      } else if (mounted) {
        ToastService.show(
          context,
          'Only the group owner can delete this group',
          type: ToastType.error,
        );
      }
    } catch (e) {
      debugPrint('[GroupInfo] _deleteGroup failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to delete group',
          type: ToastType.error,
        );
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
        headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
      );

      if ((response.statusCode == 200 || response.statusCode == 204) &&
          mounted) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) context.go('/home');
      }
    } catch (e) {
      debugPrint('[GroupInfo] _leaveGroup failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to leave group',
          type: ToastType.error,
        );
      }
    }
  }

  Future<void> _kickMember(ConversationMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Remove Member'),
        content: Text('Remove ${member.username} from this group?'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

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

  Future<void> _banMember(ConversationMember member) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Ban Member'),
        content: Text(
          'Ban ${member.username} from this group? '
          'They will not be able to rejoin.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Ban'),
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
        await _loadGroupInfo();
        await ref.read(conversationsProvider.notifier).loadConversations();
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
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    if (token == null) return;

    final uri = Uri.parse(
      '$serverUrl/api/groups/${widget.conversationId}/avatar',
    );
    final request = http.MultipartRequest('PUT', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(
        http.MultipartFile.fromBytes(
          'avatar',
          file.bytes!,
          filename: file.name,
          contentType: MediaType('image', 'png'),
        ),
      );

    try {
      final streamedResponse = await request.send();
      // Drain the response body to close the stream.
      await streamedResponse.stream.bytesToString();
      if (!mounted) return;

      if (streamedResponse.statusCode == 200) {
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
          'Failed to upload avatar (${streamedResponse.statusCode})',
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

  Future<void> _showAddChannelDialog() async {
    final nameController = TextEditingController();
    String selectedKind = 'text';

    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          title: const Text('Add Channel'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              TextField(
                controller: nameController,
                autofocus: true,
                decoration: const InputDecoration(
                  labelText: 'Channel name',
                  hintText: 'e.g. general',
                ),
              ),
              const SizedBox(height: 16),
              DropdownButtonFormField<String>(
                initialValue: selectedKind,
                decoration: const InputDecoration(labelText: 'Type'),
                items: const [
                  DropdownMenuItem(value: 'text', child: Text('Text')),
                  DropdownMenuItem(value: 'voice', child: Text('Voice')),
                ],
                onChanged: (v) {
                  if (v != null) setDialogState(() => selectedKind = v);
                },
              ),
            ],
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.pop(dialogContext),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () {
                final name = nameController.text.trim();
                if (name.isNotEmpty) {
                  Navigator.pop(dialogContext, {
                    'name': name,
                    'kind': selectedKind,
                  });
                }
              },
              child: const Text('Create'),
            ),
          ],
        ),
      ),
    );

    nameController.dispose();
    if (result == null) return;

    final success = await ref
        .read(channelsProvider.notifier)
        .createChannel(widget.conversationId, result['name']!, result['kind']!);
    if (mounted) {
      ToastService.show(
        context,
        success ? 'Channel created' : 'Failed to create channel',
        type: success ? ToastType.success : ToastType.error,
      );
    }
  }

  Future<void> _deleteChannel(String channelId, String channelName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Channel'),
        content: Text('Delete channel "$channelName"? This cannot be undone.'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    final success = await ref
        .read(channelsProvider.notifier)
        .deleteChannel(widget.conversationId, channelId);
    if (mounted) {
      ToastService.show(
        context,
        success ? 'Channel deleted' : 'Failed to delete channel',
        type: success ? ToastType.success : ToastType.error,
      );
    }
  }

  // ---------------------------------------------------------------------------
  // Extracted build helpers
  // ---------------------------------------------------------------------------

  Widget _buildLoadingState() {
    return Scaffold(
      appBar: AppBar(title: const Text(_kGroupInfoTitle)),
      body: const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildErrorState() {
    return Scaffold(
      appBar: AppBar(title: const Text(_kGroupInfoTitle)),
      body: const Center(child: Text('Could not load group information')),
    );
  }

  Widget _buildGroupAvatar({required bool isOwnerOrAdmin, String? iconUrl}) {
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    final hasIcon = iconUrl != null && iconUrl.isNotEmpty;

    Widget avatar;
    if (hasIcon) {
      final fullUrl = token != null && token.isNotEmpty
          ? '$serverUrl$iconUrl?token=$token'
          : '$serverUrl$iconUrl';
      avatar = CircleAvatar(
        radius: 40,
        backgroundColor: Theme.of(context).colorScheme.tertiary,
        backgroundImage: NetworkImage(fullUrl),
        onBackgroundImageError: (_, _) {},
        child: null,
      );
    } else {
      avatar = CircleAvatar(
        radius: 40,
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
              onPressed: _saveGroupName,
            ),
            IconButton(
              icon: const Icon(Icons.close),
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
    return Center(
      child: Text(
        '$count member${count == 1 ? '' : 's'}',
        style: Theme.of(context).textTheme.bodyMedium?.copyWith(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
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
                  onPressed: _saveDescription,
                ),
                IconButton(
                  icon: const Icon(Icons.close),
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

  List<Widget> _buildRoleBadge(String role) {
    if (role == 'owner') {
      return [
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: Theme.of(
              context,
            ).colorScheme.primary.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(
            'Owner',
            style: TextStyle(
              fontSize: 11,
              color: Theme.of(context).colorScheme.primary,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ];
    }
    if (role == 'admin') {
      return [
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
          decoration: BoxDecoration(
            color: EchoTheme.warning.withValues(alpha: 0.15),
            borderRadius: BorderRadius.circular(4),
          ),
          child: const Text(
            'Admin',
            style: TextStyle(
              fontSize: 11,
              color: EchoTheme.warning,
              fontWeight: FontWeight.w600,
            ),
          ),
        ),
      ];
    }
    return [];
  }

  Widget? _buildMemberActions({
    required ConversationMember member,
    required bool isOwnerOrAdmin,
    required bool isMe,
    required String role,
  }) {
    if (!isOwnerOrAdmin || isMe || role == 'owner') return null;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        IconButton(
          icon: Icon(
            Icons.person_remove_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          tooltip: 'Kick member',
          onPressed: () => _kickMember(member),
        ),
        IconButton(
          icon: Icon(
            Icons.block_outlined,
            size: 18,
            color: Theme.of(context).colorScheme.error,
          ),
          tooltip: 'Ban member',
          onPressed: () => _banMember(member),
        ),
      ],
    );
  }

  Widget _buildMemberTile({
    required ConversationMember member,
    required String myUserId,
    required bool isOwnerOrAdmin,
  }) {
    final serverUrl = ref.read(serverUrlProvider);
    final isMe = member.userId == myUserId;
    final role = member.role ?? 'member';
    return ListTile(
      leading: buildAvatar(
        name: member.username,
        radius: 20,
        imageUrl: resolveAvatarUrl(member.avatarUrl, serverUrl),
      ),
      title: Row(children: [Text(member.username), ..._buildRoleBadge(role)]),
      subtitle: isMe ? const Text('You') : null,
      trailing: _buildMemberActions(
        member: member,
        isOwnerOrAdmin: isOwnerOrAdmin,
        isMe: isMe,
        role: role,
      ),
    );
  }

  List<Widget> _buildMembersSection({
    required Conversation conv,
    required String myUserId,
    required bool isOwnerOrAdmin,
  }) {
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
      ...conv.members.map(
        (member) => _buildMemberTile(
          member: member,
          myUserId: myUserId,
          isOwnerOrAdmin: isOwnerOrAdmin,
        ),
      ),
    ];
  }

  List<Widget> _buildChannelsSection() {
    return [
      const Divider(),
      Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
        child: Row(
          children: [
            Text(
              'Channels',
              style: Theme.of(context).textTheme.labelLarge?.copyWith(
                color: Theme.of(context).colorScheme.primary,
              ),
            ),
            const Spacer(),
            IconButton(
              icon: const Icon(Icons.add_outlined),
              tooltip: 'Add channel',
              onPressed: _showAddChannelDialog,
            ),
          ],
        ),
      ),
      _buildChannelsList(),
    ];
  }

  Widget _buildChannelsList() {
    final channelsState = ref.watch(channelsProvider);
    final channels = channelsState.channelsFor(widget.conversationId);
    if (channels.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: Text(
          channelsState.isLoadingConversation(widget.conversationId)
              ? 'Loading channels...'
              : 'No channels',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(
            color: Theme.of(context).colorScheme.onSurfaceVariant,
          ),
        ),
      );
    }
    return Column(
      children: channels.map((channel) {
        return ListTile(
          leading: Icon(
            channel.isText ? Icons.tag : Icons.headset_mic_outlined,
            size: 20,
          ),
          title: Text(channel.name),
          subtitle: Text(channel.kind),
          trailing: IconButton(
            icon: Icon(
              Icons.delete_outline,
              size: 18,
              color: Theme.of(context).colorScheme.error,
            ),
            tooltip: 'Delete channel',
            onPressed: () => _deleteChannel(channel.id, channel.name),
          ),
        );
      }).toList(),
    );
  }

  List<Widget> _buildActionButtons({required String myRole}) {
    return [
      const Divider(),
      const SizedBox(height: 16),
      Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16),
        child: OutlinedButton.icon(
          onPressed: () {
            final link =
                'https://echo-messenger.us/#/join/${widget.conversationId}';
            Clipboard.setData(ClipboardData(text: link));
            ToastService.show(
              context,
              'Invite link copied to clipboard',
              type: ToastType.success,
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
      if (myRole == 'owner') ...[
        const SizedBox(height: 8),
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: FilledButton.icon(
            onPressed: _deleteGroup,
            icon: const Icon(Icons.delete_forever_outlined),
            label: const Text('Delete Group'),
            style: FilledButton.styleFrom(
              backgroundColor: Theme.of(context).colorScheme.error,
            ),
          ),
        ),
      ],
      const SizedBox(height: 24),
    ];
  }

  // ---------------------------------------------------------------------------
  // Disappearing messages
  // ---------------------------------------------------------------------------

  static const _kTtlOptions = [
    (label: 'Off', seconds: null),
    (label: '30 seconds', seconds: 30),
    (label: '5 minutes', seconds: 300),
    (label: '1 hour', seconds: 3600),
    (label: '1 day', seconds: 86400),
    (label: '1 week', seconds: 604800),
  ];

  String _ttlLabel(int? seconds) {
    for (final opt in _kTtlOptions) {
      if (opt.seconds == seconds) return opt.label;
    }
    return '$seconds seconds';
  }

  Future<void> _setDisappearingTtl(int? seconds) async {
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.put(
              Uri.parse(
                '$serverUrl/api/conversations/${widget.conversationId}/disappearing',
              ),
              headers: {'Authorization': 'Bearer $token', ..._kJsonHeaders},
              body: jsonEncode({'ttl_seconds': seconds}),
            ),
          );
      if (!mounted) return;
      if (response.statusCode == 200) {
        setState(() => _disappearingTtl = seconds);
        ToastService.show(
          context,
          seconds == null
              ? 'Disappearing messages turned off'
              : 'Messages disappear after ${_ttlLabel(seconds)}',
          type: ToastType.success,
        );
      } else {
        ToastService.show(
          context,
          'Failed to update disappearing messages',
          type: ToastType.error,
        );
      }
    } catch (e) {
      debugPrint('[GroupInfo] _setDisappearingTtl failed: $e');
      if (mounted) {
        ToastService.show(
          context,
          'Failed to update disappearing messages',
          type: ToastType.error,
        );
      }
    }
  }

  Widget _buildDisappearingSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Divider(),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
          child: Text(
            'Disappearing Messages',
            style: Theme.of(context).textTheme.labelMedium?.copyWith(
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
        ),
        ListTile(
          leading: const Icon(Icons.timer_outlined),
          title: const Text('Auto-delete after'),
          trailing: DropdownButton<int?>(
            value: _disappearingTtl,
            underline: const SizedBox.shrink(),
            items: _kTtlOptions.map((opt) {
              return DropdownMenuItem<int?>(
                value: opt.seconds,
                child: Text(opt.label),
              );
            }).toList(),
            onChanged: (v) => _setDisappearingTtl(v),
          ),
        ),
        const SizedBox(height: 4),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final myUserId = ref.watch(authProvider).userId ?? '';

    if (_isLoading) return _buildLoadingState();
    if (_conversation == null) return _buildErrorState();

    final conv = _conversation!;
    final displayName = conv.displayName(myUserId);
    final myMember = conv.members
        .where((m) => m.userId == myUserId)
        .firstOrNull;
    final myRole = myMember?.role ?? 'member';
    final isOwnerOrAdmin = myRole == 'owner' || myRole == 'admin';

    return Scaffold(
      appBar: AppBar(title: const Text(_kGroupInfoTitle)),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            children: [
              const SizedBox(height: 24),
              _buildGroupAvatar(
                isOwnerOrAdmin: isOwnerOrAdmin,
                iconUrl: conv.iconUrl,
              ),
              const SizedBox(height: 16),
              _buildGroupNameSection(
                displayName: displayName,
                isOwnerOrAdmin: isOwnerOrAdmin,
              ),
              _buildMemberCount(conv.members.length),
              const SizedBox(height: 16),
              const Divider(),
              _buildDescriptionSection(
                conv: conv,
                isOwnerOrAdmin: isOwnerOrAdmin,
              ),
              const SizedBox(height: 8),
              const Divider(),
              ..._buildMembersSection(
                conv: conv,
                myUserId: myUserId,
                isOwnerOrAdmin: isOwnerOrAdmin,
              ),
              if (isOwnerOrAdmin) ..._buildChannelsSection(),
              if (isOwnerOrAdmin) _buildDisappearingSection(),
              ..._buildActionButtons(myRole: myRole),
            ],
          ),
        ),
      ),
    );
  }
}
