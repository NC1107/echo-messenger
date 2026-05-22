import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Severity flavors for [EchoBanner]. Picks the icon tint, background
/// tint, and border color so callsites don't hand-roll the palette.
enum EchoBannerSeverity {
  /// Informational — uses [EchoTheme.accent].
  info,

  /// Soft warning — uses [EchoTheme.warning].
  warning,

  /// Destructive / forgery / data-loss — uses [EchoTheme.danger].
  danger,
}

/// Canonical in-line banner used for transient surface-level messages
/// (encryption status, pending contacts, session-replaced, update prompts).
///
/// New code should reach for this widget instead of hand-rolling a
/// `Container(color: x.withValues(alpha: 0.1), ...)`. Bespoke layouts that
/// genuinely need more than one action button or a custom progress bar
/// (e.g. the sidebar update banner) stay hand-rolled — see CLAUDE.md
/// "Componentize when you'd otherwise paste twice".
class EchoBanner extends StatelessWidget {
  /// Leading glyph shown to the left of [message].
  final IconData icon;

  /// Body copy. Wraps; do not add a trailing period in headlines.
  final String message;

  /// Color + tint flavor. See [EchoBannerSeverity].
  final EchoBannerSeverity severity;

  /// Optional trailing action widget — typically a [TextButton] or
  /// [IconButton]. Layout adds an 8px gap before it.
  final Widget? action;

  /// Optional outer margin. When null the banner renders flush to its
  /// parent; supply [EdgeInsets] when embedding inside a list / scroll
  /// view where a gutter is expected.
  final EdgeInsetsGeometry? margin;

  /// Optional border-radius override. Defaults to 0 (flush) so the
  /// banner can sit at the top of a conversation panel without visible
  /// corners; supply [BorderRadius] for floating variants.
  final BorderRadiusGeometry? borderRadius;

  /// When true (and [borderRadius] is set), draws a 1px border in the
  /// severity color at 40% alpha. Matches the existing pending-contacts
  /// + session-replaced banner styles.
  final bool showBorder;

  const EchoBanner({
    super.key,
    required this.icon,
    required this.message,
    this.severity = EchoBannerSeverity.info,
    this.action,
    this.margin,
    this.borderRadius,
    this.showBorder = false,
  });

  Color _color(BuildContext context) {
    switch (severity) {
      case EchoBannerSeverity.info:
        return context.accent;
      case EchoBannerSeverity.warning:
        return EchoTheme.warning;
      case EchoBannerSeverity.danger:
        return EchoTheme.danger;
    }
  }

  @override
  Widget build(BuildContext context) {
    final color = _color(context);
    final radius = borderRadius;
    return Container(
      margin: margin,
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.1),
        borderRadius: radius,
        border: showBorder && radius != null
            ? Border.fromBorderSide(
                BorderSide(color: color.withValues(alpha: 0.4)),
              )
            : null,
      ),
      child: Material(
        color: Colors.transparent,
        child: Padding(
          padding: const EdgeInsets.symmetric(
            horizontal: EchoSpacing.lg,
            vertical: EchoSpacing.sm + 2,
          ),
          child: Row(
            children: [
              Icon(icon, size: 18, color: color),
              const SizedBox(width: EchoSpacing.md),
              Expanded(
                child: Text(
                  message,
                  style: TextStyle(
                    fontSize: 12.5,
                    color: context.textPrimary,
                    height: 1.35,
                  ),
                ),
              ),
              if (action != null) ...[
                const SizedBox(width: EchoSpacing.sm),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}
