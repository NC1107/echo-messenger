import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../models/conversation.dart';
import '../services/clipboard_service.dart';
import '../services/toast_service.dart';
import '../services/upload_client.dart';
import '../theme/echo_theme.dart';
import '../providers/auth_provider.dart';
import '../providers/channels_provider.dart';
import '../models/contact.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/media_ticket_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/user_presence_provider.dart';
import '../utils/fuzzy_score.dart';
import '../utils/presence.dart';
import '../widgets/avatar_crop_dialog.dart';
import '../widgets/avatar_utils.dart' show buildAvatar, resolveAvatarUrl;
import '../widgets/channel_editor_dialog.dart';
import '../widgets/confirm_dialog.dart';
import '../widgets/member_role.dart';
import '../widgets/user_avatar.dart';
import '../widgets/context_menu/actions/member_actions_registry.dart';
import '../widgets/context_menu/echo_context_menu.dart';
import '../widgets/profile_sheets.dart';

part 'group_info_screen/parts/header_section.dart';
part 'group_info_screen/parts/members_section.dart';
part 'group_info_screen/parts/channels_section.dart';
part 'group_info_screen/parts/invite_section.dart';
part 'group_info_screen/parts/disappearing_messages.dart';
part 'group_info_screen/parts/danger_actions.dart';
part 'group_info_screen/parts/add_member_dialog.dart';

const _kJsonHeaders = {'Content-Type': 'application/json'};
const _kGroupInfoTitle = 'Group Info';

class GroupInfoScreen extends ConsumerStatefulWidget {
  final String conversationId;

  const GroupInfoScreen({super.key, required this.conversationId});

  /// Open the group info overlay. Delegates to [showGroupProfileSheet] which
  /// chooses dialog (desktop) or bottom sheet (mobile) automatically.
  static void show(BuildContext context, WidgetRef ref, String conversationId) {
    showGroupProfileSheet(context, ref, conversationId);
  }

  @override
  ConsumerState<GroupInfoScreen> createState() => _GroupInfoScreenState();
}

class _GroupInfoScreenState extends ConsumerState<GroupInfoScreen> {
  Conversation? _conversation;
  bool _isLoading = true;
  bool _isEditingName = false;
  bool _isEditingDescription = false;
  bool _isGeneratingInvite = false;
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

  @override
  void dispose() {
    _nameController.dispose();
    _descriptionController.dispose();
    super.dispose();
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

  // ---------------------------------------------------------------------------
  // Build
  // ---------------------------------------------------------------------------

  /// Back affordance. The group-info screen is reached both as a dismissible
  /// sheet (canPop) AND as a full page via `context.go('/group-info/:id')`
  /// (which replaces the stack, so there's nothing to pop) — the latter left
  /// the user stranded with no exit. Pop when we can, else fall back to the
  /// conversation.
  Widget _backButton(BuildContext context) => IconButton(
    icon: const Icon(Icons.arrow_back),
    tooltip: 'Back',
    onPressed: () => context.canPop()
        ? context.pop()
        : context.go('/home?conversation=${widget.conversationId}'),
  );

  Widget _buildLoadingState(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(_kGroupInfoTitle),
        leading: _backButton(context),
      ),
      body: const Center(child: CircularProgressIndicator()),
    );
  }

  Widget _buildErrorState(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text(_kGroupInfoTitle),
        leading: _backButton(context),
      ),
      body: const Center(child: Text('Could not load group information')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final myUserId = ref.watch(authProvider).userId ?? '';

    if (_isLoading) return _buildLoadingState(context);
    if (_conversation == null) return _buildErrorState(context);

    final conv = _conversation!;
    final displayName = conv.displayName(myUserId);
    final myMember = conv.members
        .where((m) => m.userId == myUserId)
        .firstOrNull;
    final myRole = myMember?.role ?? 'member';
    final isOwnerOrAdmin = myRole == 'owner' || myRole == 'admin';
    final viewerIsOwner = myRole == 'owner';

    return Scaffold(
      appBar: AppBar(
        title: const Text(_kGroupInfoTitle),
        leading: _backButton(context),
      ),
      body: LayoutBuilder(
        builder: (context, constraints) {
          // Wide (split-pane / desktop): 2-column layout — avatar+identity
          // on the left, content (description, members, admin) on the right.
          // Narrow (mobile / collapsed sidebar): keep the single mobile-style
          // stacked column inside a 600px-max content well.
          final isWide = constraints.maxWidth >= 800;
          if (isWide) {
            return _buildWideLayout(
              conv: conv,
              displayName: displayName,
              myUserId: myUserId,
              myRole: myRole,
              isOwnerOrAdmin: isOwnerOrAdmin,
              viewerIsOwner: viewerIsOwner,
            );
          }
          return _buildNarrowLayout(
            conv: conv,
            displayName: displayName,
            myUserId: myUserId,
            myRole: myRole,
            isOwnerOrAdmin: isOwnerOrAdmin,
            viewerIsOwner: viewerIsOwner,
          );
        },
      ),
    );
  }

  Widget _buildNarrowLayout({
    required Conversation conv,
    required String displayName,
    required String myUserId,
    required String myRole,
    required bool isOwnerOrAdmin,
    required bool viewerIsOwner,
  }) {
    return SafeArea(
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            padding: const EdgeInsets.symmetric(horizontal: 16),
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
                viewerIsOwner: viewerIsOwner,
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

  Widget _buildWideLayout({
    required Conversation conv,
    required String displayName,
    required String myUserId,
    required String myRole,
    required bool isOwnerOrAdmin,
    required bool viewerIsOwner,
  }) {
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 1100),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left column: identity + member count + action buttons.
              SizedBox(
                width: 320,
                child: SingleChildScrollView(
                  child: Column(
                    children: [
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
                      const SizedBox(height: 24),
                      ..._buildActionButtons(myRole: myRole),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 32),
              // Right column: description + members + admin sections.
              Expanded(
                child: ListView(
                  children: [
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
                      viewerIsOwner: viewerIsOwner,
                    ),
                    if (isOwnerOrAdmin) ..._buildChannelsSection(),
                    if (isOwnerOrAdmin) _buildDisappearingSection(),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
