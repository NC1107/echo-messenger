// Centered system timeline pill (e.g. "Encrypted with ...") shown inline.
import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

class SystemTimelineMessage extends StatelessWidget {
  final ChatMessage msg;

  const SystemTimelineMessage({super.key, required this.msg});

  @override
  Widget build(BuildContext context) {
    final text = msg.content.replaceFirst('[system:', '').replaceFirst(']', '');
    return Container(
      padding: const EdgeInsets.symmetric(vertical: EchoSpacing.sm),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(
            horizontal: EchoSpacing.md,
            vertical: EchoSpacing.xs,
          ),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(EchoRadii.lg),
            border: Border.all(color: context.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.lock_outline, size: 14, color: context.textMuted),
              const SizedBox(width: 6),
              Text(
                text.trim(),
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
