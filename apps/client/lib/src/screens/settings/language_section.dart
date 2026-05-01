import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/locale_provider.dart';
import '../../theme/echo_theme.dart';

/// Settings section that lets the user pick an app language.
///
/// Selecting a locale persists it to SharedPreferences and applies it
/// immediately via [localeProvider] which is read by [MaterialApp.locale].
class LanguageSection extends ConsumerWidget {
  const LanguageSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final currentLocale = ref.watch(localeProvider);

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(24),
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
            const Divider(height: 24),
            ...kSupportedLocales.map(
              (entry) => _LocaleOption(
                entry: entry,
                isSelected: currentLocale.languageCode == entry.tag,
                onTap: () => ref
                    .read(localeProvider.notifier)
                    .setLocale(Locale(entry.tag)),
              ),
            ),
            const SizedBox(height: 24),
            Text(
              'RTL languages (Arabic, Hebrew, etc.) will be added once '
              'right-to-left layout testing is complete.',
              style: TextStyle(
                color: context.textMuted,
                fontSize: 12,
                height: 1.5,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Single locale list tile
// ---------------------------------------------------------------------------

class _LocaleOption extends StatelessWidget {
  final LocaleEntry entry;
  final bool isSelected;
  final VoidCallback onTap;

  const _LocaleOption({
    required this.entry,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${entry.displayName} language option',
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
                    child: Text(
                      entry.displayName,
                      style: TextStyle(
                        color: isSelected
                            ? context.accent
                            : context.textPrimary,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
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
}
