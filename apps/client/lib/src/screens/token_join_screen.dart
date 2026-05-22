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

/// Preview data returned by `GET /api/invites/:token`.
class _InvitePreview {
  final String conversationId;
  final String name;
  final String? description;
  final String? iconUrl;
  final int memberCount;
  final bool isMember;

  const _InvitePreview({
    required this.conversationId,
    required this.name,
    this.description,
    this.iconUrl,
    required this.memberCount,
    required this.isMember,
  });

  factory _InvitePreview.fromJson(Map<String, dynamic> json) {
    // Server returns `{token, group: {id, title, description, icon_url,
    // member_count, is_member, members}}`. Read the nested object — the
    // earlier flat-key read produced "Unknown Group" + 0 members in the UI
    // because none of the top-level keys existed.
    final group =
        (json['group'] as Map<String, dynamic>?) ?? const <String, dynamic>{};
    return _InvitePreview(
      conversationId: group['id'] as String? ?? '',
      name: group['title'] as String? ?? 'Unknown Group',
      description: group['description'] as String?,
      iconUrl: group['icon_url'] as String?,
      memberCount: (group['member_count'] as num?)?.toInt() ?? 0,
      isMember: group['is_member'] as bool? ?? false,
    );
  }

  JoinPreviewData toJoinPreview() => JoinPreviewData(
    name: name,
    description: description,
    iconUrl: iconUrl,
    memberCount: memberCount,
    isMember: isMember,
  );
}

/// Screen shown when a user opens a token-based invite link like
/// `https://echo-messenger.us/invite/t/{token}`.
///
/// Fetches a lightweight preview via `GET /api/invites/{token}` and lets the
/// user accept via `POST /api/invites/{token}/accept`.
class TokenJoinScreen extends ConsumerStatefulWidget {
  final String token;

  const TokenJoinScreen({super.key, required this.token});

  @override
  ConsumerState<TokenJoinScreen> createState() => _TokenJoinScreenState();
}

class _TokenJoinScreenState extends ConsumerState<TokenJoinScreen>
    with SingleTickerProviderStateMixin {
  bool _isLoading = true;
  bool _isJoining = false;
  _InvitePreview? _preview;
  String? _error;
  bool _isExpiredOrInvalid = false;

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
      _loadInvitePreview();
    });
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  bool get _isLoggedIn => ref.read(authProvider).isLoggedIn;

  Future<void> _loadInvitePreview() async {
    final token = ref.read(authProvider).token;
    if (token == null) {
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
              Uri.parse('$serverUrl/api/invites/${widget.token}'),
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
          _preview = _InvitePreview.fromJson(data);
          _isLoading = false;
        });
        _fadeController.forward();
      } else if (response.statusCode == 404) {
        setState(() {
          _isLoading = false;
          _isExpiredOrInvalid = true;
          _error = 'Invite link not found or has expired';
        });
        _fadeController.forward();
      } else {
        setState(() {
          _isLoading = false;
          _error = 'Could not load invite information.';
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

  Future<void> _acceptInvite() async {
    setState(() => _isJoining = true);

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.post(
              Uri.parse('$serverUrl/api/invites/${widget.token}/accept'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 201) {
        await _handleAcceptInviteSuccess(response);
      } else {
        await _handleAcceptInviteError(response);
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

  Future<void> _handleAcceptInviteSuccess(http.Response response) async {
    final data = jsonDecode(response.body) as Map<String, dynamic>;
    // Server returns `{status: "already_member"|"joined", conversation_id}`.
    // The earlier read of `data['already_member']` was a phantom — that key
    // never appears in the response, so the toast always said "joined" even
    // when the user was already a member.
    final alreadyMember = (data['status'] as String?) == 'already_member';
    await ref.read(conversationsProvider.notifier).loadConversations();
    if (mounted) {
      final toastMsg = _buildSuccessToastMessage(alreadyMember);
      ToastService.show(context, toastMsg, type: ToastType.success);
      _navigateToConversation();
    }
  }

  String _buildSuccessToastMessage(bool alreadyMember) {
    final groupName = _preview?.name ?? 'group';
    return alreadyMember
        ? 'You are already a member of $groupName'
        : 'Joined $groupName successfully!';
  }

  void _navigateToConversation() {
    final convId = _preview?.conversationId;
    if (convId != null) {
      context.go('$_routeHome?conversation=$convId');
    } else {
      context.go(_routeHome);
    }
  }

  Future<void> _handleAcceptInviteError(http.Response response) async {
    String errorMsg = 'Failed to join group';
    try {
      final body = jsonDecode(response.body) as Map<String, dynamic>;
      errorMsg = body['error'] as String? ?? errorMsg;
    } catch (_) {}

    final isExpired = response.statusCode == 404;
    setState(() {
      _isJoining = false;
      _error = errorMsg;
      if (isExpired) {
        _isExpiredOrInvalid = true;
      }
    });
  }

  void _openGroup() {
    final convId = _preview?.conversationId;
    if (convId != null) {
      context.go('$_routeHome?conversation=$convId');
    } else {
      context.go(_routeHome);
    }
  }

  void _goToLogin() {
    ref.read(pendingDeepLinkProvider.notifier).set('/invite/t/${widget.token}');
    context.go(_routeLogin);
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = ref.read(serverUrlProvider);
    return Scaffold(
      backgroundColor: context.mainBg,
      body: LayoutBuilder(
        builder: (context, constraints) {
          final inner = Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
            child: Center(
              child: JoinPreviewScaffold(
                preview: _preview?.toJoinPreview(),
                isLoading: _isLoading,
                isInvalid: _isExpiredOrInvalid,
                isJoining: _isJoining,
                isLoggedIn: _isLoggedIn,
                error: _error,
                serverUrl: serverUrl,
                fadeAnimation: _fadeAnimation,
                invalidTitle: 'Invite link invalid',
                invalidBody:
                    'This invite link has expired, been revoked, or '
                    'reached its use limit.',
                onCancel: () => context.go(_routeHome),
                onLogin: _goToLogin,
                onOpenGroup: _openGroup,
                onJoin: _acceptInvite,
              ),
            ),
          );
          if (constraints.maxHeight < 600) {
            return SingleChildScrollView(child: inner);
          }
          return inner;
        },
      ),
    );
  }
}
