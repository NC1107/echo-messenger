import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';

/// Screen shown when a user opens an invite link like
/// `https://echo-messenger.us/#/join/{groupId}`.
///
/// Displays group info and a "Join" button. On success, navigates to /home.
class JoinGroupScreen extends ConsumerStatefulWidget {
  final String groupId;

  const JoinGroupScreen({super.key, required this.groupId});

  @override
  ConsumerState<JoinGroupScreen> createState() => _JoinGroupScreenState();
}

class _JoinGroupScreenState extends ConsumerState<JoinGroupScreen> {
  bool _isLoading = true;
  bool _isJoining = false;
  String? _groupName;
  int? _memberCount;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _loadGroupInfo();
    });
  }

  Future<void> _loadGroupInfo() async {
    final token = ref.read(authProvider).token;
    if (token == null) {
      setState(() {
        _isLoading = false;
        _error = 'You must be logged in to join a group.';
      });
      return;
    }

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse('$serverUrl/api/groups/${widget.groupId}'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
            ),
          );

      if (response.statusCode == 200 && mounted) {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        setState(() {
          _groupName =
              data['title'] as String? ??
              data['name'] as String? ??
              'Unknown Group';
          _memberCount = (data['members'] as List?)?.length;
          _isLoading = false;
        });
      } else if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not load group information.';
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _isLoading = false;
          _error = 'Could not reach the server.';
        });
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
        // Refresh conversations list so the new group appears
        await ref.read(conversationsProvider.notifier).loadConversations();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text('Joined ${_groupName ?? "group"} successfully!'),
            ),
          );
          context.go('/home');
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: EchoTheme.mainBg,
      appBar: AppBar(
        backgroundColor: EchoTheme.sidebarBg,
        title: const Text(
          'Join Group',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: EchoTheme.textSecondary),
          onPressed: () => context.go('/home'),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: _isLoading
              ? const CircularProgressIndicator(color: EchoTheme.accent)
              : _buildContent(),
        ),
      ),
    );
  }

  Widget _buildContent() {
    return Padding(
      padding: const EdgeInsets.all(32),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          // Group icon
          CircleAvatar(
            radius: 40,
            backgroundColor: EchoTheme.accent,
            child: const Icon(Icons.group, size: 40, color: Colors.white),
          ),
          const SizedBox(height: 20),
          // Group name
          Text(
            _groupName ?? 'Group',
            style: const TextStyle(
              color: EchoTheme.textPrimary,
              fontSize: 22,
              fontWeight: FontWeight.bold,
            ),
          ),
          if (_memberCount != null) ...[
            const SizedBox(height: 8),
            Text(
              '$_memberCount member${_memberCount == 1 ? '' : 's'}',
              style: const TextStyle(color: EchoTheme.textMuted, fontSize: 14),
            ),
          ],
          const SizedBox(height: 8),
          const Text(
            'You have been invited to join this group.',
            textAlign: TextAlign.center,
            style: TextStyle(
              color: EchoTheme.textSecondary,
              fontSize: 14,
              height: 1.4,
            ),
          ),
          if (_error != null) ...[
            const SizedBox(height: 16),
            Text(
              _error!,
              textAlign: TextAlign.center,
              style: const TextStyle(color: EchoTheme.danger, fontSize: 13),
            ),
          ],
          const SizedBox(height: 28),
          // Join button
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _isJoining ? null : _joinGroup,
              style: FilledButton.styleFrom(
                backgroundColor: EchoTheme.accent,
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
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
            ),
          ),
          const SizedBox(height: 12),
          TextButton(
            onPressed: () => context.go('/home'),
            child: const Text(
              'Cancel',
              style: TextStyle(color: EchoTheme.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
