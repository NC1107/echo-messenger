import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Visual treatment for [EmptyState]. [neutral] is the default accent-tinted
/// look; [error] swaps the badge + icon to a danger tint for "couldn't load X"
/// failure states (with a Retry CTA supplied via [EmptyState.ctaLabel]).
enum EmptyStateVariant { neutral, error }

/// Illustrated empty-state placeholder used across screens.
///
/// Renders a 64px circular tinted badge containing [icon], the [title]
/// in `titleMedium` bold, then [body] in `bodySmall` constrained to 320px, all
/// centered. If [ctaLabel] is provided, an additional [FilledButton.tonal]
/// is shown that invokes [onCta] on press. An optional [secondaryCtaLabel]
/// renders a lower-emphasis [TextButton] beside the primary CTA for cases
/// that genuinely need two next steps (e.g. "Add contact" + "Browse groups").
///
/// Pass [variant] = [EmptyStateVariant.error] for failure states so the badge
/// reads as a danger tint instead of the accent — this is the shared home for
/// the "icon + title + message + Retry" boxes screens used to hand-roll.
class EmptyState extends StatelessWidget {
  /// Material icon glyph rendered inside the tinted badge at ~32px.
  final IconData icon;

  /// Primary headline above the body copy.
  final String title;

  /// Supporting copy describing what the user can do next. When null the
  /// body line and its 8 px gap are dropped so the title sits closer to the
  /// badge — useful for compact contexts (autocomplete dropdowns, etc.)
  /// where the title alone is enough.
  final String? body;

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

  /// Neutral (accent) by default; [EmptyStateVariant.error] tints the badge +
  /// icon danger for failure states.
  final EmptyStateVariant variant;

  const EmptyState({
    super.key,
    required this.icon,
    required this.title,
    this.body,
    this.ctaLabel,
    this.onCta,
    this.secondaryCtaLabel,
    this.onSecondaryCta,
    this.footer,
    this.variant = EmptyStateVariant.neutral,
  });

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isError = variant == EmptyStateVariant.error;
    final badgeColor = isError
        ? EchoTheme.danger.withValues(alpha: 0.12)
        : context.accentLight;
    final iconColor = isError ? EchoTheme.danger : context.accent;
    return Center(
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // 64px circular badge: accent tint normally, danger tint on error.
            Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                color: badgeColor,
                shape: BoxShape.circle,
              ),
              child: Center(child: Icon(icon, size: 32, color: iconColor)),
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
            if (body != null) ...[
              const SizedBox(height: 8),
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Text(
                  body!,
                  textAlign: TextAlign.center,
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: context.textSecondary,
                    height: 1.4,
                  ),
                ),
              ),
            ],
            if (ctaLabel != null) ...[
              const SizedBox(height: 16),
              // Wrap so secondary CTA tucks under primary on narrow viewports instead of overflowing.
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
