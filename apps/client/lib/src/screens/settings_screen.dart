import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';

class SettingsScreen extends ConsumerWidget {
  const SettingsScreen({super.key});

  void _logout(BuildContext context, WidgetRef ref) {
    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    ref.read(authProvider.notifier).logout();
    context.go('/login');
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final authState = ref.watch(authProvider);
    final username = authState.username ?? 'Unknown';

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
      body: ListView(
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
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 20, vertical: 8),
            child: Text(
              'Echo Messenger v0.1.0',
              style: TextStyle(
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
          const SizedBox(height: 32),
        ],
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
        style: const TextStyle(
          color: EchoTheme.textMuted,
          fontSize: 12,
        ),
      ),
      trailing: enabled
          ? const Icon(Icons.chevron_right, color: EchoTheme.textMuted, size: 20)
          : null,
      enabled: enabled,
      onTap: onTap,
    );
  }
}
