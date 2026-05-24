import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/locale_provider.dart';
import '../../theme/echo_theme.dart';
import '../../widgets/settings_panel_scaffold.dart';

/// Settings section that lets the user pick an app language.
///
/// Selecting a locale persists it to SharedPreferences and applies it
/// immediately via [localeProvider] which is read by [MaterialApp.locale].
class LanguageSection extends ConsumerWidget {
  const LanguageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.watch(localeProvider);

    return SettingsPanelScaffold(
      children: [
        Text(
          'Language',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Choose the language used throughout the app. '
          'Takes effect immediately.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        // Beta banner — translations beyond English are scaffolded but
        // most labels still fall through to English.  Surfacing this
        // here (#791) saves testers the "is my install broken?" loop.
        _ComingSoonBanner(),
        const Divider(height: 24),
        ...kSupportedLocales.map(
          (entry) => _LocaleOption(
            entry: entry,
            isSelected: currentLocale.languageCode == entry.tag,
            isFullyTranslated: entry.tag == 'en',
            onTap: () =>
                ref.read(localeProvider.notifier).setLocale(Locale(entry.tag)),
          ),
        ),
        const SizedBox(height: 24),
        Text(
          'RTL languages (Arabic, Hebrew, etc.) will be added once '
          'right-to-left layout testing is complete.',
          style: TextStyle(color: context.textMuted, fontSize: 12, height: 1.5),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Single locale list tile
// ---------------------------------------------------------------------------

class _ComingSoonBanner extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.accentLight,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: context.accent, width: 1),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(Icons.info_outline, size: 18, color: context.accent),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              'Language support is in development. Only English is fully '
              'translated right now — picking another language will fall '
              'back to English for most labels.',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 12.5,
                height: 1.45,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _LocaleOption extends StatelessWidget {
  final LocaleEntry entry;
  final bool isSelected;
  final bool isFullyTranslated;
  final VoidCallback onTap;

  const _LocaleOption({
    required this.entry,
    required this.isSelected,
    required this.isFullyTranslated,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: isFullyTranslated
          ? '${entry.displayName} language option'
          : '${entry.displayName} language option (coming soon)',
      button: true,
      selected: isSelected,
      child: Padding(
        padding: const EdgeInsets.only(bottom: 8),
        child: Material(
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
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          entry.displayName,
                          style: TextStyle(
                            color: _getLanguageTextColor(
                              isSelected,
                              isFullyTranslated,
                              context,
                            ),
                            fontSize: 14,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        if (!isFullyTranslated) ...[
                          const SizedBox(height: 2),
                          Text(
                            'Coming soon',
                            style: TextStyle(
                              color: context.textMuted,
                              fontSize: 11.5,
                              fontStyle: FontStyle.italic,
                            ),
                          ),
                        ],
                      ],
                    ),
                  ),
                  if (isSelected)
                    Icon(Icons.check_circle, size: 20, color: context.accent),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Color _getLanguageTextColor(
    bool isSelected,
    bool isFullyTranslated,
    BuildContext context,
  ) {
    if (isSelected) return context.accent;
    return isFullyTranslated ? context.textPrimary : context.textMuted;
  }
}
