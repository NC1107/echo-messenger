import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../widgets/avatar_utils.dart' show groupAvatarColor;
import '../widgets/echo_bottom_sheet.dart';
import '../widgets/empty_state.dart';

/// A public group returned by the discovery endpoint.
class _PublicGroup {
  final String id;
  final String name;
  final String? description;
  final int memberCount;
  bool joined;

  _PublicGroup({
    required this.id,
    required this.name,
    this.description,
    required this.memberCount,
    this.joined = false,
  });

  factory _PublicGroup.fromJson(Map<String, dynamic> json) {
    return _PublicGroup(
      id: json['id'] as String? ?? json['conversation_id'] as String? ?? '',
      name: (json['title'] ?? json['name']) as String? ?? 'Unnamed',
      description: (json['description'] ?? json['desc']) as String?,
      memberCount: json['member_count'] as int? ?? 0,
      joined: json['is_member'] as bool? ?? false,
    );
  }
}

class DiscoverGroupsScreen extends ConsumerStatefulWidget {
  /// Optional callback invoked when the user taps the "New group" FAB.
  /// When null the FAB is hidden.
  final VoidCallback? onCreateGroup;

  const DiscoverGroupsScreen({super.key, this.onCreateGroup});

  @override
  ConsumerState<DiscoverGroupsScreen> createState() =>
      _DiscoverGroupsScreenState();
}

