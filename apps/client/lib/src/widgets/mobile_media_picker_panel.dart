import 'dart:io';

import 'package:emoji_picker_flutter/emoji_picker_flutter.dart';
import 'package:flutter/foundation.dart'
    show kIsWeb, defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';
import 'gif_picker_widget.dart';
import 'photo_gallery_picker.dart';

/// Full-width inline picker for mobile that replaces the system keyboard.
///
/// Three tabs: Emoji | GIFs | Photos
/// - Emoji: same config as the desktop [MediaPickerPanel]
/// - GIFs: existing [GifPickerWidget]
/// - Photos: device camera roll via [PhotoGalleryPicker] (mobile only)
class MobileMediaPickerPanel extends StatefulWidget {
  final void Function(Category? category, Emoji emoji) onEmojiSelected;
  final void Function(String gifUrl, String? slug) onGifSelected;
  final void Function(File file, String fileName, String mimeType)
  onPhotoSelected;
  final VoidCallback onClose;

  /// Which tab to show initially (0 = Emoji, 1 = GIFs, 2 = Photos).
  final int initialTab;

  const MobileMediaPickerPanel({
    super.key,
    required this.onEmojiSelected,
    required this.onGifSelected,
    required this.onPhotoSelected,
    required this.onClose,
    this.initialTab = 0,
  });

  @override
  State<MobileMediaPickerPanel> createState() => _MobileMediaPickerPanelState();
}

class _MobileMediaPickerPanelState extends State<MobileMediaPickerPanel>
    with SingleTickerProviderStateMixin {
  late final TabController _tabController;

  /// Photos tab only available on native mobile (not web, not desktop).
  static bool get _hasPhotosTab {
    if (kIsWeb) return false;
    return defaultTargetPlatform == TargetPlatform.android ||
        defaultTargetPlatform == TargetPlatform.iOS;
  }

  @override
  void initState() {
    super.initState();
    final tabCount = _hasPhotosTab ? 3 : 2;
    final initial = widget.initialTab.clamp(0, tabCount - 1);
    _tabController = TabController(
      length: tabCount,
      vsync: this,
      initialIndex: initial,
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: context.surface,
      child: Column(
        children: [
          // Thin separator line
          Container(height: 1, color: context.border),
          // Tab bar
          SizedBox(
            height: 36,
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
                    tabs: [
                      const Tab(height: 34, text: 'Emoji'),
                      const Tab(height: 34, text: 'GIFs'),
                      if (_hasPhotosTab) const Tab(height: 34, text: 'Photos'),
                    ],
                  ),
                ),
                IconButton(
                  icon: Icon(
                    Icons.keyboard,
                    size: 20,
                    color: context.textMuted,
                  ),
                  onPressed: widget.onClose,
                  tooltip: 'Show keyboard',
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 36,
                    minHeight: 36,
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
              children: [
                _buildEmojiTab(context),
                _buildGifTab(),
                if (_hasPhotosTab) _buildPhotosTab(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildEmojiTab(BuildContext context) {
    // Compute columns based on screen width for good emoji density
    final screenWidth = MediaQuery.of(context).size.width;
    final columns = (screenWidth / 42).floor().clamp(7, 12);

    return EmojiPicker(
      onEmojiSelected: widget.onEmojiSelected,
      config: Config(
        height: 400, // ignored when inside Expanded, but required by package
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

  Widget _buildPhotosTab() {
    return PhotoGalleryPicker(onPhotoSelected: widget.onPhotoSelected);
  }
}
