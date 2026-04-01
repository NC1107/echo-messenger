import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';

class SettingsScreen extends ConsumerStatefulWidget {
  const SettingsScreen({super.key});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  bool _serverOnline = false;
  bool _checkingHealth = true;
  String? _serverVersion;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkServerHealth();
    });
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
        } catch (_) {
          // Health endpoint may not return JSON
        }
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

  void _logout(BuildContext context, WidgetRef ref) {
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    ref.read(authProvider.notifier).logout();
    context.go('/login');
  }

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
      // Re-check health with the new server
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

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final username = authState.username ?? 'Unknown';
    final serverUrl = ref.watch(serverUrlProvider);
    final displayHost = Uri.tryParse(serverUrl)?.host ?? serverUrl;

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
          constraints: const BoxConstraints(maxWidth: 600),
          child: ListView(
            children: [
              const SizedBox(height: 16),
              // User info
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: Row(
                  children: [
                    CircleAvatar(
                      radius: 28,
                      backgroundColor: EchoTheme.accent,
                      child: Text(
                        username.isNotEmpty ? username[0].toUpperCase() : '?',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 22,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                    const SizedBox(width: 16),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          username,
                          style: const TextStyle(
                            color: EchoTheme.textPrimary,
                            fontSize: 18,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                        const SizedBox(height: 2),
                        const Text(
                          'Online',
                          style: TextStyle(
                            color: EchoTheme.textMuted,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),
              const Divider(color: EchoTheme.border, height: 1),

              // --- Server section ---
              Padding(
                padding: const EdgeInsets.fromLTRB(20, 16, 20, 8),
                child: Text(
                  'SERVER',
                  style: TextStyle(
                    color: EchoTheme.textMuted,
                    fontSize: 11,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
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
                  style: const TextStyle(
                    color: EchoTheme.textMuted,
                    fontSize: 12,
                  ),
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
              // Server version (if available)
              if (_serverVersion != null)
                ListTile(
                  leading: const Icon(
                    Icons.info_outline,
                    color: EchoTheme.textSecondary,
                    size: 22,
                  ),
                  title: const Text(
                    'Server version',
                    style: TextStyle(
                      color: EchoTheme.textPrimary,
                      fontSize: 15,
                    ),
                  ),
                  subtitle: Text(
                    _serverVersion!,
                    style: const TextStyle(
                      color: EchoTheme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ),
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
              const Divider(color: EchoTheme.border, height: 1),

              // Appearance
              _SettingsTile(
                icon: Icons.palette_outlined,
                title: 'Appearance',
                subtitle: 'Coming soon',
                enabled: false,
              ),
              // Notifications
              _SettingsTile(
                icon: Icons.notifications_outlined,
                title: 'Notifications',
                subtitle: 'Coming soon',
                enabled: false,
              ),
              // Privacy
              _SettingsTile(
                icon: Icons.lock_outline,
                title: 'Privacy',
                subtitle: 'Coming soon',
                enabled: false,
              ),
              const SizedBox(height: 16),
              const Divider(color: EchoTheme.border, height: 1),
              const SizedBox(height: 8),
              // Version info
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 20,
                  vertical: 8,
                ),
                child: Text(
                  'Echo Messenger v${_serverVersion ?? "0.1.0"}',
                  style: const TextStyle(
                    color: EchoTheme.textMuted,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(height: 16),
              // Logout button
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20),
                child: SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: () => _logout(context, ref),
                    icon: const Icon(
                      Icons.logout,
                      size: 18,
                      color: EchoTheme.danger,
                    ),
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
              const SizedBox(height: 32),
            ],
          ),
        ),
      ),
    );
  }
}

class _SettingsTile extends StatelessWidget {
  final IconData icon;
  final String title;
  final String subtitle;
  final bool enabled;
  final VoidCallback? onTap;

  const _SettingsTile({
    required this.icon,
    required this.title,
    required this.subtitle,
    this.enabled = true,
    this.onTap, // ignore: unused_element_parameter
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      leading: Icon(
        icon,
        color: enabled ? EchoTheme.textSecondary : EchoTheme.textMuted,
        size: 22,
      ),
      title: Text(
        title,
        style: TextStyle(
          color: enabled ? EchoTheme.textPrimary : EchoTheme.textMuted,
          fontSize: 15,
        ),
      ),
      subtitle: Text(
        subtitle,
        style: const TextStyle(color: EchoTheme.textMuted, fontSize: 12),
      ),
      trailing: enabled
          ? const Icon(
              Icons.chevron_right,
              color: EchoTheme.textMuted,
              size: 20,
            )
          : null,
      enabled: enabled,
      onTap: onTap,
    );
  }
}
