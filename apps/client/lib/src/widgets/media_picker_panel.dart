import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';
import 'gif_picker_widget.dart';

/// A tabbed panel combining the Emoji picker and GIF picker into a single
/// Discord-style panel. Shown below the chat input bar when the user taps
/// the + button.
class MediaPickerPanel extends StatefulWidget {
  /// Called when an emoji is selected. The caller is responsible for inserting
  /// the emoji character into the text field at the correct cursor position.
  final void Function(Category? category, Emoji emoji) onEmojiSelected;

  /// Called when a GIF is selected. [gifUrl] is the HD URL to send, [slug]
  /// is the Klipy slug for share tracking.
  final void Function(String gifUrl, String? slug) onGifSelected;

  /// Called when the user requests to close the panel (e.g. close button).
  final VoidCallback onClose;

  /// Total height of the panel.
  final double height;

  /// Number of emoji columns (responsive).
  final int emojiColumns;

  /// Max emoji size (responsive).
  final double emojiSize;

  const MediaPickerPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onGifSelected,
    required this.onClose,
    this.height = 250,
    this.emojiColumns = 9,
    this.emojiSize = 24,
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
    return Container(
      height: widget.height,
      decoration: BoxDecoration(
        color: context.surface,
        border: Border(top: BorderSide(color: context.border)),
      ),
      child: Column(
        children: [
          _buildTabBar(context),
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [_buildEmojiTab(context), _buildGifTab()],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTabBar(BuildContext context) {
    return SizedBox(
      height: 36,
      child: Row(
        children: [
          Expanded(
            child: TabBar(
              controller: _tabController,
              indicatorColor: context.accent,
              indicatorWeight: 2,
              labelColor: context.accent,
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
              tabs: const [
                Tab(text: 'Emoji'),
                Tab(text: 'GIF'),
              ],
            ),
          ),
          IconButton(
            icon: Icon(Icons.close, size: 16, color: context.textMuted),
            onPressed: widget.onClose,
            tooltip: 'Close',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  Widget _buildEmojiTab(BuildContext context) {
    // Height available for the emoji picker is total height minus tab bar (36).
    final emojiHeight = widget.height - 36;
    return EmojiPicker(
      onEmojiSelected: widget.onEmojiSelected,
      config: Config(
        height: emojiHeight,
        checkPlatformCompatibility: true,
        emojiViewConfig: EmojiViewConfig(
          backgroundColor: context.surface,
          columns: widget.emojiColumns,
          emojiSizeMax: widget.emojiSize,
          noRecents: Text(
            'No recents yet. Pick one below.',
            style: TextStyle(fontSize: 14, color: context.textMuted),
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
          hintText: 'Search emoji...',
        ),
      ),
    );
  }

  Widget _buildGifTab() {
    return GifPickerWidget(
      onGifSelected: widget.onGifSelected,
      // No close button -- the panel-level close handles it.
      onClose: null,
      embedMode: true,
    );
  }
}
