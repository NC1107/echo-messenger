// Horizontal divider with a localized day label ("Today" / "Yesterday" / date).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/theme_provider.dart' show UIDensity, uiDensityProvider;
import '../../theme/echo_theme.dart';

class DateDivider extends ConsumerWidget {
  final String timestamp;

  /// True when this divider sits above the *first* message in the
  /// conversation. In that case the day label adds little signal
  /// ("Today" with nothing above it just frames the start of history),
  /// so we render a "Start of conversation" marker instead — closer to
  /// the iMessage default + Discord's "This is the start of #channel"
  /// pattern.
  final bool isStartOfConversation;

  /// Optional density override; defaults to the value from
  /// [uiDensityProvider]. Tests can pin a specific tier via this param.
  final UIDensity? density;

  const DateDivider({
    super.key,
    required this.timestamp,
    this.isStartOfConversation = false,
    this.density,
  });

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      String label;
      if (isStartOfConversation) {
        label = 'Start of conversation';
      } else if (dt.year == now.year &&
          dt.month == now.month &&
          dt.day == now.day) {
        label = 'Today';
      } else if (dt.year == yesterday.year &&
          dt.month == yesterday.month &&
          dt.day == yesterday.day) {
        label = 'Yesterday';
      } else {
        label = '${_fullMonthName(dt.month)} ${dt.day}, ${dt.year}';
      }
      final UIDensity effectiveDensity =
          density ?? ref.watch(uiDensityProvider);
      final m = _DateDividerMetrics.forDensity(effectiveDensity);
      return Padding(
        padding: EdgeInsets.symmetric(vertical: m.vPad, horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: context.border.withValues(alpha: 0.5),
              ),
            ),
            Padding(
              padding: EdgeInsets.symmetric(horizontal: m.hPad),
              child: Text(
                label,
                style: TextStyle(
                  fontSize: m.fontSize,
                  color: context.textMuted,
                ),
              ),
            ),
            Expanded(
              child: Container(
                height: 1,
                color: context.border.withValues(alpha: 0.5),
              ),
            ),
          ],
        ),
      );
    } catch (_) {
      return const SizedBox.shrink();
    }
  }

  static String _fullMonthName(int m) {
    const names = [
      '',
      'January',
      'February',
      'March',
      'April',
      'May',
      'June',
      'July',
      'August',
      'September',
      'October',
      'November',
      'December',
    ];
    return names[m.clamp(1, 12)];
  }
}

class _DateDividerMetrics {
  final double vPad;
  final double hPad;
  final double fontSize;

  const _DateDividerMetrics({
    required this.vPad,
    required this.hPad,
    required this.fontSize,
  });

  static const cozy = _DateDividerMetrics(vPad: 8, hPad: 12, fontSize: 12);
  static const normal = _DateDividerMetrics(vPad: 6, hPad: 10, fontSize: 11);
  static const compact = _DateDividerMetrics(vPad: 4, hPad: 8, fontSize: 11);

  static _DateDividerMetrics forDensity(UIDensity d) {
    switch (d) {
      case UIDensity.cozy:
        return cozy;
      case UIDensity.normal:
        return normal;
      case UIDensity.compact:
        return compact;
    }
  }
}
