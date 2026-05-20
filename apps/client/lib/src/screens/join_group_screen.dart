import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../router/app_router.dart' show pendingDeepLinkProvider;
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import 'join/join_preview_scaffold.dart';

const _routeHome = '/home';
const _routeLogin = '/login';

/// Preview data returned by `GET /api/groups/:id/preview`.
class _GroupPreview {
  final String id;
  final String name;
  final String? description;
  final String? iconUrl;
  final int memberCount;
  final bool isMember;
  final List<JoinPreviewMember> members;

  const _GroupPreview({
    required this.id,
    required this.name,
    this.description,
    this.iconUrl,
    required this.memberCount,
    required this.isMember,
    this.members = const [],
  });

  factory _GroupPreview.fromJson(Map<String, dynamic> json) {
    final membersList =
        (json['members'] as List?)
            ?.map((e) => _memberFromJson(e as Map<String, dynamic>))
            .toList() ??
        const <JoinPreviewMember>[];
    return _GroupPreview(
      id: json['id'] as String,
      name: json['title'] as String? ?? 'Unknown Group',
      description: json['description'] as String?,
      iconUrl: json['icon_url'] as String?,
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      isMember: json['is_member'] as bool? ?? false,
      members: membersList,
    );
  }

  JoinPreviewData toJoinPreview() => JoinPreviewData(
    name: name,
    description: description,
    iconUrl: iconUrl,
    memberCount: memberCount,
    isMember: isMember,
    members: members,
  );
}

JoinPreviewMember _memberFromJson(Map<String, dynamic> json) =>
    JoinPreviewMember(
      userId: json['user_id'] as String,
      username: json['username'] as String? ?? '',
      avatarUrl: json['avatar_url'] as String?,
    );

/// Screen shown when a user opens an invite link like
/// `https://echo-messenger.us/#/join/{groupId}`.
///
/// Displays a rich group preview card (avatar, name, description, member
/// count, member avatar strip) before the user clicks Join.
class JoinGroupScreen extends ConsumerStatefulWidget {
  final String groupId;

  const JoinGroupScreen({super.key, required this.groupId});

  @override
  ConsumerState<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends ConsumerState<JoinGroupScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  bool _isJoining = false;
  _GroupPreview? _preview;
  String? _error;
  bool _is404 = false;

  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();
    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 400),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeOut,
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadGroupPreview();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  bool get _isLoggedIn => ref.read(authProvider).isLoggedIn;

  Future<void> _loadGroupPreview() async {
    final token = ref.read(authProvider).token;
    if (token == null) {
      // Not logged in -- show the login prompt immediately.
      setState(() => _isLoading = false);
      _fadeController.forward();
      return;
    }

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (t) => http.get(
              Uri.parse('$serverUrl/api/groups/${widget.groupId}/preview'),
              headers: {
                'Authorization': 'Bearer $t',
                'Content-Type': 'application/json',
              },
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _preview = _GroupPreview.fromJson(data);
          _isLoading = false;
        });
        _fadeController.forward();
      } else if (response.statusCode == 404) {
        setState(() {
          _isLoading = false;
          _is404 = true;
          _error = 'Group not found';
        });
        _fadeController.forward();
      } else {
        setState(() {
          _isLoading = false;
          _error = 'Could not load group information.';
        });
        _fadeController.forward();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not reach the server.';
        });
        _fadeController.forward();
      }
    }
  }

  Future<void> _joinGroup() async {
    setState(() => _isJoining = true);

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse('$serverUrl/api/groups/${widget.groupId}/join'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) {
          ToastService.show(
            context,
            'Joined ${_preview?.name ?? "group"} successfully!',
            type: ToastType.success,
          );
          context.go(_routeHome);
        }
      } else {
        String errorMsg = 'Failed to join group';
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = data['error'] as String? ?? errorMsg;
        } catch (_) {}
        setState(() {
          _isJoining = false;
          _error = errorMsg;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isJoining = false;
          _error = 'Network error. Please try again.';
        });
      }
    }
  }

  void _openGroup() {
    // Find the conversation matching this group so the home screen
    // auto-selects it.
    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == widget.groupId).firstOrNull;
    if (conv != null) {
      context.go('$_routeHome?conversation=${conv.id}');
    } else {
      context.go('$_routeHome?conversation=${widget.groupId}');
    }
  }

  void _goToLogin() {
    // Preserve the join URL so the user returns here after login.
    ref.read(pendingDeepLinkProvider.notifier).set('/join/${widget.groupId}');
    context.go(_routeLogin);
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = ref.read(serverUrlProvider);
    return Scaffold(
      backgroundColor: context.mainBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: JoinPreviewScaffold(
            preview: _preview?.toJoinPreview(),
            isLoading: _isLoading,
            isInvalid: _is404,
            isJoining: _isJoining,
            isLoggedIn: _isLoggedIn,
            error: _error,
            serverUrl: serverUrl,
            fadeAnimation: _fadeAnimation,
            invalidTitle: 'Group not found',
            invalidBody:
                'This group invite link is invalid or the group no longer '
                'exists.',
            onCancel: () => context.go(_routeHome),
            onLogin: _goToLogin,
            onOpenGroup: _openGroup,
            onJoin: _joinGroup,
          ),
        ),
      ),
    );
  }
}
