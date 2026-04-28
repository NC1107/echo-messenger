import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/chat_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/theme_provider.dart';
import '../providers/websocket_provider.dart';
import '../theme/echo_theme.dart';
import '../theme/responsive.dart';
import '../version.dart';
import '../widgets/settings/card_row.dart';
import '../widgets/settings/section_header.dart';
import '../widgets/settings/user_header_card.dart';
import 'settings/about_section.dart';
import 'settings/account_section.dart';
import 'settings/appearance_section.dart';
import 'settings/data_storage_section.dart';
import 'settings/devices_section.dart';
import 'settings/notification_section.dart';
import 'settings/privacy_section.dart';

/// Section identifiers for the redesigned settings layout.
///
/// Groups (visual):
///   ACCOUNT PREFERENCES → appearance, notifications, voiceVideo, privacy,
///                         devices, dataStorage
///   ECHO                → about (+ Log out, handled separately)
///
/// `profile` has no row in the list — it's reached only via the
/// [UserHeaderCard] tap target at the top of [SettingsRootView].
enum SettingsSection {
  profile,
  appearance,
  notifications,
  voiceVideo,
  privacy,
  devices,
  dataStorage,
  about,
}

/// Returns a human-readable label for a settings section.
String settingsSectionLabel(SettingsSection section) {
  switch (section) {
    case SettingsSection.profile:
      return 'Profile';
    case SettingsSection.appearance:
      return 'Appearance';
    case SettingsSection.notifications:
      return 'Notifications';
    case SettingsSection.voiceVideo:
      return 'Voice & Video';
    case SettingsSection.privacy:
      return 'Privacy';
    case SettingsSection.devices:
      return 'Devices';
    case SettingsSection.dataStorage:
      return 'Storage';
    case SettingsSection.about:
      return 'About';
  }
}

/// Shared label used in the dialog title and confirm button.
const _logOutLabel = 'Log out';

// ---------------------------------------------------------------------------
// Settings content widget (reusable)
// ---------------------------------------------------------------------------

/// Maps a [SettingsSection] to the screen widget that renders its detail.
class SettingsContent extends StatelessWidget {
  final SettingsSection section;

  const SettingsContent({super.key, required this.section});

  @override
  Widget build(BuildContext context) {
    switch (section) {
      case SettingsSection.profile:
        return const AccountSection();
      case SettingsSection.appearance:
        return const AppearanceSection();
      case SettingsSection.notifications:
        return const NotificationSection();
      case SettingsSection.voiceVideo:
        return const VoiceVideoSection();
      case SettingsSection.privacy:
        return const PrivacySection();
      case SettingsSection.devices:
        return const DevicesSection();
      case SettingsSection.dataStorage:
        return const DataStorageSection();
      case SettingsSection.about:
        return const AboutSection();
    }
  }
}

// ---------------------------------------------------------------------------
// Settings root view (shared by mobile + desktop)
// ---------------------------------------------------------------------------

/// Sectioned card list rendered as the entry point of the Settings screen.
/// Used as the body on mobile (full screen) and as the left pane on desktop.
class SettingsRootView extends ConsumerWidget {
  final SettingsSection? selected;
  final void Function(SettingsSection) onTap;
  final VoidCallback onLogout;

