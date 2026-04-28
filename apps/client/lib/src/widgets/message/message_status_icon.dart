import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

/// Displays a small status icon (sending, sent, delivered, read, failed) with
/// a tooltip describing the current state.
class MessageStatusIcon extends StatelessWidget {
  final MessageStatus? status;

  const MessageStatusIcon({super.key, required this.status});

  @override
  Widget build(BuildContext context) {
    if (status == null) return const SizedBox.shrink();

    IconData icon;
    Color color;
    String tooltip;
    switch (status!) {
      case MessageStatus.sending:
        icon = Icons.schedule_outlined;
        color = context.textMuted;
        tooltip = 'Sending';
      case MessageStatus.sent:
        icon = Icons.check_outlined;
        color = context.textMuted;
        tooltip = 'Sent';
      case MessageStatus.delivered:
        icon = Icons.done_all_outlined;
        color = context.textMuted;
        tooltip = 'Delivered';
      case MessageStatus.read:
        icon = Icons.done_all;
        color = context.accent;
        tooltip = 'Read';
      case MessageStatus.failed:
        icon = Icons.error_outline;
        color = EchoTheme.danger;
        tooltip = 'Failed to send';
    }
    return Padding(
      padding: const EdgeInsets.only(left: 4),
      child: Tooltip(
        message: tooltip,
        child: Icon(icon, size: 12, color: color),
      ),
    );
  }
}
