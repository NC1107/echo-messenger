import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/contacts_provider.dart';
import '../providers/server_url_provider.dart';
import '../services/toast_service.dart';
import '../theme/echo_theme.dart';
import '../widgets/conversation_panel.dart' show buildAvatar;

/// Shows a user profile. On desktop (>=900px) opens as a dialog; on mobile as
/// a full screen page.
class UserProfileScreen extends ConsumerStatefulWidget {
  final String userId;

  const UserProfileScreen({super.key, required this.userId});

  /// Open the profile as a dialog on desktop or push a full-screen route on
  /// mobile.
  static void show(BuildContext context, WidgetRef ref, String userId) {
    final width = MediaQuery.of(context).size.width;
    if (width >= 900) {
      showDialog(
        context: context,
        builder: (_) => Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: 400,
            height: 500,
            child: UserProfileScreen(userId: userId),
          ),
        ),
      );
    } else {
      Navigator.of(context).push(
        MaterialPageRoute(
          builder: (_) => Scaffold(
            appBar: AppBar(
              title: Text('Profile'),
              backgroundColor: context.surface,
            ),
            body: UserProfileScreen(userId: userId),
          ),
        ),
      );
    }
  }

  @override
  ConsumerState<UserProfileScreen> createState() => _UserProfileScreenState();
}

class _UserProfileScreenState extends ConsumerState<UserProfileScreen> {
  bool _isLoading = true;
  String? _error;

  String _username = '';
  String? _displayName;
  String? _bio;
  String? _avatarUrl;
  String? _createdAt;
  bool _isContact = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) => _loadProfile());
  }

  Future<void> _loadProfile() async {
    final serverUrl = ref.read(serverUrlProvider);

    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse('$serverUrl/api/users/${widget.userId}/profile'),
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
          _username = data['username'] as String? ?? '';
          _displayName = data['display_name'] as String?;
          _bio = data['bio'] as String?;
          _avatarUrl = data['avatar_url'] as String?;
          _createdAt = data['created_at'] as String?;
          _isLoading = false;
        });
      } else {
        setState(() {
          _error = 'Failed to load profile (${response.statusCode})';
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _error = 'Failed to load profile';
          _isLoading = false;
        });
      }
    }

    // Check if user is already a contact
    final contacts = ref.read(contactsProvider).contacts;
    if (contacts.any((c) => c.userId == widget.userId)) {
      if (mounted) setState(() => _isContact = true);
    }
  }

  Future<void> _addContact() async {
    if (_username.isEmpty) return;
    await ref.read(contactsProvider.notifier).sendRequest(_username);
    if (mounted) {
      ToastService.show(
        context,
        'Contact request sent',
        type: ToastType.success,
      );
    }
  }

  String _formatMemberSince(String? isoDate) {
    if (isoDate == null) return 'Unknown';
    try {
      final dt = DateTime.parse(isoDate).toLocal();
      const months = [
        'Jan',
        'Feb',
        'Mar',
        'Apr',
        'May',
        'Jun',
        'Jul',
        'Aug',
        'Sep',
        'Oct',
        'Nov',
        'Dec',
      ];
      return '${months[dt.month - 1]} ${dt.day}, ${dt.year}';
    } catch (_) {
      return 'Unknown';
    }
  }

  @override
  Widget build(BuildContext context) {
    final serverUrl = ref.watch(serverUrlProvider);

    if (_isLoading) {
      return Center(
        child: CircularProgressIndicator(color: context.accent, strokeWidth: 2),
      );
    }

    if (_error != null) {
      return Center(
        child: Text(
          _error!,
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
      );
    }

    final fullAvatarUrl = _avatarUrl != null ? '$serverUrl$_avatarUrl' : null;

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
      child: Column(
        children: [
          // Large avatar
          buildAvatar(name: _username, radius: 40, imageUrl: fullAvatarUrl),
          const SizedBox(height: 16),
          // Display name
          if (_displayName != null && _displayName!.isNotEmpty)
            Text(
              _displayName!,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.bold,
              ),
            ),
          // Username
          Text(
            '@$_username',
            style: TextStyle(
              color: _displayName != null
                  ? context.textMuted
                  : context.textPrimary,
              fontSize: _displayName != null ? 14 : 22,
              fontWeight: _displayName != null
                  ? FontWeight.normal
                  : FontWeight.bold,
            ),
          ),
          const SizedBox(height: 12),
          // Bio
          if (_bio != null && _bio!.isNotEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(
                _bio!,
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 14,
                  height: 1.4,
                ),
              ),
            ),
          if (_bio != null && _bio!.isNotEmpty) const SizedBox(height: 12),
          // Member since
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.calendar_today_outlined,
                size: 14,
                color: context.textMuted,
              ),
              const SizedBox(width: 6),
              Text(
                'Member since ${_formatMemberSince(_createdAt)}',
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
            ],
          ),
          const SizedBox(height: 28),
          // Action buttons
          if (!_isContact && widget.userId != ref.read(authProvider).userId)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: _addContact,
                icon: const Icon(Icons.person_add_outlined, size: 18),
                label: Text('Add Contact'),
                style: FilledButton.styleFrom(
                  backgroundColor: context.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
          if (_isContact)
            SizedBox(
              width: double.infinity,
              child: FilledButton.icon(
                onPressed: null,
                icon: const Icon(Icons.check, size: 18),
                label: const Text('Contact'),
                style: FilledButton.styleFrom(
                  backgroundColor: EchoTheme.online,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  padding: const EdgeInsets.symmetric(vertical: 12),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
