import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../router/app_router.dart' show pendingDeepLink;
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../widgets/avatar_utils.dart' show buildAvatar, resolveAvatarUrl;

const _routeHome = '/home';
const _routeLogin = '/login';

class _ResolvedInviteUser {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String? bio;
  final String? statusMessage;
  final String relationship;

  const _ResolvedInviteUser({
    required this.userId,
    required this.username,
    this.displayName,
    this.avatarUrl,
    this.bio,
    this.statusMessage,
    required this.relationship,
  });

  factory _ResolvedInviteUser.fromJson(Map<String, dynamic> json) {
    return _ResolvedInviteUser(
      userId: json['user_id'] as String,
      username: json['username'] as String,
      displayName: json['display_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      bio: json['bio'] as String?,
      statusMessage: json['status_message'] as String?,
      relationship: json['relationship'] as String? ?? 'none',
    );
  }
}

class UsernameInviteScreen extends ConsumerStatefulWidget {
  final String username;

  const UsernameInviteScreen({super.key, required this.username});

  @override
  ConsumerState<UsernameInviteScreen> createState() =>
      _UsernameInviteScreenState();
}

class _UsernameInviteScreenState extends ConsumerState<UsernameInviteScreen> {
  bool _isLoading = true;
  bool _isActionLoading = false;
  String? _error;
  _ResolvedInviteUser? _user;
  String _relationship = 'none';