class _DiscoverGroupsScreenState extends ConsumerState<DiscoverGroupsScreen> {
  static const _pageSize = 20;
  final _searchController = TextEditingController();
  Timer? _debounce;
  List<_PublicGroup> _groups = [];
  bool _isLoading = false;
  bool _isLoadingMore = false;
  bool _hasMore = true;
  int _offset = 0;
  String? _error;
  final Set<String> _joiningIds = {};

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchGroups('');
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _debounce?.cancel();
    super.dispose();
  }

  void _onSearchChanged(String query) {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 400), () {
      _searchGroups(query.trim());
    });
  }

  Future<void> _searchGroups(String query) async {
    setState(() {
      _isLoading = true;
      _error = null;
      _offset = 0;
      _hasMore = true;
      _groups = [];
    });

    await _fetchGroups(query);
  }

  Future<void> _loadMore() async {
    if (_isLoadingMore || !_hasMore) return;
    setState(() => _isLoadingMore = true);
    await _fetchGroups(_searchController.text.trim());
    if (mounted) setState(() => _isLoadingMore = false);
  }

  Future<void> _fetchGroups(String query) async {
    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;

    try {
      final params = <String, String>{
        'limit': '$_pageSize',
        'offset': '$_offset',
      };
      if (query.isNotEmpty) params['search'] = query;

      final uri = Uri.parse(
        '$serverUrl/api/groups/public',
      ).replace(queryParameters: params);
      final response = await http
          .get(
            uri,
            headers: {
              'Authorization': 'Bearer ${token ?? ""}',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200) {
        final body = jsonDecode(response.body);
        final List<dynamic> list = body is List
            ? body
            : (body['groups'] as List? ?? []);
        final newGroups = list
            .map((e) => _PublicGroup.fromJson(e as Map<String, dynamic>))
            .toList();
        setState(() {
          _groups.addAll(newGroups);
          _hasMore = newGroups.length >= _pageSize;
          _offset += newGroups.length;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Server returned ${response.statusCode}';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load groups';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _joinGroup(_PublicGroup group) async {
    setState(() => _joiningIds.add(group.id));

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;

    try {
      final response = await http
          .post(
            Uri.parse('$serverUrl/api/groups/${group.id}/join'),
            headers: {
              'Authorization': 'Bearer ${token ?? ""}',
              'Content-Type': 'application/json',
            },
          )
          .timeout(const Duration(seconds: 10));

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        setState(() {
          group.joined = true;
          _joiningIds.remove(group.id);
        });
        // Reload conversations so the new group appears
        ref.read(conversationsProvider.notifier).loadConversations();
      } else {
        setState(() => _joiningIds.remove(group.id));
        if (mounted) {
          ToastService.show(
            context,
            'Failed to join group (${response.statusCode})',
            type: ToastType.error,
          );
        }
      }
    } catch (e) {
      if (mounted) {
        setState(() => _joiningIds.remove(group.id));
        ToastService.show(
          context,
          'Failed to join group',
          type: ToastType.error,
        );
      }
    }
  }

  /// Show a bottom-sheet preview of a group with full details and a Join CTA.
  /// Lets users decide whether to join before committing.
  void _showGroupPreview(_PublicGroup group) {
    showEchoBottomSheet<void>(
      context,
      dragHandle: true,
      builder: (sheetCtx) {
        return Padding(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // Avatar + name
              Row(
                children: [
                  Container(
                    width: 56,
                    height: 56,
                    decoration: BoxDecoration(
                      color: groupAvatarColor(group.name),
                      borderRadius: BorderRadius.circular(28),
                    ),
                    alignment: Alignment.center,
                    child: const Icon(
                      Icons.group,
                      size: 28,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 14),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 2),
                        Row(
                          children: [
                            Icon(
                              Icons.public,
                              size: 13,
                              color: context.textMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              'Public group',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 12,
                              ),
                            ),
                            const SizedBox(width: 10),
                            Icon(
                              Icons.people_outline,
                              size: 13,
                              color: context.textMuted,
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${group.memberCount} '
                              'member${group.memberCount == 1 ? '' : 's'}',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ),
              if (group.description != null &&
                  group.description!.isNotEmpty) ...[
                const SizedBox(height: 18),
                Text(
                  'About',
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.6,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  group.description!,
                  maxLines: 4,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: context.textSecondary,
                    fontSize: 14,
                    height: 1.45,
                  ),
                ),
              ],
              const SizedBox(height: 24),
              // Join CTA — disabled when already joined.
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: group.joined
                      ? null
                      : () {
                          Navigator.of(sheetCtx).pop();
                          _joinGroup(group);
                        },
                  style: FilledButton.styleFrom(
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    group.joined ? 'Already joined' : 'Join group',
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: context.mainBg,
      floatingActionButton: widget.onCreateGroup != null
          ? Semantics(
              label: 'Create new group',
              button: true,
              child: FloatingActionButton(
                onPressed: widget.onCreateGroup,
                tooltip: 'Create new group',
                child: const Icon(Icons.group_add_outlined),
              ),
            )
          : null,
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
              child: Row(
                children: [
                  if (canPop)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: IconButton(
                        icon: Icon(
                          Icons.arrow_back,
                          color: context.textSecondary,
                        ),
                        onPressed: () => Navigator.of(context).pop(),
                      ),
                    ),
                  Text(
                    'Discover',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
              child: Text(
                'Public groups. Server-stored — open a DM for end-to-end encryption.',
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
            ),
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: TextField(
                controller: _searchController,
                style: TextStyle(color: context.textPrimary, fontSize: 14),
                decoration: InputDecoration(
                  hintText: 'Search public groups',
                  hintStyle: TextStyle(color: context.textMuted, fontSize: 14),
                  prefixIcon: Icon(
                    Icons.search,
                    size: 20,
                    color: context.textMuted,
                  ),
                  filled: true,
                  fillColor: context.cardRowBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide.none,
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                    borderSide: BorderSide(color: context.accent, width: 1),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 12,
                  ),
                ),
                onChanged: _onSearchChanged,
              ),
            ),
            Expanded(child: _buildContent()),
          ],
        ),
      ),
    );
  }

  Widget _buildContent() {
    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: context.accent, strokeWidth: 2),
      );
    }
    if (_error != null) {
      return _buildErrorState();
    }
    if (_groups.isEmpty) {
      return _buildEmptyState();
    }
    return _buildGroupList();
  }

  Widget _buildErrorState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.error_outline, size: 40, color: context.textMuted),
          const SizedBox(height: 12),
          Text(
            _error!,
            style: TextStyle(color: context.textSecondary, fontSize: 14),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => _searchGroups(_searchController.text.trim()),
            child: const Text('Retry'),
          ),
        ],
      ),
    );
  }

  Widget _buildEmptyState() {
    return const EmptyState(
      icon: Icons.travel_explore,
      title: 'No public groups found',
      body: 'Try a different search, or check back later.',
    );
  }

  Widget _buildGroupList() {
    return ListView.builder(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      itemCount: _groups.length + (_hasMore ? 1 : 0),
      itemBuilder: (context, index) {
        if (index >= _groups.length) {
          return _buildLoadMoreItem();
        }
        final group = _groups[index];
        return _GroupDiscoveryItem(
          group: group,
          isJoining: _joiningIds.contains(group.id),
          onJoin: () => _joinGroup(group),
          onTap: () => _showGroupPreview(group),
        );
      },
    );
  }

  Widget _buildLoadMoreItem() {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 16),
      child: Center(
        child: _isLoadingMore
            ? SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  color: context.accent,
                  strokeWidth: 2,
                ),
              )
            : TextButton(onPressed: _loadMore, child: const Text('Load more')),
      ),
    );
  }
}

