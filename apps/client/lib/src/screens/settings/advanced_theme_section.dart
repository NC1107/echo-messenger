import 'package:flutter/material.dart';
import 'package:flutter_colorpicker/flutter_colorpicker.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../theme/echo_theme.dart';

/// Settings > Appearance > Advanced — lets the user override the current
/// theme's primary and accent colors. Persisted via SharedPreferences keys
/// [kCustomPrimaryColorKey] and [kCustomAccentColorKey] (ARGB int).
class AdvancedThemeSection extends ConsumerWidget {
  const AdvancedThemeSection({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final custom = ref.watch(customColorsProvider);
    final scheme = Theme.of(context).colorScheme;

    final effectivePrimary = custom.primaryColor ?? scheme.primary;
    final effectiveAccent = custom.accentColor ?? scheme.secondary;

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Advanced',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Override the active theme\'s primary and accent colors. '
              'Changes apply immediately and survive restarts.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const Divider(height: 32),
            _ColorPickerTile(
              key: const Key('primary_color_tile'),
              label: 'Primary color',
              subtitle: 'Used for text highlights and UI elements',
              currentColor: effectivePrimary,
              isOverridden: custom.primaryColor != null,
              onColorChanged: (c) =>
                  ref.read(customColorsProvider.notifier).setPrimaryColor(c),
            ),
            const SizedBox(height: 12),
            _ColorPickerTile(
              key: const Key('accent_color_tile'),
              label: 'Accent color',
              subtitle: 'Used for buttons, links, and active states',
              currentColor: effectiveAccent,
              isOverridden: custom.accentColor != null,
              onColorChanged: (c) =>
                  ref.read(customColorsProvider.notifier).setAccentColor(c),
            ),
            if (custom.hasOverrides) ...[
              const SizedBox(height: 24),
              Align(
                alignment: Alignment.centerLeft,
                child: OutlinedButton.icon(
                  key: const Key('reset_colors_button'),
                  onPressed: () =>
                      ref.read(customColorsProvider.notifier).resetColors(),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Reset to theme defaults'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.textSecondary,
                    side: BorderSide(color: context.border),
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Inline variant: embeds directly inside AppearanceSection's ListView
// ---------------------------------------------------------------------------

/// Compact inline widget that renders the two color picker tiles and an
/// optional reset button. Intended to be embedded directly inside
/// [AppearanceSection] rather than shown as a standalone screen.
class AdvancedThemeInline extends ConsumerWidget {
  const AdvancedThemeInline({super.key});

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final custom = ref.watch(customColorsProvider);
    final scheme = Theme.of(context).colorScheme;

    final effectivePrimary = custom.primaryColor ?? scheme.primary;
    final effectiveAccent = custom.accentColor ?? scheme.secondary;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _ColorPickerTile(
          key: const Key('primary_color_tile'),
          label: 'Primary color',
          subtitle: 'Text highlights and UI elements',
          currentColor: effectivePrimary,
          isOverridden: custom.primaryColor != null,
          onColorChanged: (c) =>
              ref.read(customColorsProvider.notifier).setPrimaryColor(c),
        ),
        const SizedBox(height: 8),
        _ColorPickerTile(
          key: const Key('accent_color_tile'),
          label: 'Accent color',
          subtitle: 'Buttons, links, and active states',
          currentColor: effectiveAccent,
          isOverridden: custom.accentColor != null,
          onColorChanged: (c) =>
              ref.read(customColorsProvider.notifier).setAccentColor(c),
        ),
        if (custom.hasOverrides) ...[
          const SizedBox(height: 12),
          OutlinedButton.icon(
            key: const Key('reset_colors_button'),
            onPressed: () =>
                ref.read(customColorsProvider.notifier).resetColors(),
            icon: const Icon(Icons.refresh, size: 18),
            label: const Text('Reset to theme defaults'),
            style: OutlinedButton.styleFrom(
              foregroundColor: context.textSecondary,
              side: BorderSide(color: context.border),
            ),
          ),
        ],
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Color picker tile
// ---------------------------------------------------------------------------

class _ColorPickerTile extends StatelessWidget {
  final String label;
  final String subtitle;
  final Color currentColor;
  final bool isOverridden;
  final ValueChanged<Color> onColorChanged;

  const _ColorPickerTile({
    super.key,
    required this.label,
    required this.subtitle,
    required this.currentColor,
    required this.isOverridden,
    required this.onColorChanged,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label picker',
      button: true,
      child: Material(
        color: Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          hoverColor: context.surfaceHover,
          onTap: () => _openPicker(context),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.border),
              color: context.cardRowBg,
            ),
            child: Row(
              children: [
                // Color swatch preview
                Container(
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    color: currentColor,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: context.border, width: 1),
                  ),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            label,
                            style: TextStyle(
                              color: context.textPrimary,
                              fontSize: 14,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                          if (isOverridden) ...[
                            const SizedBox(width: 6),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: context.accentLight,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'custom',
                                style: TextStyle(
                                  color: context.accent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                Icon(
                  Icons.colorize_outlined,
                  size: 20,
                  color: context.textSecondary,
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _openPicker(BuildContext context) async {
    Color picked = currentColor;
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: Theme.of(context).colorScheme.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: Theme.of(context).dividerColor),
        ),
        title: Text(
          label,
          style: TextStyle(
            color: Theme.of(context).colorScheme.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: SingleChildScrollView(
          child: ColorPicker(
            pickerColor: picked,
            onColorChanged: (c) => picked = c,
            enableAlpha: false,
            labelTypes: const [],
            pickerAreaHeightPercent: 0.8,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () {
              onColorChanged(picked);
              Navigator.pop(dialogContext);
            },
            child: const Text('Apply'),
          ),
        ],
      ),
    );
  }
}