  bool get _isLoggedIn => ref.read(authProvider).isLoggedIn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadInvite());
  }

  Future<void> _loadInvite() async {
    if (!_isLoggedIn) {
      setState(() => _isLoading = false);
      return;
    }

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse(
                '$serverUrl/api/users/resolve/${Uri.encodeComponent(widget.username)}',
              ),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        final resolved = _ResolvedInviteUser.fromJson(data);
        setState(() {
          _user = resolved;
          _relationship = resolved.relationship;
          _isLoading = false;
          _error = null;
        });
        return;
      }

      if (response.statusCode == 404) {
        setState(() {
          _isLoading = false;
          _error = 'User not found';
        });
        return;
      }

      setState(() {
        _isLoading = false;
        _error = 'Could not resolve invite';
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _isLoading = false;
        _error = 'Could not reach server';
      });
    }
  }

  void _goToLogin() {
    pendingDeepLink = '/u/${widget.username}';
    context.go(_routeLogin);
  }

  Future<void> _openDm() async {
    final user = _user;
    if (user == null) return;
    setState(() => _isActionLoading = true);
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(user.userId, user.username);
      if (!mounted) return;
      context.go('$_routeHome?conversation=${conv.id}');
    } on DmException catch (e) {
      if (!mounted) return;
      ToastService.show(context, e.message, type: ToastType.error);
    } catch (_) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not start conversation',
        type: ToastType.error,
      );
    } finally {
      if (mounted) {
        setState(() => _isActionLoading = false);
      }
    }
  }

  Future<void> _sendContactRequest() async {
    final user = _user;
    if (user == null) return;
    setState(() => _isActionLoading = true);
    await ref.read(contactsProvider.notifier).sendRequest(user.username);
    if (!mounted) return;
    final error = ref.read(contactsProvider).error;
    if (error != null) {
      ToastService.show(context, error, type: ToastType.error);
      setState(() => _isActionLoading = false);
      return;
    }
    setState(() {
      _relationship = 'pending';
      _isActionLoading = false;
    });
    ToastService.show(context, 'Contact request sent', type: ToastType.success);
  }

  @override
  Widget build(BuildContext context) {
    if (_isLoading) {
      return Scaffold(
        backgroundColor: context.mainBg,
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: context.mainBg,
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 440),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: _buildCard(context),
          ),
        ),
      ),
    );
  }

  Widget _buildCard(BuildContext context) {
    if (!_isLoggedIn) return _buildLoginCard(context);
    if (_error != null) return _buildErrorCard(context, _error!);
    final user = _user;
    if (user == null) return _buildErrorCard(context, 'Could not load invite');

    final serverUrl = ref.watch(serverUrlProvider);
    final avatar = resolveAvatarUrl(user.avatarUrl, serverUrl);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          buildAvatar(name: user.username, radius: 42, imageUrl: avatar),
          const SizedBox(height: 16),
          Text(
            user.displayName ?? user.username,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(
            '@${user.username}',
            style: TextStyle(color: context.textSecondary, fontSize: 14),
          ),
          if (user.statusMessage != null && user.statusMessage!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              user.statusMessage!,
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
                fontStyle: FontStyle.italic,
              ),
              textAlign: TextAlign.center,
            ),
          ],
          if (user.bio != null && user.bio!.isNotEmpty) ...[
            const SizedBox(height: 10),
            Text(
              user.bio!,
              style: TextStyle(color: context.textMuted, fontSize: 13),
              textAlign: TextAlign.center,
              maxLines: 3,
              overflow: TextOverflow.ellipsis,
            ),
          ],
          const SizedBox(height: 24),
          _buildPrimaryAction(context),
          const SizedBox(height: 10),
          TextButton(
            onPressed: () => context.go(_routeHome),
            child: Text(
              'Back to chats',
              style: TextStyle(color: context.textSecondary),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildLoginCard(BuildContext context) {
    return _simpleCard(
      context,
      icon: Icons.login_rounded,
      title: 'Sign in to continue',
      subtitle: 'Open the invite for @${widget.username} after you log in.',
      action: FilledButton.icon(
        onPressed: _goToLogin,
        icon: const Icon(Icons.login_rounded, size: 18),
        label: const Text('Log in'),
      ),
    );
  }

  Widget _buildErrorCard(BuildContext context, String message) {
    return _simpleCard(
      context,
      icon: Icons.search_off_rounded,
      title: 'Invite unavailable',
      subtitle: message,
      action: FilledButton.icon(
        onPressed: _loadInvite,
        icon: const Icon(Icons.refresh, size: 18),
        label: const Text('Retry'),
      ),
    );
  }

  Widget _simpleCard(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String subtitle,
    required Widget action,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      decoration: BoxDecoration(
        color: context.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: context.border),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 40, color: context.textMuted),
          const SizedBox(height: 14),
          Text(
            title,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            subtitle,
            textAlign: TextAlign.center,
            style: TextStyle(color: context.textSecondary, fontSize: 13),
          ),
          const SizedBox(height: 22),
          SizedBox(width: double.infinity, child: action),
        ],
      ),
    );
  }

  Widget _buildPrimaryAction(BuildContext context) {
    if (_relationship == 'contact') {
      return SizedBox(
        width: double.infinity,
        child: FilledButton.icon(
          onPressed: _isActionLoading ? null : _openDm,
          icon: const Icon(Icons.chat_bubble_outline, size: 18),
          label: _isActionLoading
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: Colors.white,
                  ),
                )
              : const Text('Message'),
        ),
      );
    }

    if (_relationship == 'pending') {
      return SizedBox(
        width: double.infinity,
        child: OutlinedButton.icon(
          onPressed: null,
          icon: const Icon(Icons.schedule, size: 18),
          label: const Text('Request pending'),
        ),
      );
    }

    if (_relationship == 'blocked') {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 12),
        decoration: BoxDecoration(
          color: EchoTheme.danger.withValues(alpha: 0.1),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'You cannot contact this user.',
          textAlign: TextAlign.center,
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
      );
    }

    return SizedBox(
      width: double.infinity,
      child: FilledButton.icon(
        onPressed: _isActionLoading ? null : _sendContactRequest,
        icon: const Icon(Icons.person_add_outlined, size: 18),
        label: _isActionLoading
            ? const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(
                  strokeWidth: 2,
                  color: Colors.white,
                ),
              )
            : const Text('Add Contact'),
      ),
    );
  }
}
