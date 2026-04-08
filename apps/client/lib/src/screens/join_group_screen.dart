import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';

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
  final List<_MemberPreview> members;

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
            ?.map((e) => _MemberPreview.fromJson(e as Map<String, dynamic>))
            .toList() ??
        [];
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
}

class _MemberPreview {
  final String userId;
  final String username;
  final String? avatarUrl;

  const _MemberPreview({
    required this.userId,
    required this.username,
    this.avatarUrl,
  });

  factory _MemberPreview.fromJson(Map<String, dynamic> json) {
    return _MemberPreview(
      userId: json['user_id'] as String,
      username: json['username'] as String? ?? '',
      avatarUrl: json['avatar_url'] as String?,
    );
  }
}

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
    context.go(_routeHome);
  }

  void _goToLogin() {
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

  // ---------------------------------------------------------------------------
  // Loading skeleton
  // ---------------------------------------------------------------------------

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
            // Avatar shimmer
            _SkeletonCircle(size: 80, color: context.surfaceHover),
            const SizedBox(height: 20),
            // Name shimmer
            _SkeletonRect(width: 160, height: 22, color: context.surfaceHover),
            const SizedBox(height: 12),
            // Description shimmer
            _SkeletonRect(width: 220, height: 14, color: context.surfaceHover),
            const SizedBox(height: 8),
            _SkeletonRect(width: 180, height: 14, color: context.surfaceHover),
            const SizedBox(height: 20),
            // Member count shimmer
            _SkeletonRect(width: 100, height: 13, color: context.surfaceHover),
            const SizedBox(height: 32),
            // Button shimmer
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

  // ---------------------------------------------------------------------------
  // Main card
  // ---------------------------------------------------------------------------

  Widget _buildCard() {
    if (_is404) return _buildErrorCard();

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
              // Group avatar
              _buildAvatar(),
              const SizedBox(height: 20),

              // Group name
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

              // Description
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

              // Member count
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
                      '${_preview!.memberCount} member${_preview!.memberCount == 1 ? '' : 's'}',
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ],

              // Member avatar strip
              if (_preview != null && _preview!.members.isNotEmpty) ...[
                const SizedBox(height: 18),
                _buildMemberStrip(),
              ],

              // Error message
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

              // Primary action button
              _buildActionButton(),

              // Back link
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

  // ---------------------------------------------------------------------------
  // Avatar
  // ---------------------------------------------------------------------------

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

    // Initials fallback
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

  // ---------------------------------------------------------------------------
  // Member strip (overlapping circles)
  // ---------------------------------------------------------------------------

  Widget _buildMemberStrip() {
    final serverUrl = ref.read(serverUrlProvider);
    final members = _preview!.members;
    final maxShow = members.length > 5 ? 5 : members.length;
    const avatarSize = 32.0;
    const overlap = 10.0;
    final totalWidth = avatarSize + (maxShow - 1) * (avatarSize - overlap);

    return SizedBox(
      width: totalWidth,
      height: avatarSize,
      child: Stack(
        children: List.generate(maxShow, (i) {
          final member = members[i];
          return Positioned(
            left: i * (avatarSize - overlap),
            child: Container(
              width: avatarSize,
              height: avatarSize,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: context.surface, width: 2),
              ),
              child: CircleAvatar(
                radius: (avatarSize - 4) / 2,
                backgroundColor: context.surfaceHover,
                backgroundImage: member.avatarUrl != null
                    ? NetworkImage('$serverUrl${member.avatarUrl}')
                    : null,
                child: member.avatarUrl == null
                    ? Text(
                        member.username.isNotEmpty
                            ? member.username[0].toUpperCase()
                            : '?',
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                      )
                    : null,
              ),
            ),
          );
        }),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Action button
  // ---------------------------------------------------------------------------

  Widget _buildActionButton() {
    // Not logged in
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

    // Already a member
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

    // Join button
    return SizedBox(
      width: double.infinity,
      child: FilledButton(
        onPressed: _isJoining ? null : _joinGroup,
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

  // ---------------------------------------------------------------------------
  // 404 / error card
  // ---------------------------------------------------------------------------

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
                  Icons.search_off_rounded,
                  size: 36,
                  color: EchoTheme.danger,
                ),
              ),
              const SizedBox(height: 20),
              Text(
                'Group not found',
                style: TextStyle(
                  color: context.textPrimary,
                  fontSize: 20,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 10),
              Text(
                'This invite link may have expired or the group no longer exists.',
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
// Skeleton shapes
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
