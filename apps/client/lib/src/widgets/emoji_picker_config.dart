/// Shared `emoji_picker_flutter` configuration used by every surface
/// that embeds the picker (main media-picker panel, mobile media-picker
/// panel, full reaction picker, etc.). Previously each surface kept its
/// own copy of the same colour + spacing + skin-tone setup; this lets
/// them all theme the picker the same way through one entry point.
library;

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Builds the `Config` object used by every Echo emoji picker.
///
/// [height] is forwarded to the picker; some embeddings (`Expanded`)
/// ignore it, others rely on it. [columns] defaults to 9 (the desktop /
/// fixed-width default); the mobile panel computes a width-aware value.
Config buildEchoEmojiPickerConfig(
  BuildContext context, {
  required double height,
  int columns = 9,
}) {
  return Config(
    height: height,
    checkPlatformCompatibility: true,
    emojiViewConfig: EmojiViewConfig(
      backgroundColor: context.surface,
      columns: columns,
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
  );
}
