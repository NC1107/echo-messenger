import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../providers/auth_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

class AccountSection extends ConsumerStatefulWidget {
  const AccountSection({super.key});

  @override
  ConsumerState<AccountSection> createState() => _AccountSectionState();
}

class _AccountSectionState extends ConsumerState<AccountSection> {
  final _displayNameController = TextEditingController();
  final _bioController = TextEditingController();
  final _statusController = TextEditingController();
  final _pronounsController = TextEditingController();
  final _timezoneController = TextEditingController();
  final _websiteController = TextEditingController();
  final _emailController = TextEditingController();
  final _phoneController = TextEditingController();
  bool _profileLoaded = false;
  bool _saving = false;

  // Password change
  final _currentPasswordController = TextEditingController();
  final _newPasswordController = TextEditingController();
  bool _changingPassword = false;

  @override
  void initState() {
    super.initState();
    _loadProfile();
  }

  @override
  void dispose() {
    _displayNameController.dispose();
    _bioController.dispose();
    _statusController.dispose();
    _pronounsController.dispose();
    _currentPasswordController.dispose();
    _newPasswordController.dispose();
    _timezoneController.dispose();
    _websiteController.dispose();
    _emailController.dispose();
    _phoneController.dispose();
    super.dispose();
  }

  bool _profileError = false;

  Future<void> _loadProfile() async {
    final serverUrl = ref.read(serverUrlProvider);
    final auth = ref.read(authProvider);
    if (auth.userId == null) return;

    try {
      final resp = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.get(
              Uri.parse('$serverUrl/api/users/${auth.userId}/profile'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );
      if (resp.statusCode == 200 && mounted) {
        final data = jsonDecode(resp.body) as Map<String, dynamic>;
        setState(() {
          _displayNameController.text = data['display_name'] as String? ?? '';
          _bioController.text = data['bio'] as String? ?? '';
          _statusController.text = data['status_message'] as String? ?? '';
          _pronounsController.text = data['pronouns'] as String? ?? '';
          _timezoneController.text = data['timezone'] as String? ?? '';
          _websiteController.text = data['website'] as String? ?? '';
          _emailController.text = data['email'] as String? ?? '';
          _phoneController.text = data['phone'] as String? ?? '';
          _profileLoaded = true;
          _profileError = false;
        });
      } else if (mounted) {
        setState(() => _profileError = true);
      }
    } catch (_) {
      if (mounted) setState(() => _profileError = true);
    }
  }

  Future<void> _saveProfile() async {
    final serverUrl = ref.read(serverUrlProvider);

    setState(() => _saving = true);
    try {
      // Always send every field value — the server uses empty string as
      // "clear the field" (NULLIF in SQL) and NULL as "keep existing value".
      final body = <String, dynamic>{
        'display_name': _displayNameController.text,
        'bio': _bioController.text,
        'status_message': _statusController.text,
        'pronouns': _pronounsController.text,
        'timezone': _timezoneController.text,
        'website': _websiteController.text,
        'email': _emailController.text,
        'phone': _phoneController.text,
      };

      final resp = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.patch(
              Uri.parse('$serverUrl/api/users/me/profile'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode(body),
            ),
          );

      if (!mounted) return;
      if (resp.statusCode == 200) {
        ToastService.show(context, 'Profile updated', type: ToastType.success);
      } else {
        final err =
            jsonDecode(resp.body)['error'] as String? ?? 'Unknown error';
        ToastService.show(context, err, type: ToastType.error);
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(context, 'Failed to save: $e', type: ToastType.error);
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  static MediaType _mimeFromFilename(String name) {
    final ext = name.split('.').last.toLowerCase();
    return switch (ext) {
      'jpg' || 'jpeg' => MediaType('image', 'jpeg'),
      'webp' => MediaType('image', 'webp'),
      'gif' => MediaType('image', 'gif'),
      _ => MediaType('image', 'png'),
    };
  }

  Future<void> _changePassword() async {
    final serverUrl = ref.read(serverUrlProvider);

    if (_newPasswordController.text.length < 8) {
      ToastService.show(
        context,
        'New password must be at least 8 characters',
        type: ToastType.error,
      );
      return;
    }

    setState(() => _changingPassword = true);
    try {
      final resp = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.patch(
              Uri.parse('$serverUrl/api/users/me/password'),
              headers: {
                'Authorization': 'Bearer $token',
                'Content-Type': 'application/json',
              },
              body: jsonEncode({
                'current_password': _currentPasswordController.text,
                'new_password': _newPasswordController.text,
              }),
            ),
          );

      if (!mounted) return;
      if (resp.statusCode == 200) {
        _currentPasswordController.clear();
        _newPasswordController.clear();
        ToastService.show(
          context,
          'Password changed successfully',
          type: ToastType.success,
        );
      } else {
        final err =
            jsonDecode(resp.body)['error'] as String? ?? 'Unknown error';
        ToastService.show(context, err, type: ToastType.error);
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to change password: $e',
          type: ToastType.error,
        );
      }
    } finally {
      if (mounted) setState(() => _changingPassword = false);
    }
  }

  static String _avatarInitial(String username) {
    if (username.isNotEmpty) return username[0].toUpperCase();
    return '?';
  }

  Future<void> _uploadAvatar() async {
    final result = await FilePicker.platform.pickFiles(
      type: FileType.image,
      withData: true,
    );
    if (result == null || result.files.isEmpty) return;

    final file = result.files.first;
    if (file.bytes == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    final token = ref.read(authProvider).token;
    if (token == null) return;

    final request = _buildAvatarRequest(serverUrl, token, file);

    try {
      final streamedResponse = await request.send();
      final body = await streamedResponse.stream.bytesToString();
      if (!mounted) return;
      _handleAvatarResponse(streamedResponse.statusCode, body);
    } catch (e) {
      if (mounted) {
        ToastService.show(context, 'Upload error: $e', type: ToastType.error);
      }
    }
  }

  http.MultipartRequest _buildAvatarRequest(
    String serverUrl,
    String token,
    PlatformFile file,
  ) {
    final uri = Uri.parse('$serverUrl/api/users/me/avatar');
    return http.MultipartRequest('PUT', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(
        http.MultipartFile.fromBytes(
          'avatar',
          file.bytes!,
          filename: file.name,
          contentType: _mimeFromFilename(file.name),
        ),
      );
  }

  void _handleAvatarResponse(int statusCode, String body) {
    if (statusCode == 200) {
      _tryUpdateAvatarUrl(body);
      ToastService.show(context, 'Avatar updated', type: ToastType.success);
    } else {
      ToastService.show(
        context,
        'Failed to upload avatar ($statusCode)',
        type: ToastType.error,
      );
    }
  }

  void _tryUpdateAvatarUrl(String body) {
    try {
      final data = jsonDecode(body) as Map<String, dynamic>;
      final avatarUrl = data['avatar_url'] as String?;
      if (avatarUrl != null) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) {
            ref.read(authProvider.notifier).updateAvatarUrl(avatarUrl);
          }
        });
      }
    } catch (_) {}
  }

