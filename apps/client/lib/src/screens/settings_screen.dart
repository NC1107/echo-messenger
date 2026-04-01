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
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';

/// Section identifiers for the settings navigation.
enum _SettingsSection { account, privacy, server, appearance, about }

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _serverOnline = false;
  bool _checkingHealth = true;
  String? _serverVersion;

  _SettingsSection _selectedSection = _SettingsSection.account;

  /// On mobile, null means we show the nav list; non-null means we pushed into
  /// the detail view for that section.
  _SettingsSection? _mobileDetailSection;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkServerHealth();
    });
  }

  // ---------------------------------------------------------------------------
  // Server health (preserved from original)
  // ---------------------------------------------------------------------------

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

  // ---------------------------------------------------------------------------
  // Logout
  // ---------------------------------------------------------------------------

  void _logout(BuildContext context, WidgetRef ref) {
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    ref.read(authProvider.notifier).logout();
    context.go('/login');
  }

  // ---------------------------------------------------------------------------
  // Change server dialog (preserved from original)
  // ---------------------------------------------------------------------------

  Future<void> _showChangeServerDialog() async {
    final currentUrl = ref.read(serverUrlProvider);
    final controller = TextEditingController(text: currentUrl);

    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
        ),
        title: const Text(
          'Change Server',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Enter the URL of an Echo server. You will need to log in again after changing servers.',
              style: TextStyle(
                color: EchoTheme.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: const TextStyle(
                color: EchoTheme.textPrimary,
                fontSize: 14,
              ),
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

  // ---------------------------------------------------------------------------
  // Avatar upload
  // ---------------------------------------------------------------------------

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
      if (mounted) {
        if (streamedResponse.statusCode == 200) {
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

  // ---------------------------------------------------------------------------
  // QR code dialog
  // ---------------------------------------------------------------------------

  void _showQrCodeDialog() {
    final authState = ref.read(authProvider);
    final userId = authState.userId ?? '';
    final username = authState.username ?? 'Unknown';
    final echoUri = 'echo://user/$userId';

    showDialog(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: EchoTheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: const BorderSide(color: EchoTheme.border),
        ),
        title: const Text(
          'My QR Code',
          style: TextStyle(
            color: EchoTheme.textPrimary,
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
              style: const TextStyle(
                color: EchoTheme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              echoUri,
              style: const TextStyle(color: EchoTheme.textMuted, fontSize: 12),
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

  // ---------------------------------------------------------------------------
  // Layout
  // ---------------------------------------------------------------------------

  bool get _isMobile => MediaQuery.of(context).size.width < 600;

  @override
  Widget build(BuildContext context) {
    if (_isMobile) {
      return _buildMobileLayout();
    }
    return _buildDesktopLayout();
  }

  // ---------------------------------------------------------------------------
  // Mobile layout: nav list or detail
  // ---------------------------------------------------------------------------

  Widget _buildMobileLayout() {
    if (_mobileDetailSection != null) {
      return Scaffold(
        backgroundColor: EchoTheme.mainBg,
        appBar: AppBar(
          backgroundColor: EchoTheme.sidebarBg,
          title: Text(
            _sectionLabel(_mobileDetailSection!),
            style: const TextStyle(
              color: EchoTheme.textPrimary,
              fontSize: 18,
              fontWeight: FontWeight.w600,
            ),
          ),
          leading: IconButton(
            icon: const Icon(Icons.arrow_back, color: EchoTheme.textSecondary),
            onPressed: () => setState(() => _mobileDetailSection = null),
          ),
        ),
        body: _buildSectionContent(_mobileDetailSection!),
      );
    }

    return Scaffold(
      backgroundColor: EchoTheme.mainBg,
      appBar: AppBar(
        backgroundColor: EchoTheme.sidebarBg,
        title: const Text(
          'Settings',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: EchoTheme.textSecondary),
          onPressed: () => context.pop(),
        ),
      ),
      body: _buildNavList(
        onTap: (section) => setState(() => _mobileDetailSection = section),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Desktop layout: two-panel
  // ---------------------------------------------------------------------------

  Widget _buildDesktopLayout() {
    return Scaffold(
      backgroundColor: EchoTheme.mainBg,
      appBar: AppBar(
        backgroundColor: EchoTheme.sidebarBg,
        title: const Text(
          'Settings',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back, color: EchoTheme.textSecondary),
          onPressed: () => context.pop(),
        ),
      ),
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // Left nav panel (200px)
              SizedBox(
                width: 200,
                child: _buildNavList(
                  onTap: (section) =>
                      setState(() => _selectedSection = section),
                  selected: _selectedSection,
                ),
              ),
              Container(width: 1, color: EchoTheme.border),
              // Right content panel
              Expanded(child: _buildSectionContent(_selectedSection)),
            ],
          ),
        ),
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Navigation list
  // ---------------------------------------------------------------------------

  Widget _buildNavList({
    required void Function(_SettingsSection) onTap,
    _SettingsSection? selected,
  }) {
    return Column(
      children: [
        const SizedBox(height: 8),
        _navItem(
          icon: Icons.person_outlined,
          label: 'Account',
          section: _SettingsSection.account,
          selected: selected,
          onTap: onTap,
        ),
        _navItem(
          icon: Icons.lock_outline,
          label: 'Privacy',
          section: _SettingsSection.privacy,
          selected: selected,
          onTap: onTap,
        ),
        _navItem(
          icon: Icons.dns_outlined,
          label: 'Server',
          section: _SettingsSection.server,
          selected: selected,
          onTap: onTap,
        ),
        _navItem(
          icon: Icons.palette_outlined,
          label: 'Appearance',
          section: _SettingsSection.appearance,
          selected: selected,
          onTap: onTap,
        ),
        _navItem(
          icon: Icons.info_outline,
          label: 'About',
          section: _SettingsSection.about,
          selected: selected,
          onTap: onTap,
        ),
        const Spacer(),
        // Logout button
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 16),
          child: SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: () => _logout(context, ref),
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
    required IconData icon,
    required String label,
    required _SettingsSection section,
    required _SettingsSection? selected,
    required void Function(_SettingsSection) onTap,
  }) {
    final isSelected = selected == section;
    return Material(
      color: isSelected ? EchoTheme.accentLight : Colors.transparent,
      child: InkWell(
        onTap: () => onTap(section),
        hoverColor: EchoTheme.surfaceHover,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          child: Row(
            children: [
              Icon(
                icon,
                size: 20,
                color: isSelected ? EchoTheme.accent : EchoTheme.textSecondary,
              ),
              const SizedBox(width: 12),
              Text(
                label,
                style: TextStyle(
                  color: isSelected ? EchoTheme.accent : EchoTheme.textPrimary,
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

  // ---------------------------------------------------------------------------
  // Section content router
  // ---------------------------------------------------------------------------

  String _sectionLabel(_SettingsSection section) {
    switch (section) {
      case _SettingsSection.account:
        return 'Account';
      case _SettingsSection.privacy:
        return 'Privacy';
      case _SettingsSection.server:
        return 'Server';
      case _SettingsSection.appearance:
        return 'Appearance';
      case _SettingsSection.about:
        return 'About';
    }
  }

  Widget _buildSectionContent(_SettingsSection section) {
    switch (section) {
      case _SettingsSection.account:
        return _buildAccountSection();
      case _SettingsSection.privacy:
        return _buildPrivacySection();
      case _SettingsSection.server:
        return _buildServerSection();
      case _SettingsSection.appearance:
        return _buildAppearanceSection();
      case _SettingsSection.about:
        return _buildAboutSection();
    }
  }

  // ---------------------------------------------------------------------------
  // Account section
  // ---------------------------------------------------------------------------

  Widget _buildAccountSection() {
    final authState = ref.watch(authProvider);
    final username = authState.username ?? 'Unknown';

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Avatar + username
        Row(
          children: [
            Stack(
              children: [
                CircleAvatar(
                  radius: 32,
                  backgroundColor: EchoTheme.accent,
                  child: Text(
                    username.isNotEmpty ? username[0].toUpperCase() : '?',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 26,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
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
                        color: EchoTheme.surface,
                        shape: BoxShape.circle,
                        border: Border.all(color: EchoTheme.border, width: 2),
                      ),
                      child: const Icon(
                        Icons.edit,
                        size: 12,
                        color: EchoTheme.textSecondary,
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
                  style: const TextStyle(
                    color: EchoTheme.textPrimary,
                    fontSize: 20,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 2),
                const Text(
                  'Online',
                  style: TextStyle(color: EchoTheme.textMuted, fontSize: 13),
                ),
              ],
            ),
          ],
        ),
        const SizedBox(height: 24),
        // Upload Avatar button
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _uploadAvatar,
            icon: const Icon(Icons.upload, size: 18),
            label: const Text('Upload Avatar'),
          ),
        ),
        const SizedBox(height: 12),
        // QR Code button
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

  // ---------------------------------------------------------------------------
  // Privacy section
  // ---------------------------------------------------------------------------

  Widget _buildPrivacySection() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.lock_outline, size: 48, color: EchoTheme.textMuted),
          SizedBox(height: 16),
          Text(
            'Coming soon',
            style: TextStyle(
              color: EchoTheme.textSecondary,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Privacy settings will be available in a future update.',
            style: TextStyle(color: EchoTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // Server section
  // ---------------------------------------------------------------------------

  Widget _buildServerSection() {
    final serverUrl = ref.watch(serverUrlProvider);
    final displayHost = Uri.tryParse(serverUrl)?.host ?? serverUrl;

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Connected to
        ListTile(
          leading: const Icon(
            Icons.dns_outlined,
            color: EchoTheme.textSecondary,
            size: 22,
          ),
          title: const Text(
            'Connected to',
            style: TextStyle(color: EchoTheme.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            displayHost,
            style: const TextStyle(color: EchoTheme.textMuted, fontSize: 12),
          ),
        ),
        // Status
        ListTile(
          leading: Icon(
            Icons.circle,
            color: _checkingHealth
                ? EchoTheme.warning
                : (_serverOnline ? EchoTheme.online : EchoTheme.danger),
            size: 12,
          ),
          title: const Text(
            'Status',
            style: TextStyle(color: EchoTheme.textPrimary, fontSize: 15),
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
            icon: const Icon(
              Icons.refresh,
              color: EchoTheme.textMuted,
              size: 20,
            ),
            tooltip: 'Refresh status',
            onPressed: _checkServerHealth,
          ),
        ),
        // Server version
        if (_serverVersion != null)
          ListTile(
            leading: const Icon(
              Icons.info_outline,
              color: EchoTheme.textSecondary,
              size: 22,
            ),
            title: const Text(
              'Server version',
              style: TextStyle(color: EchoTheme.textPrimary, fontSize: 15),
            ),
            subtitle: Text(
              _serverVersion!,
              style: const TextStyle(color: EchoTheme.textMuted, fontSize: 12),
            ),
          ),
        const Divider(color: EchoTheme.border, height: 32),
        // Change server
        ListTile(
          leading: const Icon(
            Icons.swap_horiz_outlined,
            color: EchoTheme.textSecondary,
            size: 22,
          ),
          title: const Text(
            'Change server',
            style: TextStyle(color: EchoTheme.textPrimary, fontSize: 15),
          ),
          subtitle: const Text(
            'Connect to a different Echo server',
            style: TextStyle(color: EchoTheme.textMuted, fontSize: 12),
          ),
          trailing: const Icon(
            Icons.chevron_right,
            color: EchoTheme.textMuted,
            size: 20,
          ),
          onTap: _showChangeServerDialog,
        ),
      ],
    );
  }

  // ---------------------------------------------------------------------------
  // Appearance section
  // ---------------------------------------------------------------------------

  Widget _buildAppearanceSection() {
    return const Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.palette_outlined, size: 48, color: EchoTheme.textMuted),
          SizedBox(height: 16),
          Text(
            'Coming soon',
            style: TextStyle(
              color: EchoTheme.textSecondary,
              fontSize: 16,
              fontWeight: FontWeight.w500,
            ),
          ),
          SizedBox(height: 8),
          Text(
            'Appearance settings will be available in a future update.',
            style: TextStyle(color: EchoTheme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // About section
  // ---------------------------------------------------------------------------

  Widget _buildAboutSection() {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        const Text(
          'Echo Messenger',
          style: TextStyle(
            color: EchoTheme.textPrimary,
            fontSize: 20,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Version ${_serverVersion ?? "0.1.0"}',
          style: const TextStyle(color: EchoTheme.textMuted, fontSize: 14),
        ),
        const SizedBox(height: 24),
        const Text(
          'Open source',
          style: TextStyle(
            color: EchoTheme.accent,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        const Text(
          'Echo is a decentralized, end-to-end encrypted messenger. '
          'Contributions and self-hosting are welcome.',
          style: TextStyle(
            color: EchoTheme.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
      ],
    );
  }
}
