import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

/// Centered pill shown for in-timeline system events: member joined/left,
/// encryption key changes, voice call started, etc.  Extracted from
/// `message_item.dart` (#refactor-2026-05-09) so the rendering logic is
/// reusable from the thread view + saved-messages view without dragging
/// the full MessageItem state machine.
class SystemEventPill extends StatelessWidget {
  final ChatMessage message;

  const SystemEventPill({super.key, required this.message});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 24),
      child: Center(
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: context.surface,
            borderRadius: BorderRadius.circular(8),
            border: Border.all(color: context.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                systemEventIcon(message.content),
                size: 13,
                color: context.textMuted,
              ),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  message.content,
                  style: GoogleFonts.inter(
                    color: context.textMuted,
                    fontSize: 11,
                  ),
                  textAlign: TextAlign.center,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

/// Pick an icon for a system-event message based on a few keyword
/// heuristics in the rendered text.  Public so other timeline surfaces
/// (thread view, saved messages) can mirror the same affordance.
IconData systemEventIcon(String content) {
  final lower = content.toLowerCase();
  if (lower.contains('call')) {
    return Icons.call;
  }
  if (lower.contains('encryption') || lower.contains('key')) {
    return Icons.vpn_key;
  }
  if (lower.contains('joined') ||
      lower.contains('left') ||
      lower.contains('removed') ||
      lower.contains('banned')) {
    return Icons.group;
  }
  return Icons.info_outline;
}
