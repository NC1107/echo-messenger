import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../router/app_router.dart' show pendingDeepLink;
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';

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
    return _InvitePreview(
      conversationId: json['conversation_id'] as String,
      name: json['name'] as String? ?? 'Unknown Group',
      description: json['description'] as String?,
      iconUrl: json['icon_url'] as String?,
      memberCount: (json['member_count'] as num?)?.toInt() ?? 0,
      isMember: json['is_member'] as bool? ?? false,
    );
  }
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
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final alreadyMember = data['already_member'] as bool? ?? false;
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) {
          ToastService.show(
            context,
            alreadyMember
                ? 'You are already a member of ${_preview?.name ?? "this group"}'
                : 'Joined ${_preview?.name ?? "group"} successfully!',
            type: ToastType.success,
          );
          final convId = _preview?.conversationId;
          if (convId != null) {
            context.go('$_routeHome?conversation=$convId');
          } else {
            context.go(_routeHome);
          }
        }
      } else {
        String errorMsg = 'Failed to join group';
        try {
          final body = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = body['error'] as String? ?? errorMsg;
        } catch (_) {}
        if (response.statusCode == 404) {
          setState(() {
            _isJoining = false;
            _isExpiredOrInvalid = true;
            _error = errorMsg;
          });
        } else {
          setState(() {
            _isJoining = false;
            _error = errorMsg;
          });
        }
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
    final convId = _preview?.conversationId;
    if (convId != null) {
      context.go('$_routeHome?conversation=$convId');
    } else {
      context.go(_routeHome);
    }
  }

  void _goToLogin() {
    pendingDeepLink = '/invite/t/${widget.token}';
    context.go(_routeLogin);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mainBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: _isLoading ? _buildLoadingState() : _buildCard(),
        ),
      ),
    );
  }

  Widget _buildLoadingState() {
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 420),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: context.border),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _SkeletonCircle(size: 80, color: context.surfaceHover),
            const SizedBox(height: 20),
            _SkeletonRect(width: 160, height: 22, color: context.surfaceHover),
            const SizedBox(height: 12),
            _SkeletonRect(width: 220, height: 14, color: context.surfaceHover),
            const SizedBox(height: 8),
            _SkeletonRect(width: 180, height: 14, color: context.surfaceHover),
            const SizedBox(height: 20),
            _SkeletonRect(width: 100, height: 13, color: context.surfaceHover),
            const SizedBox(height: 32),
            _SkeletonRect(
              width: double.infinity,
              height: 48,
              color: context.surfaceHover,
              borderRadius: 10,
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildCard() {
    if (_isExpiredOrInvalid) return _buildErrorCard();

    return FadeTransition(
      opacity: _fadeAnimation,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildAvatar(),
              const SizedBox(height: 20),
              Text(
                _preview?.name ?? 'Group Invite',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.3,
                ),
                textAlign: TextAlign.center,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
              ),
              if (_preview?.description != null &&
                  _preview!.description!.isNotEmpty) ...[
                const SizedBox(height: 10),
                Text(
                  _preview!.description!,
                  style: TextStyle(
                    color: context.textMuted,
                    fontSize: 14,
                    height: 1.5,
                  ),
                  textAlign: TextAlign.center,
                  maxLines: 3,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
              if (_preview != null) ...[
                const SizedBox(height: 14),
                Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.people_outline_rounded,
                      size: 16,
                      color: context.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(
                      '${_preview!.memberCount} '
                      'member${_preview!.memberCount == 1 ? '' : 's'}',
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ],
              if (_error != null) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: EchoTheme.danger.withValues(alpha: 0.1),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.error_outline,
                        size: 16,
                        color: EchoTheme.danger,
                      ),
                      const SizedBox(width: 8),
                      Flexible(
                        child: Text(
                          _error!,
                          style: const TextStyle(
                            color: EchoTheme.danger,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 28),
              _buildActionButton(),
              const SizedBox(height: 12),
              TextButton(
                onPressed: () => context.go(_routeHome),
                child: Text(
                  _isLoggedIn ? 'Back to chats' : 'Cancel',
                  style: TextStyle(color: context.textSecondary, fontSize: 13),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildAvatar() {
    final serverUrl = ref.read(serverUrlProvider);
    final iconUrl = _preview?.iconUrl;

    if (iconUrl != null && iconUrl.isNotEmpty) {
      return CircleAvatar(
        radius: 40,
        backgroundColor: context.surfaceHover,
        backgroundImage: NetworkImage('$serverUrl$iconUrl'),
      );
    }

    final name = _preview?.name ?? '';
    final initials = _extractInitials(name);

    return CircleAvatar(
      radius: 40,
      backgroundColor: context.accent,
      child: Text(
        initials,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 28,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }

  String _extractInitials(String name) {
    if (name.isEmpty) return '?';
    final words = name.trim().split(RegExp(r'\s+'));
    if (words.length >= 2) {
      return '${words[0][0]}${words[1][0]}'.toUpperCase();
    }
    return name[0].toUpperCase();
  }

  Widget _buildActionButton() {
    if (!_isLoggedIn) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _goToLogin,
          icon: const Icon(Icons.login_rounded, size: 18),
          label: const Text(
            'Log in to join',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: context.accent,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      );
    }

    if (_preview?.isMember == true) {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _openGroup,
          icon: const Icon(Icons.open_in_new_rounded, size: 18),
          label: const Text(
            'Open Group',
            style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
          ),
          style: FilledButton.styleFrom(
            backgroundColor: context.accent,
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _isJoining ? null : _acceptInvite,
        style: FilledButton.styleFrom(
          backgroundColor: context.accent,
          padding: const EdgeInsets.symmetric(vertical: 14),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(10),
          ),
        ),
        child: _isJoining
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text(
                'Join Group',
                style: TextStyle(fontSize: 15, fontWeight: FontWeight.w600),
              ),
      ),
    );
  }

  Widget _buildErrorCard() {
    return FadeTransition(
      opacity: _fadeAnimation,
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 40),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: context.border),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.15),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 40,
                backgroundColor: EchoTheme.danger.withValues(alpha: 0.15),
                child: const Icon(
                  Icons.link_off_rounded,
                  size: 36,
                  color: EchoTheme.danger,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Invite link invalid',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'This invite link has expired, been revoked, or reached its '
                'use limit.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 28),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () => context.go(_routeHome),
                  style: FilledButton.styleFrom(
                    backgroundColor: context.accent,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                  child: Text(
                    _isLoggedIn ? 'Back to chats' : 'Go to login',
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Skeleton shapes (duplicated from join_group_screen to avoid coupling)
// ---------------------------------------------------------------------------

class _SkeletonCircle extends StatelessWidget {
  final double size;
  final Color color;

  const _SkeletonCircle({required this.size, required this.color});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      decoration: BoxDecoration(shape: BoxShape.circle, color: color),
    );
  }
}

class _SkeletonRect extends StatelessWidget {
  final double width;
  final double height;
  final Color color;
  final double borderRadius;

  const _SkeletonRect({
    required this.width,
    required this.height,
    required this.color,
    this.borderRadius = 6,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: color,
        borderRadius: BorderRadius.circular(borderRadius),
      ),
    );
  }
}
