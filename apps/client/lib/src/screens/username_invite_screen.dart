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

class _InviteResolution {
  final String userId;
  final String username;
  final String? displayName;
  final String? avatarUrl;
  final String relationship;
  final bool isSelf;

  const _InviteResolution({
    required this.userId,
    required this.username,
    required this.displayName,
    required this.avatarUrl,
    required this.relationship,
    required this.isSelf,
  });

  factory _InviteResolution.fromJson(Map<String, dynamic> json) {
    return _InviteResolution(
      userId: json['user_id'] as String? ?? '',
      username: json['username'] as String? ?? '',
      displayName: json['display_name'] as String?,
      avatarUrl: json['avatar_url'] as String?,
      relationship: json['relationship'] as String? ?? 'none',
      isSelf: json['is_self'] as bool? ?? false,
    );
  }

  _InviteResolution copyWith({String? relationship}) {
    return _InviteResolution(
      userId: userId,
      username: username,
      displayName: displayName,
      avatarUrl: avatarUrl,
      relationship: relationship ?? this.relationship,
      isSelf: isSelf,
    );
  }
}

class UsernameInviteScreen extends ConsumerStatefulWidget {
  final String username;

  const UsernameInviteScreen({super.key, required this.username});

  @override
  ConsumerState<UsernameInviteScreen> createState() => _UsernameInviteScreenState();
}

class _UsernameInviteScreenState extends ConsumerState<UsernameInviteScreen> {
  bool _isLoading = true;
  bool _isSubmitting = false;
  bool _notFound = false;
  String? _error;
  _InviteResolution? _invite;

