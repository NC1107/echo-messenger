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
    return Scaffold(
      backgroundColor: context.mainBg,
      appBar: AppBar(
        backgroundColor: context.sidebarBg,
        title: Text(
          'Discover Groups',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: Column(
        children: [
          // Search bar
          Padding(
            padding: const EdgeInsets.all(16),
            child: TextField(
              controller: _searchController,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                hintText: 'Search public groups...',
                prefixIcon: Icon(Icons.search, size: 20),
              ),
              onChanged: _onSearchChanged,
            ),
          ),
          // Content
          Expanded(
            child: _isLoading
                ? Center(
                    child: CircularProgressIndicator(
                      color: context.accent,
                      strokeWidth: 2,
                    ),
                  )
                : _error != null
                ? Center(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.error_outline,
                          size: 40,
                          color: context.textMuted,
                        ),
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          style: TextStyle(
                            color: context.textSecondary,
                            fontSize: 14,
                          ),
                        ),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () =>
                              _searchGroups(_searchController.text.trim()),
                          child: const Text('Retry'),
                        ),
                      ],
                    ),
                  )
                : _groups.isEmpty
                ? Center(
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
                          style: TextStyle(
                            color: context.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: _groups.length + (_hasMore ? 1 : 0),
                    itemBuilder: (context, index) {
                      if (index >= _groups.length) {
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
                                : TextButton(
                                    onPressed: _loadMore,
                                    child: const Text('Load more'),
                                  ),
                          ),
                        );
                      }
                      final group = _groups[index];
                      return _GroupDiscoveryItem(
                        group: group,
                        isJoining: _joiningIds.contains(group.id),
                        onJoin: () => _joinGroup(group),
                      );
                    },
                  ),
          ),
        ],
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
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.border),
      ),
      child: Row(
        children: [
          // Group avatar
          CircleAvatar(
            radius: 22,
            backgroundColor: context.accent,
            child: const Icon(Icons.group, size: 20, color: Colors.white),
          ),
          const SizedBox(width: 12),
          // Name + description + member count
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  group.name,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                if (group.description != null &&
                    group.description!.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    group.description!,
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 13,
                    ),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
                const SizedBox(height: 4),
                Text(
                  '${group.memberCount} member${group.memberCount == 1 ? '' : 's'}',
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 8),
          // Join button
          if (group.joined)
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              decoration: BoxDecoration(
                color: context.surface,
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: context.border),
              ),
              child: Text(
                'Joined',
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
            )
          else
            FilledButton(
              onPressed: isJoining ? null : onJoin,
              style: FilledButton.styleFrom(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
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
                  : const Text('Join', style: TextStyle(fontSize: 13)),
            ),
        ],
      ),
    );
  }
}
