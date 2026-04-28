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
  const DiscoverGroupsScreen({super.key});

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

  @override
  Widget build(BuildContext context) {
    final canPop = Navigator.of(context).canPop();
    return Scaffold(
      backgroundColor: context.mainBg,
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
                'Public groups. Join with one tap — your messages stay encrypted.',
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
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.explore_outlined,
            size: 48,
            color: context.textMuted.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            'No public groups found',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 15,
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Try a different search or create a public group',
            style: TextStyle(color: context.textMuted, fontSize: 13),
          ),
        ],
      ),
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

  const _GroupDiscoveryItem({
    required this.group,
    required this.isJoining,
    required this.onJoin,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.cardRowBg,
        borderRadius: BorderRadius.circular(14),
      ),
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
            child: const Icon(Icons.group, size: 22, color: Colors.white),
          ),
          const SizedBox(width: 12),
          // Name + stats + description
          Expanded(
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
                  maxLines: 1,
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
                      style: TextStyle(
                        color: EchoTheme.online,
                        fontSize: 12,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '${group.memberCount} member${group.memberCount == 1 ? '' : 's'}',
                      style: TextStyle(color: context.textMuted, fontSize: 12),
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
              ],
            ),
          ),
          const SizedBox(width: 12),
          // Join / Joined affordance
          if (group.joined)
            Container(
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
            )
          else
            FilledButton(
              onPressed: isJoining ? null : onJoin,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 18,
                  vertical: 10,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
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
                      style: TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
        ],
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
