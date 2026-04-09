import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';
import 'gif_picker_widget.dart';

/// Discord-style floating emoji + GIF picker panel.
///
/// Renders as a card anchored to the bottom-right of the chat area with:
/// - Tabs at the top: Emoji | GIF
/// - Emoji tab: search bar + category sidebar (left) + emoji grid (right)
/// - GIF tab: search + trending/results grid
class MediaPickerPanel extends StatefulWidget {
  final void Function(Category? category, Emoji emoji) onEmojiSelected;
  final void Function(String gifUrl, String? slug) onGifSelected;
  final VoidCallback onClose;

  const MediaPickerPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onGifSelected,
    required this.onClose,
  });

  @override
  State<MediaPickerPanel> createState() => _MediaPickerPanelState();
}

class _MediaPickerPanelState extends State<MediaPickerPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 2, vsync: this);
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final screenSize = MediaQuery.of(context).size;
    final pickerWidth = screenSize.width < 412 ? screenSize.width - 32 : 380.0;
    final pickerHeight = screenSize.height < 700
        ? screenSize.height * 0.45
        : 350.0;

    return Align(
      alignment: Alignment.bottomRight,
      child: Container(
        width: pickerWidth,
        height: pickerHeight,
        margin: const EdgeInsets.only(right: 8, bottom: 4),
        decoration: BoxDecoration(
          color: context.surface,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: context.border),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.3),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: Column(
          children: [
            // Tab bar header
            Container(
              height: 36,
              decoration: BoxDecoration(
                border: Border(
                  bottom: BorderSide(color: context.border, width: 1),
                ),
              ),
              child: Row(
                children: [
                  Expanded(
                    child: TabBar(
                      controller: _tabController,
                      indicatorColor: context.accent,
                      indicatorWeight: 2,
                      indicatorSize: TabBarIndicatorSize.label,
                      labelColor: context.textPrimary,
                      unselectedLabelColor: context.textMuted,
                      labelStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      unselectedLabelStyle: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      dividerColor: Colors.transparent,
                      labelPadding: const EdgeInsets.symmetric(horizontal: 16),
                      tabs: const [
                        Tab(height: 34, text: 'Emoji'),
                        Tab(height: 34, text: 'GIFs'),
                      ],
                    ),
                  ),
                  IconButton(
                    icon: Icon(Icons.close, size: 16, color: context.textMuted),
                    onPressed: widget.onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 28,
                      minHeight: 28,
                    ),
                  ),
                  const SizedBox(width: 4),
                ],
              ),
            ),
            // Content
            Expanded(
              child: TabBarView(
                controller: _tabController,
                children: [_buildEmojiTab(context), _buildGifTab()],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmojiTab(BuildContext context) {
    return EmojiPicker(
      onEmojiSelected: widget.onEmojiSelected,
      config: Config(
        height: 312,
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
    );
  }

  Widget _buildGifTab() {
    return GifPickerWidget(
      onGifSelected: widget.onGifSelected,
      onClose: null,
      embedMode: true,
    );
  }
}
