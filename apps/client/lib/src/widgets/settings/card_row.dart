import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// A grouped card row used by the redesigned Settings list and other
/// sectioned card layouts. Renders a leading colored icon badge (~36×36
/// rounded-12), a primary label, an optional trailing summary value, and a
/// chevron. Use [destructive] for "Log out" / "Delete" style rows — the
/// chevron is suppressed and the label/icon use [EchoTheme.danger].
class CardRow extends StatelessWidget {
  /// Leading icon shown inside the colored badge.
  final IconData icon;

  /// Tint applied to the icon and to the [iconBadgeBg] (semi-transparent).
  /// Use [EchoTheme.danger] for destructive rows.
  final Color iconColor;

  /// Primary row label.
  final String label;

  /// Optional trailing summary text rendered in the muted text color
  /// before the chevron.
  final String? trailingValue;

  /// When true, renders the row in destructive style: red label and icon,
  /// no chevron, no trailing value.
  final bool destructive;

  /// Tap handler. When null the row renders disabled (40% opacity).
  final VoidCallback? onTap;

  const CardRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    this.trailingValue,
    this.destructive = false,
    this.onTap,
  });

  static const double _rowHeight = 56;
  static const double _hPadding = 12;
  static const double _badgeSize = 36;
  static const double _badgeRadius = 12;

  @override
  Widget build(BuildContext context) {
    final effectiveIconColor = destructive ? EchoTheme.danger : iconColor;
    final effectiveLabelColor = destructive
        ? EchoTheme.danger
        : context.textPrimary;

    final disabled = onTap == null;
    final content = Padding(
      padding: const EdgeInsets.symmetric(horizontal: _hPadding),
      child: Row(
        children: [
          // Leading colored icon badge.
          Container(
            width: _badgeSize,
            height: _badgeSize,
            decoration: BoxDecoration(
              color: effectiveIconColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(_badgeRadius),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: 18, color: effectiveIconColor),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: effectiveLabelColor,
                fontSize: 15,
                fontWeight: destructive ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ),
          if (!destructive && trailingValue != null) ...[
            const SizedBox(width: 8),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 160),
              child: Text(
                trailingValue!,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                textAlign: TextAlign.end,
                style: TextStyle(color: context.textMuted, fontSize: 13),
              ),
            ),
          ],
          if (!destructive) ...[
            const SizedBox(width: 4),
            Icon(Icons.chevron_right, size: 16, color: context.textMuted),
          ],
        ],
      ),
    );

    return Semantics(
      label: destructive ? label : '$label settings',
      button: true,
      enabled: !disabled,
      child: Opacity(
        opacity: disabled ? 0.4 : 1,
        child: SizedBox(
          height: _rowHeight,
          child: Material(
            type: MaterialType.transparency,
            child: InkWell(
              onTap: onTap,
              borderRadius: BorderRadius.circular(12),
              child: content,
            ),
          ),
        ),
      ),
    );
  }
}
