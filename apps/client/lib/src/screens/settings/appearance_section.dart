import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../theme/echo_theme.dart';

class AppearanceSection extends ConsumerWidget {
  const AppearanceSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
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
        const SizedBox(height: 8),
        _ThemeOption(
          label: 'Ember',
          subtitle: 'Warm dark with amber accents',
          icon: Icons.local_fire_department_outlined,
          isSelected: currentTheme == AppThemeSelection.ember,
          onTap: () => ref
              .read(themeProvider.notifier)
              .setTheme(AppThemeSelection.ember),
        ),
        const SizedBox(height: 32),
        Text(
          'Message Layout',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 16),
        _ThemeOption(
          label: 'Bubbles',
          subtitle: 'Chat bubbles aligned left and right',
          icon: Icons.chat_bubble_outline,
          isSelected: ref.watch(messageLayoutProvider) == MessageLayout.bubbles,
          onTap: () => ref
              .read(messageLayoutProvider.notifier)
              .setLayout(MessageLayout.bubbles),
        ),
        const SizedBox(height: 8),
        _ThemeOption(
          label: 'Compact',
          subtitle: 'Discord-style, all messages left-aligned',
          icon: Icons.format_align_left_outlined,
          isSelected: ref.watch(messageLayoutProvider) == MessageLayout.compact,
          onTap: () => ref
              .read(messageLayoutProvider.notifier)
              .setLayout(MessageLayout.compact),
        ),
      ],
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