  void _showQrCodeDialog() {
    final authState = ref.read(authProvider);
    final userId = authState.userId ?? '';
    final username = authState.username ?? 'Unknown';
    final profileLink = 'https://echo-messenger.us/#/profile/$userId';

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'My QR Code',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(16),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(12),
              ),
              child: QrImageView(
                data: profileLink,
                version: QrVersions.auto,
                size: 200,
                backgroundColor: Colors.white,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              username,
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              profileLink,
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: profileLink));
                ToastService.show(
                  dialogContext,
                  'Link copied to clipboard',
                  type: ToastType.success,
                );
              },
              icon: const Icon(Icons.copy, size: 16),
              label: const Text('Copy link'),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final username = authState.username ?? 'Unknown';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Profile card
        Container(
          padding: const EdgeInsets.all(20),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: context.border),
          ),
          child: Row(
            children: [
              // Avatar with accent ring + edit overlay
              Stack(
                children: [
                  Container(
                    padding: const EdgeInsets.all(3),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      border: Border.all(color: context.accent, width: 2),
                    ),
                    child: CircleAvatar(
                      radius: 34,
                      backgroundColor: context.accent,
                      backgroundImage: authState.avatarUrl != null
                          ? NetworkImage(
                              '${ref.read(serverUrlProvider)}${authState.avatarUrl}',
                              headers: {
                                'Authorization': 'Bearer ${authState.token}',
                              },
                            )
                          : null,
                      child: authState.avatarUrl == null
                          ? Text(
                              _avatarInitial(username),
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 28,
                                fontWeight: FontWeight.w600,
                              ),
                            )
                          : null,
                    ),
                  ),
                  Positioned(
                    bottom: 0,
                    right: 0,
                    child: GestureDetector(
                      onTap: _uploadAvatar,
                      child: Container(
                        width: 26,
                        height: 26,
                        decoration: BoxDecoration(
                          color: context.surface,
                          shape: BoxShape.circle,
                          border: Border.all(color: context.border, width: 2),
                        ),
                        child: Icon(
                          Icons.camera_alt,
                          size: 13,
                          color: context.textSecondary,
                        ),
                      ),
                    ),
                  ),
                  // Online indicator
                  Positioned(
                    top: 2,
                    right: 2,
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        color: EchoTheme.online,
                        shape: BoxShape.circle,
                        border: Border.all(color: context.surface, width: 2),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(width: 16),
              // Name + username + status
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    if (_displayNameController.text.isNotEmpty)
                      Text(
                        _displayNameController.text,
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    Row(
                      children: [
                        Text(
                          '@$username',
                          style: TextStyle(
                            color: _displayNameController.text.isNotEmpty
                                ? context.textMuted
                                : context.textPrimary,
                            fontSize: _displayNameController.text.isNotEmpty
                                ? 13
                                : 18,
                            fontWeight: _displayNameController.text.isNotEmpty
                                ? FontWeight.normal
                                : FontWeight.w700,
                          ),
                        ),
                        if (_pronounsController.text.isNotEmpty) ...[
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              color: context.surfaceHover,
                              borderRadius: BorderRadius.circular(10),
                            ),
                            child: Text(
                              _pronounsController.text,
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ),
                        ],
                      ],
                    ),
                    if (_statusController.text.isNotEmpty) ...[
                      const SizedBox(height: 4),
                      Text(
                        _statusController.text,
                        style: TextStyle(
                          color: context.textSecondary,
                          fontSize: 13,
                          fontStyle: FontStyle.italic,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ],
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        // Action buttons row
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _uploadAvatar,
                icon: const Icon(Icons.upload, size: 16),
                label: const Text('Upload Avatar'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _showQrCodeDialog,
                icon: const Icon(Icons.qr_code, size: 16),
                label: const Text('QR Code'),
              ),
            ),
          ],
        ),
        if (_profileError) ...[
          const Divider(height: 40),
          Row(
            children: [
              Icon(Icons.error_outline, size: 18, color: EchoTheme.danger),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Failed to load profile. Check your connection.',
                  style: TextStyle(color: EchoTheme.danger, fontSize: 13),
                ),
              ),
              TextButton(onPressed: _loadProfile, child: const Text('Retry')),
            ],
          ),
        ],
        if (_profileLoaded) ...[
          const Divider(height: 40),
          Text(
            'Profile',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'Customize your public profile information.',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const Divider(height: 24),
          _profileField(
            controller: _displayNameController,
            label: 'Display Name',
            hint: 'How others see you',
            maxLength: 50,
          ),
          const SizedBox(height: 12),
          _buildPronounsField(),
          const SizedBox(height: 12),
          _profileField(
            controller: _statusController,
            label: 'Status',
            hint: 'What are you up to?',
            maxLength: 100,
          ),
          const SizedBox(height: 12),
          _profileField(
            controller: _bioController,
            label: 'Bio',
            hint: 'Tell others about yourself',
            maxLength: 300,
            maxLines: 3,
          ),
          const SizedBox(height: 12),
          _buildTimezoneDropdown(),
          const SizedBox(height: 12),
          _profileField(
            controller: _websiteController,
            label: 'Website',
            hint: 'https://example.com',
            maxLength: 200,
          ),
          const SizedBox(height: 12),
          _profileField(
            controller: _emailController,
            label: 'Email',
            hint: 'you@example.com',
            maxLength: 254,
          ),
          const SizedBox(height: 12),
          _profileField(
            controller: _phoneController,
            label: 'Phone',
            hint: '+1 555 123 4567',
            maxLength: 30,
          ),
          const SizedBox(height: 20),
          SizedBox(
            width: double.infinity,
            child: FilledButton(
              onPressed: _saving ? null : _saveProfile,
              child: _saving
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: Colors.white,
                      ),
                    )
                  : const Text('Save Profile'),
            ),
          ),
        ],
        // Password change section (always visible, outside _profileLoaded gate)
        const Divider(height: 40),
        Text(
          'Change Password',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        _profileField(
          controller: _currentPasswordController,
          label: 'Current Password',
          hint: 'Enter your current password',
          maxLength: 128,
          obscure: true,
        ),
        const SizedBox(height: 12),
        _profileField(
          controller: _newPasswordController,
          label: 'New Password',
          hint: 'At least 8 characters',
          maxLength: 128,
          obscure: true,
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton(
            onPressed: _changingPassword ? null : _changePassword,
            child: _changingPassword
                ? const SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Text('Change Password'),
          ),
        ),
      ],
    );
  }

  // Common pronoun options
  static const _pronounOptions = [
    'he/him',
    'she/her',
    'they/them',
    'he/they',
    'she/they',
    'any pronouns',
  ];

  bool get _isCustomPronoun =>
      _pronounsController.text.isNotEmpty &&
      !_pronounOptions.contains(_pronounsController.text);

  Widget _buildPronounsField() {
    final currentValue = _pronounsController.text;
    final isOther = _isCustomPronoun;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        DropdownButtonFormField<String>(
          initialValue: isOther
              ? 'other'
              : currentValue.isEmpty
              ? null
              : currentValue,
          decoration: InputDecoration(
            labelText: 'Pronouns',
            labelStyle: TextStyle(color: context.textSecondary),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.border),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: context.accent),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 12,
              vertical: 10,
            ),
          ),
          dropdownColor: context.surface,
          style: TextStyle(color: context.textPrimary, fontSize: 14),
          items: [
            ..._pronounOptions.map(
              (p) => DropdownMenuItem(value: p, child: Text(p)),
            ),
            const DropdownMenuItem(value: 'other', child: Text('Other...')),
          ],
          onChanged: (value) {
            setState(() {
              if (value == 'other') {
                _pronounsController.text = '';
              } else {
                _pronounsController.text = value ?? '';
              }
            });
          },
        ),
        if (isOther || currentValue.isEmpty && _pronounsController.text == '')
          if (isOther) ...[
            const SizedBox(height: 8),
            _profileField(
              controller: _pronounsController,
              label: 'Custom pronouns',
              hint: 'Enter your pronouns',
              maxLength: 30,
            ),
          ],
      ],
    );
  }

  // Common IANA timezones
  static const _timezones = [
    'America/New_York',
    'America/Chicago',
    'America/Denver',
    'America/Los_Angeles',
    'America/Anchorage',
    'Pacific/Honolulu',
    'America/Toronto',
    'America/Vancouver',
    'America/Mexico_City',
    'America/Sao_Paulo',
    'America/Argentina/Buenos_Aires',
    'Europe/London',
    'Europe/Paris',
    'Europe/Berlin',
    'Europe/Madrid',
    'Europe/Rome',
    'Europe/Amsterdam',
    'Europe/Stockholm',
    'Europe/Moscow',
    'Europe/Istanbul',
    'Africa/Cairo',
    'Africa/Lagos',
    'Africa/Johannesburg',
    'Asia/Dubai',
    'Asia/Kolkata',
    'Asia/Bangkok',
    'Asia/Shanghai',
    'Asia/Tokyo',
    'Asia/Seoul',
    'Asia/Singapore',
    'Australia/Sydney',
    'Australia/Melbourne',
    'Australia/Perth',
    'Pacific/Auckland',
  ];

  Widget _buildTimezoneDropdown() {
    final current = _timezoneController.text;
    final isInList = _timezones.contains(current);

    return DropdownButtonFormField<String>(
      initialValue: isInList ? current : null,
      decoration: InputDecoration(
        labelText: 'Timezone',
        hintText: current.isNotEmpty && !isInList ? current : 'Select timezone',
        hintStyle: TextStyle(color: context.textMuted),
        labelStyle: TextStyle(color: context.textSecondary),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
      dropdownColor: context.surface,
      style: TextStyle(color: context.textPrimary, fontSize: 14),
      isExpanded: true,
      menuMaxHeight: 300,
      items: _timezones
          .map((tz) => DropdownMenuItem(value: tz, child: Text(tz)))
          .toList(),
      onChanged: (value) {
        setState(() => _timezoneController.text = value ?? '');
      },
    );
  }

  Widget _profileField({
    required TextEditingController controller,
    required String label,
    String? hint,
    int maxLength = 100,
    int maxLines = 1,
    bool obscure = false,
  }) {
    return TextFormField(
      controller: controller,
      maxLength: maxLength,
      maxLines: maxLines,
      obscureText: obscure,
      style: TextStyle(color: context.textPrimary, fontSize: 14),
      decoration: InputDecoration(
        labelText: label,
        hintText: hint,
        labelStyle: TextStyle(color: context.textSecondary),
        hintStyle: TextStyle(color: context.textMuted),
        counterStyle: TextStyle(color: context.textMuted, fontSize: 10),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.border),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(8),
          borderSide: BorderSide(color: context.accent),
        ),
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 10,
        ),
      ),
    );
  }
}