  bool get _isLoggedIn => ref.read(authProvider).isLoggedIn;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_isLoggedIn) {
        _resolveUsername();
      } else {
        setState(() => _isLoading = false);
      }
    });
  }

  Future<void> _resolveUsername() async {
    setState(() {
      _isLoading = true;
      _error = null;
      _notFound = false;
    });

    final serverUrl = ref.read(serverUrlProvider);
    final encoded = Uri.encodeComponent(widget.username.trim());
    try {
      final response = await ref.read(authProvider.notifier).authenticatedRequest(
        (token) => http.get(
          Uri.parse('$serverUrl/api/users/resolve/$encoded'),
          headers: {
            'Authorization': 'Bearer $token',
            'Content-Type': 'application/json',
          },
        ),
      );

      if (!mounted) return;

      if (response.statusCode == 200) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _invite = _InviteResolution.fromJson(data);
          _isLoading = false;
        });
      } else if (response.statusCode == 404) {
        setState(() {
          _notFound = true;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Could not resolve this username invite.';
          _isLoading = false;
        });
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = 'Could not reach the server.';
        _isLoading = false;
      });
    }
  }

  void _goToLogin() {
    pendingDeepLink = '/u/${widget.username}';
    context.go(_routeLogin);
  }

  Future<void> _startDm() async {
    final invite = _invite;
    if (invite == null) return;

    setState(() => _isSubmitting = true);
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(invite.userId, invite.username);
      if (!mounted) return;
      context.go('$_routeHome?conversation=${conv.id}');
    } on DmException catch (e) {
      if (!mounted) return;
      ToastService.show(context, e.message, type: ToastType.error);
    } catch (_) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not start direct message.',
        type: ToastType.error,
      );
    } finally {
      if (mounted) setState(() => _isSubmitting = false);
    }
  }

  Future<void> _sendContactRequest() async {
    final invite = _invite;
    if (invite == null) return;

    setState(() => _isSubmitting = true);
    await ref.read(contactsProvider.notifier).sendRequest(invite.username);
    if (!mounted) return;

    final contactsState = ref.read(contactsProvider);
    if (contactsState.error != null) {
      ToastService.show(context, contactsState.error!, type: ToastType.error);
      setState(() => _isSubmitting = false);
      return;
    }

    setState(() {
      _invite = invite.copyWith(relationship: 'pending');
      _isSubmitting = false;
    });
    ToastService.show(
      context,
      'Contact request sent to @${invite.username}',
      type: ToastType.success,
    );
  }

  Widget _buildActionButton() {
    final invite = _invite;
    if (!_isLoggedIn) {
      return FilledButton.icon(
        onPressed: _goToLogin,
        icon: const Icon(Icons.login_rounded, size: 18),
        label: const Text('Log in to continue'),
      );
    }
    if (invite == null) {
      return FilledButton(
        onPressed: _resolveUsername,
        child: const Text('Retry'),
      );
    }
    if (invite.isSelf) {
      return FilledButton.icon(
        onPressed: () => context.go(_routeHome),
        icon: const Icon(Icons.home_outlined, size: 18),
        label: const Text('Open Home'),
      );
    }
    if (invite.relationship == 'contact') {
      return FilledButton.icon(
        onPressed: _isSubmitting ? null : _startDm,
        icon: const Icon(Icons.chat_bubble_outline, size: 18),
        label: Text(_isSubmitting ? 'Starting DM...' : 'Message @${invite.username}'),
      );
    }
    if (invite.relationship == 'pending') {
      return const FilledButton.icon(
        onPressed: null,
        icon: Icon(Icons.schedule_outlined, size: 18),
        label: Text('Request Pending'),
      );
    }
    if (invite.relationship == 'blocked') {
      return const FilledButton.icon(
        onPressed: null,
        icon: Icon(Icons.block_outlined, size: 18),
        label: Text('Unavailable'),
      );
    }
    return FilledButton.icon(
      onPressed: _isSubmitting ? null : _sendContactRequest,
      icon: const Icon(Icons.person_add_alt_1_outlined, size: 18),
      label: Text(_isSubmitting ? 'Sending...' : 'Send Contact Request'),
    );
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = ref.watch(serverUrlProvider);

    return Scaffold(
      backgroundColor: context.mainBg,
      body: Center(
        child: SingleChildScrollView(
          padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 48),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 420),
            child: Container(
              padding: const EdgeInsets.all(24),
              decoration: BoxDecoration(
                color: context.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(color: context.border),
              ),
              child: _isLoading
                  ? const Center(child: CircularProgressIndicator())
                  : _notFound
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.search_off, size: 42, color: context.textMuted),
                        const SizedBox(height: 12),
                        Text(
                          'This username invite was not found.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.textSecondary),
                        ),
                      ],
                    )
                  : _error != null
                  ? Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.error_outline, size: 42, color: context.textMuted),
                        const SizedBox(height: 12),
                        Text(
                          _error!,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.textSecondary),
                        ),
                        const SizedBox(height: 16),
                        OutlinedButton(
                          onPressed: _resolveUsername,
                          child: const Text('Retry'),
                        ),
                      ],
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        buildAvatar(
                          name: _invite?.username ?? widget.username,
                          radius: 40,
                          imageUrl: resolveAvatarUrl(_invite?.avatarUrl, serverUrl),
                        ),
                        const SizedBox(height: 14),
                        Text(
                          _invite?.displayName?.isNotEmpty == true
                              ? _invite!.displayName!
                              : '@${_invite?.username ?? widget.username}',
                          textAlign: TextAlign.center,
                          style: TextStyle(
                            color: context.textPrimary,
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (_invite?.displayName?.isNotEmpty == true) ...[
                          const SizedBox(height: 4),
                          Text(
                            '@${_invite!.username}',
                            style: TextStyle(color: context.textMuted, fontSize: 13),
                          ),
                        ],
                        const SizedBox(height: 16),
                        Text(
                          _invite?.relationship == 'contact'
                              ? 'You can start a direct message now.'
                              : _invite?.relationship == 'pending'
                              ? 'A contact request is already pending.'
                              : _invite?.relationship == 'blocked'
                              ? 'This invite is unavailable.'
                              : 'Send a contact request to start chatting.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: context.textSecondary, fontSize: 13),
                        ),
                        const SizedBox(height: 20),
                        SizedBox(width: double.infinity, child: _buildActionButton()),
                      ],
                    ),
            ),
          ),
        ),
      ),
    );
  }
}
