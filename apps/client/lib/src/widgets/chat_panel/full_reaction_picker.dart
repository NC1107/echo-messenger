import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../../models/chat_message.dart';
import '../../theme/echo_theme.dart';

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
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    backgroundColor: context.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
    ),
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
          config: Config(
            height: 380,
            checkPlatformCompatibility: true,
            emojiViewConfig: EmojiViewConfig(
              backgroundColor: context.surface,
              columns: 9,
              emojiSizeMax: 28,
              verticalSpacing: 0,
              horizontalSpacing: 0,
              noRecents: Text(
                'No recents yet.',
                style: TextStyle(fontSize: 12, color: context.textMuted),
              ),
            ),
            categoryViewConfig: CategoryViewConfig(
              initCategory: Category.SMILEYS,
              recentTabBehavior: RecentTabBehavior.RECENT,
              backgroundColor: context.surface,
              indicatorColor: context.accent,
              iconColorSelected: context.accent,
              iconColor: context.textMuted,
            ),
            skinToneConfig: SkinToneConfig(
              enabled: true,
              dialogBackgroundColor: context.surface,
              indicatorColor: context.accent,
            ),
            bottomActionBarConfig: const BottomActionBarConfig(enabled: false),
            searchViewConfig: SearchViewConfig(
              backgroundColor: context.surface,
              buttonIconColor: context.textSecondary,
              hintText: 'Find an emoji...',
            ),
          ),
        ),
      ),
    ),
  );
}
