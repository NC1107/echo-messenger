import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart';
import '../../theme/echo_theme.dart';

/// A grouped card row used by the redesigned Settings list and other
/// sectioned card layouts. Renders a leading colored icon badge, a primary
/// label, an optional trailing summary value, and a chevron. Use
/// [destructive] for "Log out" / "Delete" style rows -- the chevron is
/// suppressed and the label/icon use [EchoTheme.danger].
///
/// Sizing scales with the global [UIDensity] (cozy / normal / compact),
/// matching the density tiers used by the channel bar and message stream.
class CardRow extends ConsumerWidget {
  /// Leading icon shown inside the colored badge.
  final IconData icon;

  /// Tint applied to the icon and to the icon badge background
  /// (semi-transparent). Use [EchoTheme.danger] for destructive rows.
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

  /// Optional density override; defaults to the value from
  /// [uiDensityProvider]. Tests can pin a specific tier via this param.
  final UIDensity? density;

  const CardRow({
    super.key,
    required this.icon,
    required this.iconColor,
    required this.label,
    this.trailingValue,
    this.destructive = false,
    this.onTap,
    this.density,
  });

  static _CardRowMetrics _metricsFor(UIDensity density) {
    switch (density) {
      case UIDensity.cozy:
        return const _CardRowMetrics(
          rowHeight: 64,
          hPadding: 14,
          badgeSize: 40,
          badgeRadius: 14,
          iconSize: 20,
          gap: 14,
          labelSize: 16,
          trailingSize: 14,
          chevronSize: 18,
        );
      case UIDensity.compact:
        return const _CardRowMetrics(
          rowHeight: 44,
          hPadding: 10,
          badgeSize: 28,
          badgeRadius: 10,
          iconSize: 16,
          gap: 10,
          labelSize: 13,
          trailingSize: 12,
          chevronSize: 14,
        );
      case UIDensity.normal:
        return const _CardRowMetrics(
          rowHeight: 56,
          hPadding: 12,
          badgeSize: 36,
          badgeRadius: 12,
          iconSize: 18,
          gap: 12,
          labelSize: 15,
          trailingSize: 13,
          chevronSize: 16,
        );
    }
  }

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final UIDensity effectiveDensity = density ?? ref.watch(uiDensityProvider);
    final m = _metricsFor(effectiveDensity);
    final effectiveIconColor = destructive ? EchoTheme.danger : iconColor;
    final effectiveLabelColor = destructive
        ? EchoTheme.danger
        : context.textPrimary;

    final disabled = onTap == null;
    final content = Padding(
      padding: EdgeInsets.symmetric(horizontal: m.hPadding),
      child: Row(
        children: [
          Container(
            width: m.badgeSize,
            height: m.badgeSize,
            decoration: BoxDecoration(
              color: effectiveIconColor.withValues(alpha: 0.16),
              borderRadius: BorderRadius.circular(m.badgeRadius),
            ),
            alignment: Alignment.center,
            child: Icon(icon, size: m.iconSize, color: effectiveIconColor),
          ),
          SizedBox(width: m.gap),
          Expanded(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: effectiveLabelColor,
                fontSize: m.labelSize,
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
                style: TextStyle(
                  color: context.textMuted,
                  fontSize: m.trailingSize,
                ),
              ),
            ),
          ],
          if (!destructive) ...[
            const SizedBox(width: 4),
            Icon(
              Icons.chevron_right,
              size: m.chevronSize,
              color: context.textMuted,
            ),
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
          height: m.rowHeight,
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

class _CardRowMetrics {
  final double rowHeight;
  final double hPadding;
  final double badgeSize;
  final double badgeRadius;
  final double iconSize;
  final double gap;
  final double labelSize;
  final double trailingSize;
  final double chevronSize;

  const _CardRowMetrics({
    required this.rowHeight,
    required this.hPadding,
    required this.badgeSize,
    required this.badgeRadius,
    required this.iconSize,
    required this.gap,
    required this.labelSize,
    required this.trailingSize,
    required this.chevronSize,
  });
}
