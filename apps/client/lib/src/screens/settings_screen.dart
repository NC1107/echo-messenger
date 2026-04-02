import 'dart:convert';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;
import 'package:http_parser/http_parser.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/privacy_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/update_provider.dart';
import '../providers/voice_settings_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../version.dart';

/// Section identifiers for the settings navigation.
enum SettingsSection { account, privacy, audio, server, appearance, about }

/// Returns a human-readable label for a settings section.
String settingsSectionLabel(SettingsSection section) {
  switch (section) {
    case SettingsSection.account:
      return 'Account';
    case SettingsSection.privacy:
      return 'Privacy';
    case SettingsSection.server:
      return 'Server';
    case SettingsSection.audio:
      return 'Audio';
    case SettingsSection.appearance:
      return 'Appearance';
    case SettingsSection.about:
      return 'About';
  }
}

// ---------------------------------------------------------------------------
// Settings nav list widget (reusable)
// ---------------------------------------------------------------------------

class SettingsNavList extends StatelessWidget {
  final SettingsSection? selected;
  final void Function(SettingsSection) onTap;
  final VoidCallback onLogout;

  const SettingsNavList({
    super.key,
    this.selected,
    required this.onTap,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        _navItem(
          context: context,
          icon: Icons.person_outlined,
          label: 'Account',
          section: SettingsSection.account,
        ),
        _navItem(
          context: context,
          icon: Icons.lock_outline,
          label: 'Privacy',
          section: SettingsSection.privacy,
        ),
        _navItem(
          context: context,
          icon: Icons.graphic_eq,
          label: 'Audio',
          section: SettingsSection.audio,
        ),
        _navItem(
          context: context,
          icon: Icons.dns_outlined,
          label: 'Server',
          section: SettingsSection.server,
        ),
        _navItem(
          context: context,
          icon: Icons.palette_outlined,
          label: 'Appearance',
          section: SettingsSection.appearance,
        ),
        _navItem(
          context: context,
          icon: Icons.info_outline,
          label: 'About',
          section: SettingsSection.about,
        ),
        const Spacer(),
        // Logout button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: onLogout,
              icon: const Icon(Icons.logout, size: 18, color: EchoTheme.danger),
              label: const Text(
                'Log out',
                style: TextStyle(color: EchoTheme.danger),
              ),
              style: OutlinedButton.styleFrom(
                side: const BorderSide(color: EchoTheme.danger),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _navItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required SettingsSection section,
  }) {
    final isSelected = selected == section;
    return Material(
      color: isSelected ? context.accentLight : Colors.transparent,
      child: InkWell(
        onTap: () => onTap(section),
        hoverColor: context.surfaceHover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? context.accent : context.textSecondary,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? context.accent : context.textPrimary,
                  fontSize: 14,
                  fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
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
// Settings content widget (reusable)
// ---------------------------------------------------------------------------

class SettingsContent extends ConsumerStatefulWidget {
  final SettingsSection section;

  const SettingsContent({super.key, required this.section});

  @override
  ConsumerState<SettingsContent> createState() => _SettingsContentState();
}

class _SettingsContentState extends ConsumerState<SettingsContent> {
  bool _serverOnline = false;
  bool _checkingHealth = true;
  String? _serverVersion;

  @override
  void initState() {
    super.initState();
    if (widget.section == SettingsSection.server ||
        widget.section == SettingsSection.about) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _checkServerHealth();
      });
    }
    if (widget.section == SettingsSection.privacy) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ref.read(privacyProvider.notifier).load();
      });
    }
  }

  @override
  void didUpdateWidget(covariant SettingsContent oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.section != oldWidget.section &&
        (widget.section == SettingsSection.server ||
            widget.section == SettingsSection.about) &&
        _serverVersion == null) {
      _checkServerHealth();
    }
    if (widget.section != oldWidget.section &&
        widget.section == SettingsSection.privacy) {
      ref.read(privacyProvider.notifier).load();
    }
  }

  Future<void> _checkServerHealth() async {
    setState(() => _checkingHealth = true);
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/api/health'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 && mounted) {
        String? version;
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          version = data['version'] as String?;
        } catch (_) {}
        setState(() {
          _serverOnline = true;
          _checkingHealth = false;
          _serverVersion = version;
        });
      } else if (mounted) {
        setState(() {
          _serverOnline = false;
          _checkingHealth = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _serverOnline = false;
          _checkingHealth = false;
        });
      }
    }
  }

  Future<void> _showChangeServerDialog() async {
    final currentUrl = ref.read(serverUrlProvider);
    final controller = TextEditingController(text: currentUrl);

    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Change Server',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the URL of an Echo server. You will need to log in again after changing servers.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://echo-messenger.us',
              ),
              keyboardType: TextInputType.url,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                controller.text = defaultServerUrl;
              },
              child: const Text(
                'Reset to default',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newUrl != null && newUrl.isNotEmpty && newUrl != currentUrl) {
      await ref.read(serverUrlProvider.notifier).setUrl(newUrl);
      await _checkServerHealth();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Server URL updated. Please log out and log in again for changes to take full effect.',
            ),
          ),
        );
      }
    }
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

    final uri = Uri.parse('$serverUrl/api/users/me/avatar');
    final request = http.MultipartRequest('PUT', uri)
      ..headers['Authorization'] = 'Bearer $token'
      ..files.add(
        http.MultipartFile.fromBytes(
          'avatar',
          file.bytes!,
          filename: file.name,
          contentType: MediaType('image', 'png'),
        ),
      );

    try {
      final streamedResponse = await request.send();
      final body = await streamedResponse.stream.bytesToString();
      if (mounted) {
        if (streamedResponse.statusCode == 200) {
          // Parse avatar URL from response and update auth state
          try {
            final data = jsonDecode(body) as Map<String, dynamic>;
            final avatarUrl = data['avatar_url'] as String?;
            if (avatarUrl != null) {
              ref.read(authProvider.notifier).updateAvatarUrl(avatarUrl);
            }
          } catch (_) {}
          ScaffoldMessenger.of(
            context,
          ).showSnackBar(const SnackBar(content: Text('Avatar updated')));
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Failed to upload avatar (${streamedResponse.statusCode})',
              ),
            ),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Upload error: $e')));
      }
    }
  }

  void _showQrCodeDialog() {
    final authState = ref.read(authProvider);
    final userId = authState.userId ?? '';
    final username = authState.username ?? 'Unknown';
    final echoUri = 'echo://user/$userId';

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
                data: echoUri,
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
              echoUri,
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            const SizedBox(height: 16),
            OutlinedButton.icon(
              onPressed: () {
                Clipboard.setData(ClipboardData(text: echoUri));
                ScaffoldMessenger.of(dialogContext).showSnackBar(
                  const SnackBar(content: Text('Link copied to clipboard')),
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
    switch (widget.section) {
      case SettingsSection.account:
        return _buildAccountSection();
      case SettingsSection.privacy:
        return _buildPrivacySection();
      case SettingsSection.server:
        return _buildServerSection();
      case SettingsSection.audio:
        return _buildAudioSection();
      case SettingsSection.appearance:
        return _buildAppearanceSection();
      case SettingsSection.about:
        return _buildAboutSection();
    }
  }

  Widget _buildAccountSection() {
    final authState = ref.watch(authProvider);
    final username = authState.username ?? 'Unknown';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 32,
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
                          username.isNotEmpty ? username[0].toUpperCase() : '?',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 26,
                            fontWeight: FontWeight.w600,
                          ),
                        )
                      : null,
                ),
                Positioned(
                  bottom: 0,
                  right: 0,
                  child: GestureDetector(
                    onTap: _uploadAvatar,
                    child: Container(
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: context.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: context.border, width: 2),
                      ),
                      child: Icon(
                        Icons.edit,
                        size: 12,
                        color: context.textSecondary,
                      ),
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(width: 20),
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  username,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  'Online',
                  style: TextStyle(color: context.textMuted, fontSize: 13),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _uploadAvatar,
            icon: const Icon(Icons.upload, size: 18),
            label: const Text('Upload Avatar'),
          ),
        ),
        const SizedBox(height: 12),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _showQrCodeDialog,
            icon: const Icon(Icons.qr_code, size: 18),
            label: const Text('My QR Code'),
          ),
        ),
      ],
    );
  }

  Future<void> _resetEncryptionKeys() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Reset Encryption Keys',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will regenerate your encryption keys. You won\'t be able '
          'to read old encrypted messages. Both you and your contacts will '
          'need to exchange new messages.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Reset Keys'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(cryptoProvider.notifier).resetKeys();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Encryption keys have been reset successfully.'),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Failed to reset keys: $e')));
      }
    }
  }

  Widget _buildPrivacySection() {
    final privacy = ref.watch(privacyProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (privacy.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              privacy.error!,
              style: const TextStyle(color: EchoTheme.danger, fontSize: 12),
            ),
          ),
        Text(
          'Messaging Privacy',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Control read receipts and whether unencrypted direct messages are allowed.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Send Read Receipts',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'When off, others will not see when you read messages.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.readReceiptsEnabled,
          onChanged: privacy.isLoading
              ? null
              : (value) => ref
                    .read(privacyProvider.notifier)
                    .setReadReceiptsEnabled(value),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Allow Unencrypted Direct Messages',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'When off, plaintext direct messages are blocked.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.allowUnencryptedDm,
          onChanged: privacy.isLoading
              ? null
              : (value) => ref
                    .read(privacyProvider.notifier)
                    .setAllowUnencryptedDm(value),
        ),
        const SizedBox(height: 24),
        Text(
          'Encryption',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Echo uses end-to-end encryption for encrypted direct messages. '
          'Your encryption keys are stored locally on this device.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _resetEncryptionKeys,
            icon: const Icon(Icons.warning_amber_outlined, size: 18),
            label: const Text('Reset Encryption Keys'),
            style: OutlinedButton.styleFrom(
              foregroundColor: EchoTheme.danger,
              side: const BorderSide(color: EchoTheme.danger),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildServerSection() {
    final serverUrl = ref.watch(serverUrlProvider);
    final displayHost = Uri.tryParse(serverUrl)?.host ?? serverUrl;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ListTile(
          leading: Icon(
            Icons.dns_outlined,
            color: context.textSecondary,
            size: 22,
          ),
          title: Text(
            'Connected to',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            displayHost,
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ),
        ListTile(
          leading: Icon(
            Icons.circle,
            color: _checkingHealth
                ? EchoTheme.warning
                : (_serverOnline ? EchoTheme.online : EchoTheme.danger),
            size: 12,
          ),
          title: Text(
            'Status',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            _checkingHealth
                ? 'Checking...'
                : (_serverOnline ? 'Online' : 'Offline'),
            style: TextStyle(
              color: _checkingHealth
                  ? EchoTheme.warning
                  : (_serverOnline ? EchoTheme.online : EchoTheme.danger),
              fontSize: 12,
            ),
          ),
          trailing: IconButton(
            icon: Icon(Icons.refresh, color: context.textMuted, size: 20),
            tooltip: 'Refresh status',
            onPressed: _checkServerHealth,
          ),
        ),
        if (_serverVersion != null)
          ListTile(
            leading: Icon(
              Icons.info_outline,
              color: context.textSecondary,
              size: 22,
            ),
            title: Text(
              'Server version',
              style: TextStyle(color: context.textPrimary, fontSize: 15),
            ),
            subtitle: Text(
              _serverVersion!,
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
          ),
        Divider(color: context.border, height: 32),
        ListTile(
          leading: Icon(
            Icons.swap_horiz_outlined,
            color: context.textSecondary,
            size: 22,
          ),
          title: Text(
            'Change server',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            'Connect to a different Echo server',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: context.textMuted,
            size: 20,
          ),
          onTap: _showChangeServerDialog,
        ),
      ],
    );
  }

  Widget _buildAudioSection() {
    final voice = ref.watch(voiceSettingsProvider);
    final notifier = ref.read(voiceSettingsProvider.notifier);

    const inputDevices = [
      {'id': 'default', 'name': 'Default Microphone'},
    ];
    const outputDevices = [
      {'id': 'default', 'name': 'Default Output'},
    ];

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Voice & Audio',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Configure voice device preferences and push-to-talk behavior.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 18),
        DropdownButtonFormField<String>(
          value: inputDevices.any((d) => d['id'] == voice.inputDeviceId)
              ? voice.inputDeviceId
              : 'default',
          decoration: const InputDecoration(labelText: 'Input Device'),
          items: inputDevices
              .map(
                (device) => DropdownMenuItem(
                  value: device['id'],
                  child: Text(device['name']!),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) notifier.setInputDevice(value);
          },
        ),
        const SizedBox(height: 12),
        DropdownButtonFormField<String>(
          value: outputDevices.any((d) => d['id'] == voice.outputDeviceId)
              ? voice.outputDeviceId
              : 'default',
          decoration: const InputDecoration(labelText: 'Output Device'),
          items: outputDevices
              .map(
                (device) => DropdownMenuItem(
                  value: device['id'],
                  child: Text(device['name']!),
                ),
              )
              .toList(),
          onChanged: (value) {
            if (value != null) notifier.setOutputDevice(value);
          },
        ),
        const SizedBox(height: 16),
        Text(
          'Input Sensitivity',
          style: TextStyle(color: context.textPrimary, fontSize: 13),
        ),
        Slider(
          value: voice.inputGain,
          min: 0,
          max: 2,
          divisions: 20,
          label: voice.inputGain.toStringAsFixed(1),
          onChanged: notifier.setInputGain,
        ),
        const SizedBox(height: 8),
        Text(
          'Output Volume',
          style: TextStyle(color: context.textPrimary, fontSize: 13),
        ),
        Slider(
          value: voice.outputVolume,
          min: 0,
          max: 1,
          divisions: 20,
          label: (voice.outputVolume * 100).round().toString(),
          onChanged: notifier.setOutputVolume,
        ),
        const SizedBox(height: 10),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Push-to-Talk',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'When enabled, your mic transmits only while push-to-talk is active.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: voice.pushToTalkEnabled,
          onChanged: notifier.setPushToTalkEnabled,
        ),
      ],
    );
  }

  Widget _buildAppearanceSection() {
    final currentTheme = ref.watch(themeProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Theme',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        _ThemeOption(
          label: 'System',
          subtitle: 'Follow your device settings',
          icon: Icons.settings_brightness_outlined,
          isSelected: currentTheme == AppThemeSelection.system,
          onTap: () => ref
              .read(themeProvider.notifier)
              .setTheme(AppThemeSelection.system),
        ),
        const SizedBox(height: 8),
        _ThemeOption(
          label: 'Dark',
          subtitle: 'Easy on the eyes',
          icon: Icons.dark_mode_outlined,
          isSelected: currentTheme == AppThemeSelection.dark,
          onTap: () =>
              ref.read(themeProvider.notifier).setTheme(AppThemeSelection.dark),
        ),
        const SizedBox(height: 8),
        _ThemeOption(
          label: 'Light',
          subtitle: 'Classic bright look',
          icon: Icons.light_mode_outlined,
          isSelected: currentTheme == AppThemeSelection.light,
          onTap: () => ref
              .read(themeProvider.notifier)
              .setTheme(AppThemeSelection.light),
        ),
        const SizedBox(height: 8),
        _ThemeOption(
          label: 'Graphite',
          subtitle: 'High-contrast dark with teal accents',
          icon: Icons.water_drop_outlined,
          isSelected: currentTheme == AppThemeSelection.graphite,
          onTap: () => ref
              .read(themeProvider.notifier)
              .setTheme(AppThemeSelection.graphite),
        ),
      ],
    );
  }

  Future<void> _deleteAccount() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: const Text(
          'Delete Account',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will permanently delete your account and all data. '
          'This cannot be undone.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Delete My Account'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse('$serverUrl/api/users/me'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        // Clear all local data and navigate to login
        ref.read(websocketProvider.notifier).disconnect();
        ref.read(chatProvider.notifier).clear();
        ref.read(authProvider.notifier).logout();
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('Account deleted successfully.')),
          );
          context.go('/login');
        }
      } else {
        String errorMsg = 'Failed to delete account';
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = data['error'] as String? ?? errorMsg;
        } catch (_) {}
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text(errorMsg)));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('Network error. Please try again.')),
        );
      }
    }
  }

  Widget _buildCheckForUpdates() {
    final update = ref.watch(updateProvider);
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: update.checking
              ? null
              : () => ref.read(updateProvider.notifier).check(force: true),
          icon: update.checking
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.textMuted,
                  ),
                )
              : Icon(Icons.refresh, size: 16),
          label: Text(update.checking ? 'Checking...' : 'Check for Updates'),
          style: OutlinedButton.styleFrom(
            foregroundColor: context.textSecondary,
            side: BorderSide(color: context.border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: 12),
        if (update.latestVersion != null && !update.checking)
          Text(
            update.updateAvailable
                ? 'v${update.latestVersion} available'
                : 'Up to date',
            style: TextStyle(
              color: update.updateAvailable
                  ? context.accent
                  : context.textMuted,
              fontSize: 13,
            ),
          ),
      ],
    );
  }

  Widget _buildAboutSection() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Echo Messenger',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Client version: $appVersion',
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
        const SizedBox(height: 4),
        Text(
          'Server version: ${_serverVersion ?? "unknown"}',
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
        const SizedBox(height: 16),
        _buildCheckForUpdates(),
        const SizedBox(height: 24),
        Text(
          'Open source',
          style: TextStyle(
            color: context.accent,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Echo is a decentralized, end-to-end encrypted messenger. '
          'Contributions and self-hosting are welcome.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 32),
        Divider(color: context.border),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _deleteAccount,
            icon: const Icon(Icons.delete_forever_outlined, size: 18),
            label: const Text('Delete Account'),
            style: OutlinedButton.styleFrom(
              foregroundColor: EchoTheme.danger,
              side: const BorderSide(color: EchoTheme.danger),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Full settings screen (used on mobile route / standalone)
// ---------------------------------------------------------------------------

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  SettingsSection _selectedSection = SettingsSection.account;
  SettingsSection? _mobileDetailSection;

  void _logout() {
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    ref.read(authProvider.notifier).logout();
    context.go('/login');
  }

  bool get _isMobile => MediaQuery.of(context).size.width < 600;

  @override
  Widget build(BuildContext context) {
    if (_isMobile) {
      return _buildMobileLayout();
    }
    return _buildDesktopLayout();
  }

  Widget _buildMobileLayout() {
    if (_mobileDetailSection != null) {
      return Scaffold(
        backgroundColor: context.mainBg,
        appBar: AppBar(
          backgroundColor: context.sidebarBg,
          title: Text(
            settingsSectionLabel(_mobileDetailSection!),
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          leading: IconButton(
            icon: Icon(Icons.arrow_back, color: context.textSecondary),
            onPressed: () => setState(() => _mobileDetailSection = null),
          ),
        ),
        body: SettingsContent(
          key: ValueKey(_mobileDetailSection),
          section: _mobileDetailSection!,
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.mainBg,
      appBar: AppBar(
        backgroundColor: context.sidebarBg,
        title: Text(
          'Settings',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.textSecondary),
          onPressed: () => context.pop(),
        ),
      ),
      body: SettingsNavList(
        onTap: (section) => setState(() => _mobileDetailSection = section),
        onLogout: _logout,
      ),
    );
  }

  Widget _buildDesktopLayout() {
    return Scaffold(
      backgroundColor: context.mainBg,
      appBar: AppBar(
        backgroundColor: context.sidebarBg,
        title: Text(
          'Settings',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.textSecondary),
          onPressed: () => context.pop(),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 200,
                child: SettingsNavList(
                  selected: _selectedSection,
                  onTap: (section) =>
                      setState(() => _selectedSection = section),
                  onLogout: _logout,
                ),
              ),
              Container(width: 1, color: context.border),
              Expanded(
                child: SettingsContent(
                  key: ValueKey(_selectedSection),
                  section: _selectedSection,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _ThemeOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeOption({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Material(
      color: isSelected ? context.accentLight : Colors.transparent,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(10),
        hoverColor: context.surfaceHover,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected ? context.accent : context.border,
              width: 1,
            ),
          ),
          child: Row(
            children: [
              Icon(
                icon,
                size: 22,
                color: isSelected ? context.accent : context.textSecondary,
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: TextStyle(
                        color: isSelected
                            ? context.accent
                            : context.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      subtitle,
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                    ),
                  ],
                ),
              ),
              if (isSelected)
                Icon(Icons.check_circle, size: 20, color: context.accent),
            ],
          ),
        ),
      ),
    );
  }
}
