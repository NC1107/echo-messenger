// Horizontal divider with a localized day label ("Today" / "Yesterday" / date).
import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';

class DateDivider extends StatelessWidget {
  final String timestamp;

  const DateDivider({super.key, required this.timestamp});

  @override
  Widget build(BuildContext context) {
    try {
      final dt = DateTime.parse(timestamp).toLocal();
      final now = DateTime.now();
      final yesterday = now.subtract(const Duration(days: 1));
      String label;
      if (dt.year == now.year && dt.month == now.month && dt.day == now.day) {
        label = 'Today';
      } else if (dt.year == yesterday.year &&
          dt.month == yesterday.month &&
          dt.day == yesterday.day) {
        label = 'Yesterday';
      } else {
        label = '${_fullMonthName(dt.month)} ${dt.day}, ${dt.year}';
      }
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 4, horizontal: 16),
        child: Row(
          children: [
            Expanded(
              child: Container(
                height: 1,
                color: context.border.withValues(alpha: 0.5),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8),
              child: Text(
                label,
                style: TextStyle(fontSize: 11, color: context.textMuted),
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
