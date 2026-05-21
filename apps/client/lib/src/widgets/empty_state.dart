import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Illustrated empty-state placeholder used across screens.
///
/// Renders a 64px circular accent-tinted badge containing [icon], the [title]
/// in `titleMedium` bold, then [body] in `bodySmall` constrained to 320px, all
/// centered. If [ctaLabel] is provided, an additional [FilledButton.tonal]
/// is shown that invokes [onCta] on press. An optional [secondaryCtaLabel]
/// renders a lower-emphasis [TextButton] beside the primary CTA for cases
/// that genuinely need two next steps (e.g. "Add contact" + "Browse groups").
class EmptyState extends StatelessWidget {
  /// Material icon glyph rendered inside the tinted badge at ~32px.
  final IconData icon;

  /// Primary headline above the body copy.
  final String title;

  /// Supporting copy describing what the user can do next.
  final String body;

  /// Optional CTA button label. When null, no button is rendered.
  final String? ctaLabel;

  /// Invoked when the CTA button is pressed.
  final VoidCallback? onCta;

  /// Optional secondary CTA label. When set, a [TextButton] is rendered to
  /// the right of the primary CTA. Both labels must be set together for the
  /// secondary CTA to appear.
  final String? secondaryCtaLabel;

  /// Invoked when the secondary CTA button is pressed.
  final VoidCallback? onSecondaryCta;

  /// Optional widget rendered below the CTA. Useful for secondary hints
  /// (e.g. keyboard-shortcut tip) without competing with the primary CTA.
  final Widget? footer;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    required this.body,
    this.ctaLabel,
    this.onCta,
    this.secondaryCtaLabel,
    this.onSecondaryCta,
    this.footer,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 64px circular badge with light accent fill and accent-colored icon.
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: context.accentLight,
                shape: BoxShape.circle,
              ),
              child: Center(child: Icon(icon, size: 32, color: context.accent)),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
            const SizedBox(height: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                body,
                textAlign: TextAlign.center,
                style: theme.textTheme.bodySmall?.copyWith(
                  color: context.textSecondary,
                  height: 1.4,
                ),
              ),
            ),
            if (ctaLabel != null) ...[
              const SizedBox(height: 16),
              // Wrap so the secondary CTA tucks under the primary on narrow
              // viewports (e.g. 750 px wide_layout with the sidebar taking
              // ~360 px) instead of triggering a horizontal overflow.
              Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.center,
                children: [
                  FilledButton.tonal(onPressed: onCta, child: Text(ctaLabel!)),
                  if (secondaryCtaLabel != null)
                    TextButton(
                      onPressed: onSecondaryCta,
                      child: Text(secondaryCtaLabel!),
                    ),
                ],
              ),
            ],
            if (footer != null) ...[const SizedBox(height: 20), footer!],
          ],
        ),
      ),
    );
  }
}
