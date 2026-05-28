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
/// Leading resolution order:
/// 1. [leading] — any widget (e.g. [UserAvatar], [CircleAvatar]).
/// 2. [icon] — an [IconData] wrapped in the standard icon style.
/// 3. Nothing — the row has no leading widget.
///
/// For card-style rows with a colored icon badge (the redesigned settings
/// home list) use [CardRow] from `widgets/settings/card_row.dart` instead.
class SettingsListTile extends StatelessWidget {
  /// Arbitrary leading widget. Takes precedence over [icon] when both are set.
  final Widget? leading;

  /// Leading icon. Used when [leading] is null.
  final IconData? icon;

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
    this.leading,
    this.icon,
    required this.title,
    this.subtitle,
    this.trailing,
    this.onTap,
    this.destructive = false,
  });

  Widget? _resolveLeading(BuildContext context) {
    if (leading != null) return leading;
    if (icon == null) return null;
    final iconColor = destructive ? EchoTheme.danger : context.textSecondary;
    return Icon(icon, color: iconColor, size: 22);
  }

  Widget? _resolveTrailing(BuildContext context) {
    if (trailing != null) return trailing;
    if (onTap != null && !destructive) {
      return Icon(Icons.chevron_right, color: context.textMuted, size: 20);
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final titleColor = destructive ? EchoTheme.danger : context.textPrimary;

    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: _resolveLeading(context),
      title: Text(title, style: TextStyle(color: titleColor, fontSize: 15)),
      subtitle: subtitle == null
          ? null
          : Text(
              subtitle!,
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
      trailing: _resolveTrailing(context),
      onTap: onTap,
    );
  }
}
