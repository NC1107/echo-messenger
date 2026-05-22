import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

/// Standardised settings row: leading icon + title + optional subtitle +
/// optional trailing widget (defaults to a chevron when [onTap] is set).
///
/// Use this instead of building a raw [ListTile] with `contentPadding: EdgeInsets.zero`,
/// muted icon and chevron, theme-aware text styles, etc. Every settings
/// section in the app uses the same recipe; this widget bakes it in so
/// callers stay focused on what the row does.
///
/// For card-style rows with a colored icon badge (the redesigned settings
/// home list) use [CardRow] from `widgets/settings/card_row.dart` instead.
class SettingsListTile extends StatelessWidget {
  /// Leading icon.
  final IconData icon;

  /// Primary row label.
  final String title;

  /// Optional supporting line shown under the title in muted text.
  final String? subtitle;

  /// Optional trailing widget. When omitted AND [onTap] is non-null,
  /// renders a chevron-right; when both are omitted, nothing trails the row.
  final Widget? trailing;

  /// Tap handler. When null the row renders without a chevron and is inert.
  final VoidCallback? onTap;

  /// When true, renders the row in destructive style: danger color on icon
  /// and title, no default chevron.
  final bool destructive;

  const SettingsListTile({
    super.key,
    required this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  @override
  Widget build(BuildContext context) {
    final iconColor = destructive ? EchoTheme.danger : context.textSecondary;
    final titleColor = destructive ? EchoTheme.danger : context.textPrimary;

    Widget? resolvedTrailing = trailing;
    if (resolvedTrailing == null && onTap != null && !destructive) {
      resolvedTrailing = Icon(
        Icons.chevron_right,
        color: context.textMuted,
        size: 20,
      );
    }

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(icon, color: iconColor, size: 22),
      title: Text(title, style: TextStyle(color: titleColor, fontSize: 15)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
      trailing: resolvedTrailing,
      onTap: onTap,
    );
  }
}