class _GroupDiscoveryItem extends StatelessWidget {
  final _PublicGroup group;
  final bool isJoining;
  final VoidCallback onJoin;
  final VoidCallback? onTap;

  const _GroupDiscoveryItem({
    required this.group,
    required this.isJoining,
    required this.onJoin,
    this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 12),
      child: Semantics(
        label: 'discover group ${group.name} — tap to preview',
        button: true,
        child: Material(
          color: context.cardRowBg,
          borderRadius: BorderRadius.circular(14),
          clipBehavior: Clip.antiAlias,
          child: InkWell(
            onTap: onTap,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 16),
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final isNarrow = constraints.maxWidth < 400;
                  final joinButton = _buildJoinAffordance(context);
                  final nameColumn = Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          group.name,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                          ),
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                        ),
                        const SizedBox(height: 4),
                        Row(
                          children: [
                            Container(
                              width: 6,
                              height: 6,
                              decoration: const BoxDecoration(
                                color: EchoTheme.online,
                                shape: BoxShape.circle,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Text(
                              '${_onlineCount(group)}',
                              style: const TextStyle(
                                color: EchoTheme.online,
                                fontSize: 12,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '${group.memberCount} member${group.memberCount == 1 ? '' : 's'}',
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                        if (group.description != null &&
                            group.description!.isNotEmpty) ...[
                          const SizedBox(height: 6),
                          Text(
                            group.description!,
                            style: TextStyle(
                              color: context.textSecondary,
                              fontSize: 13,
                              height: 1.35,
                            ),
                            maxLines: 2,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ],
                        if (isNarrow) ...[
                          const SizedBox(height: 10),
                          joinButton,
                        ],
                      ],
                    ),
                  );

                  return ConstrainedBox(
                    constraints: const BoxConstraints(minHeight: 68),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // Group avatar — bright solid background with white glyph,
                        // deterministically picked from the group palette.
                        Container(
                          width: 44,
                          height: 44,
                          decoration: BoxDecoration(
                            color: groupAvatarColor(group.name),
                            borderRadius: BorderRadius.circular(22),
                          ),
                          alignment: Alignment.center,
                          child: const Icon(
                            Icons.group,
                            size: 22,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 12),
                        // Name + stats + description (+ button on narrow)
                        nameColumn,
                        if (!isNarrow) ...[
                          const SizedBox(width: 12),
                          joinButton,
                        ],
                      ],
                    ),
                  );
                },
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// Builds the Join / Joined affordance widget, shared between the row
  /// layout (wide screens) and the stacked layout (narrow screens).
  Widget _buildJoinAffordance(BuildContext context) {
    if (group.joined) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
        decoration: BoxDecoration(
          color: context.surfaceHover,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Text(
          'Joined',
          style: TextStyle(
            color: context.textMuted,
            fontSize: 13,
            fontWeight: FontWeight.w600,
          ),
        ),
      );
    }
    return FilledButton(
      onPressed: isJoining ? null : onJoin,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
        minimumSize: Size.zero,
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
      child: isJoining
          ? const SizedBox(
              width: 16,
              height: 16,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                color: Colors.white,
              ),
            )
          : const Text(
              'Join',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
            ),
    );
  }

  /// Best-effort online count for the green-dot indicator. The discovery
  /// API doesn't currently surface live presence per group, so this is a
  /// rough estimate (10% of members capped at 99). When the backend adds a
  /// real count, swap this for the field.
  int _onlineCount(_PublicGroup g) {
    if (g.memberCount <= 0) return 0;
    final est = (g.memberCount * 0.1).ceil();
    return est.clamp(1, 99);
  }
}