  const SettingsRootView({
    super.key,
    this.selected,
    required this.onTap,
    required this.onLogout,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final themeSelection = ref.watch(themeProvider);
    final appearanceTrailing = _themeLabel(themeSelection);

    return SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(0, 8, 0, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          UserHeaderCard(onTap: () => onTap(SettingsSection.profile)),
          const SectionHeader('Account preferences'),
          _CardGroup(
            children: [
              _row(
                context,
                icon: Icons.palette_outlined,
                iconColor: const Color(0xFF8B5CF6),
                section: SettingsSection.appearance,
                trailing: appearanceTrailing,
              ),
              _row(
                context,
                icon: Icons.notifications_outlined,
                iconColor: const Color(0xFFEF4444),
                section: SettingsSection.notifications,
              ),
              _row(
                context,
                icon: Icons.graphic_eq,
                iconColor: const Color(0xFF22C55E),
                section: SettingsSection.voiceVideo,
              ),
              _row(
                context,
                icon: Icons.lock_outline,
                iconColor: const Color(0xFF14B8A6),
                section: SettingsSection.privacy,
              ),
              _row(
                context,
                icon: Icons.devices_outlined,
                iconColor: const Color(0xFFF59E0B),
                section: SettingsSection.devices,
              ),
              _row(
                context,
                icon: Icons.folder_outlined,
                iconColor: context.textPrimary,
                section: SettingsSection.dataStorage,
              ),
            ],
          ),
          const SectionHeader('Echo'),
          _CardGroup(
            children: [
              _row(
                context,
                icon: Icons.info_outline,
                iconColor: const Color(0xFF8B5CF6),
                section: SettingsSection.about,
                trailing: 'v$appVersion',
              ),
              CardRow(
                icon: Icons.logout,
                iconColor: EchoTheme.danger,
                label: 'Log out',
                destructive: true,
                onTap: onLogout,
              ),
            ],
          ),
          const SizedBox(height: EchoSectionTokens.groupGap),
        ],
      ),
    );
  }

  Widget _row(
    BuildContext context, {
    required IconData icon,
    required Color iconColor,
    required SettingsSection section,
    String? trailing,
  }) {
    final isSelected = selected == section;
    return Container(
      color: isSelected ? context.accentLight : null,
      child: CardRow(
        icon: icon,
        iconColor: iconColor,
        label: settingsSectionLabel(section),
        trailingValue: trailing,
        onTap: () => onTap(section),
      ),
    );
  }

  String _themeLabel(AppThemeSelection selection) {
    switch (selection) {
      case AppThemeSelection.system:
        return 'System';
      case AppThemeSelection.dark:
        return 'Dark';
      case AppThemeSelection.light:
        return 'Light';
      case AppThemeSelection.graphite:
        return 'Graphite';
      case AppThemeSelection.ember:
        return 'Ember';
      case AppThemeSelection.neon:
        return 'Neon';
      case AppThemeSelection.sakura:
        return 'Sakura';
      case AppThemeSelection.aurora:
        return 'Aurora';
    }
  }
}

class _CardGroup extends StatelessWidget {
  final List<Widget> children;

  const _CardGroup({required this.children});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14),
        child: Material(
          color: context.cardRowBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: _separated(context, children),
          ),
        ),
      ),
    );
  }

  List<Widget> _separated(BuildContext context, List<Widget> rows) {
    final out = <Widget>[];
    for (var i = 0; i < rows.length; i++) {
      out.add(rows[i]);
      if (i < rows.length - 1) {
        out.add(
          Padding(
            padding: const EdgeInsets.only(left: 60),
            child: Divider(height: 1, thickness: 0.5, color: context.border),
          ),
        );
      }
    }
    return out;
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
  SettingsSection _selectedSection = SettingsSection.profile;
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
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Are you sure you want to log out?',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            Text(
              'Your local encryption keys will be cleared. '
              'Old encrypted messages on this device may become unreadable.',
              style: TextStyle(
                color: EchoTheme.danger,
                fontSize: 13,
                height: 1.5,
              ),
            ),
          ],
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
          backgroundColor: context.mainBg,
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
      body: SafeArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
              child: Row(
                children: [
                  if (widget.onBack != null || Navigator.of(context).canPop())
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: IconButton(
                        icon: Icon(
                          Icons.arrow_back,
                          color: context.textSecondary,
                        ),
                        onPressed: () {
                          if (widget.onBack != null) {
                            widget.onBack!();
                          } else {
                            context.pop();
                          }
                        },
                      ),
                    ),
                  Text(
                    'Settings',
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 28,
                      fontWeight: FontWeight.w700,
                      letterSpacing: -0.5,
                    ),
                  ),
                ],
              ),
            ),
            Expanded(
              child: SettingsRootView(
                onTap: (section) =>
                    setState(() => _mobileDetailSection = section),
                onLogout: _logout,
              ),
            ),
          ],
        ),
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
            width: 320,
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
                  child: SettingsRootView(
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
