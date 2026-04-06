import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import 'settings/about_section.dart';
import 'settings/account_section.dart';
import 'settings/appearance_section.dart';
import 'settings/audio_section.dart';
import 'settings/debug_section.dart';
import 'settings/privacy_section.dart';

/// Section identifiers for the settings navigation.
enum SettingsSection { account, privacy, audio, appearance, about, debug }

/// Returns a human-readable label for a settings section.
String settingsSectionLabel(SettingsSection section) {
  switch (section) {
    case SettingsSection.account:
      return 'Account';
    case SettingsSection.privacy:
      return 'Privacy';
    case SettingsSection.audio:
      return 'Audio';
    case SettingsSection.appearance:
      return 'Appearance';
    case SettingsSection.about:
      return 'About';
    case SettingsSection.debug:
      return 'Debug Logs';
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
        _navItem(
          context: context,
          icon: Icons.bug_report_outlined,
          label: 'Debug Logs',
          section: SettingsSection.debug,
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
      case SettingsSection.audio:
        return const AudioSection();
      case SettingsSection.appearance:
        return const AppearanceSection();
      case SettingsSection.about:
        return const AboutSection();
      case SettingsSection.debug:
        return const DebugSection();
    }
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
