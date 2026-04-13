import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import 'settings/about_section.dart';
import 'settings/accessibility_section.dart';
import 'settings/account_section.dart';
import 'settings/appearance_section.dart';
import 'settings/audio_section.dart';
import 'settings/data_storage_section.dart';
import 'settings/debug_section.dart';
import 'settings/notification_section.dart';
import 'settings/privacy_section.dart';

/// Section identifiers for the settings navigation.
enum SettingsSection {
  account,
  privacy,
  notifications,
  audio,
  appearance,
  accessibility,
  about,
  dataStorage,
  debug,
}

/// Returns a human-readable label for a settings section.
String settingsSectionLabel(SettingsSection section) {
  switch (section) {
    case SettingsSection.account:
      return 'Account';
    case SettingsSection.privacy:
      return 'Privacy & Safety';
    case SettingsSection.notifications:
      return 'Notifications';
    case SettingsSection.audio:
      return 'Voice & Video';
    case SettingsSection.appearance:
      return 'Appearance';
    case SettingsSection.accessibility:
      return 'Accessibility';
    case SettingsSection.about:
      return 'About';
    case SettingsSection.dataStorage:
      return 'Data & Storage';
    case SettingsSection.debug:
      return 'Debug Logs';
  }
}

/// Shared label used in the nav list, dialog title, and dialog button.
const _logOutLabel = 'Log Out';

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

  Widget _categoryHeader(BuildContext context, String label) {
    return Padding(
      padding: const EdgeInsets.only(left: 16, top: 16, bottom: 4),
      child: Text(
        label,
        style: TextStyle(
          color: context.textMuted,
          fontSize: 11,
          fontWeight: FontWeight.w600,
          letterSpacing: 0.5,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        const SizedBox(height: 8),
        _categoryHeader(context, 'USER SETTINGS'),
        _navItem(
          context: context,
          icon: Icons.person_outlined,
          label: 'Account',
          section: SettingsSection.account,
        ),
        _navItem(
          context: context,
          icon: Icons.lock_outline,
          label: 'Privacy & Safety',
          section: SettingsSection.privacy,
        ),
        _navItem(
          context: context,
          icon: Icons.notifications_outlined,
          label: 'Notifications',
          section: SettingsSection.notifications,
        ),
        _navItem(
          context: context,
          icon: Icons.graphic_eq,
          label: 'Voice & Video',
          section: SettingsSection.audio,
        ),
        _categoryHeader(context, 'APP SETTINGS'),
        _navItem(
          context: context,
          icon: Icons.palette_outlined,
          label: 'Appearance',
          section: SettingsSection.appearance,
        ),
        _navItem(
          context: context,
          icon: Icons.accessibility_new,
          label: 'Accessibility',
          section: SettingsSection.accessibility,
        ),
        // Logout button in nav list
        _navItem(
          context: context,
          icon: Icons.logout,
          label: _logOutLabel,
          section: null,
          isLogout: true,
        ),
        _categoryHeader(context, 'ADVANCED'),
        _navItem(
          context: context,
          icon: Icons.info_outline,
          label: 'About',
          section: SettingsSection.about,
        ),
        _navItem(
          context: context,
          icon: Icons.storage_outlined,
          label: 'Data & Storage',
          section: SettingsSection.dataStorage,
        ),
        _navItem(
          context: context,
          icon: Icons.bug_report_outlined,
          label: 'Debug Logs',
          section: SettingsSection.debug,
        ),
        const Spacer(),
      ],
    );
  }

  Widget _navItem({
    required BuildContext context,
    required IconData icon,
    required String label,
    required SettingsSection? section,
    bool isLogout = false,
  }) {
    final isSelected = !isLogout && selected == section;

    final Color iconColor;
    if (isLogout) {
      iconColor = EchoTheme.danger;
    } else if (isSelected) {
      iconColor = context.accent;
    } else {
      iconColor = context.textSecondary;
    }

    final Color labelColor;
    if (isLogout) {
      labelColor = EchoTheme.danger;
    } else if (isSelected) {
      labelColor = context.accent;
    } else {
      labelColor = context.textPrimary;
    }

    return Semantics(
      label: isLogout ? 'log out' : '$label settings',
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? context.accentLight : Colors.transparent,
        child: InkWell(
          onTap: isLogout ? onLogout : () => onTap(section!),
          hoverColor: context.surfaceHover,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
            child: Row(
              children: [
                Icon(icon, size: 20, color: iconColor),
                const SizedBox(width: 12),
                Text(
                  label,
                  style: TextStyle(
                    color: labelColor,
                    fontSize: 14,
                    fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Settings content widget (reusable)
// ---------------------------------------------------------------------------

class SettingsContent extends StatelessWidget {
  final SettingsSection section;

  const SettingsContent({super.key, required this.section});

  @override
  Widget build(BuildContext context) {
    switch (section) {
      case SettingsSection.account:
        return const AccountSection();
      case SettingsSection.privacy:
        return const PrivacySection();
      case SettingsSection.notifications:
        return const NotificationSection();
      case SettingsSection.audio:
        return const AudioSection();
      case SettingsSection.appearance:
        return const AppearanceSection();
      case SettingsSection.accessibility:
        return const AccessibilitySection();
      case SettingsSection.about:
        return const AboutSection();
      case SettingsSection.dataStorage:
        return const DataStorageSection();
      case SettingsSection.debug:
        return const DebugSection();
    }
  }
}

// ---------------------------------------------------------------------------
// Full settings screen (used on mobile route / standalone)
// ---------------------------------------------------------------------------

class SettingsScreen extends ConsumerStatefulWidget {
  /// Optional callback for embedded mobile usage (back button in narrow layout).
  final VoidCallback? onBack;

  const SettingsScreen({super.key, this.onBack});

  @override
  ConsumerState<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends ConsumerState<SettingsScreen> {
  SettingsSection _selectedSection = SettingsSection.account;
  SettingsSection? _mobileDetailSection;

  Future<void> _logout() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          _logOutLabel,
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'Are you sure you want to log out?',
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
            child: const Text(_logOutLabel),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    await ref.read(cryptoProvider.notifier).resetState();
    ref.read(authProvider.notifier).logout();
    if (mounted) context.go('/login');
  }

  bool get _isMobile => Responsive.isMobile(context);

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
          onPressed: () {
            if (widget.onBack != null) {
              widget.onBack!();
            } else {
              context.pop();
            }
          },
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
      body: Row(
        children: [
          // Nav sidebar -- flush left, matches conversation sidebar
          Container(
            width: 250,
            color: context.sidebarBg,
            child: Column(
              children: [
                // Header with back arrow
                SizedBox(
                  height: 56,
                  child: Row(
                    children: [
                      const SizedBox(width: 4),
                      IconButton(
                        icon: Icon(
                          Icons.arrow_back,
                          color: context.textSecondary,
                        ),
                        onPressed: () => context.pop(),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Settings',
                        style: TextStyle(
                          color: context.textPrimary,
                          fontSize: 18,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ],
                  ),
                ),
                Container(height: 1, color: context.border),
                Expanded(
                  child: SettingsNavList(
                    selected: _selectedSection,
                    onTap: (section) =>
                        setState(() => _selectedSection = section),
                    onLogout: _logout,
                  ),
                ),
              ],
            ),
          ),
          Container(width: 1, color: context.border),
          // Content area -- fills remaining width
          Expanded(
            child: SettingsContent(
              key: ValueKey(_selectedSection),
              section: _selectedSection,
            ),
          ),
        ],
      ),
    );
  }
}
