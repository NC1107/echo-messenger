import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../echo_bottom_sheet.dart';
import '../emoji_picker_config.dart';

/// Show the full emoji-picker bottom sheet for adding a reaction to a message.
///
/// Pulled out of `chat_panel.dart` so the picker is reusable from other
/// surfaces (thread view, search results, etc.) without dragging the
/// 232-line reaction-overlay machinery along with it.
///
/// `onPick` receives the chosen emoji and the boolean of whether the user
/// already had that reaction (so the caller can flip add ↔ remove without
/// re-deriving it).
Future<void> showFullReactionPicker(
  BuildContext context, {
  required ChatMessage message,
  required String myUserId,
  required void Function(String emoji, bool alreadyReacted) onPick,
}) {
  return showEchoBottomSheet<void>(
    context,
    builder: (sheetContext) => SizedBox(
      height: 380,
      child: DefaultTextStyle(
        style: const TextStyle(fontFamilyFallback: ['NotoEmoji']),
        child: EmojiPicker(
          onEmojiSelected: (_, emoji) {
            Navigator.of(sheetContext).pop();
            final alreadyReacted = message.reactions.any(
              (r) => r.emoji == emoji.emoji && r.userId == myUserId,
            );
            onPick(emoji.emoji, alreadyReacted);
          },
          config: buildEchoEmojiPickerConfig(context, height: 380),
        ),
      ),
    ),
  );
}
