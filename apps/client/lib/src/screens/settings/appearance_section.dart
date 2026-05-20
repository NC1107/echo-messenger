import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/channel_layout_provider.dart';
import '../../providers/gif_playback_provider.dart';
import '../../providers/theme_provider.dart';
import '../../theme/echo_theme.dart';
import 'advanced_theme_section.dart';

/// SharedPreferences key for GIF autoplay setting.
const kGifAutoplayKey = 'gif_autoplay_enabled';

/// Preview color data for rendering a miniature theme thumbnail.
class _ThemePreviewColors {
  final Color sidebarBg;
  final Color mainBg;
  final Color sentBubble;
  final Color recvBubble;
  final Color accent;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;

  const _ThemePreviewColors({
    required this.sidebarBg,
    required this.mainBg,
    required this.sentBubble,
    required this.recvBubble,
    required this.accent,
    required this.border,
    required this.textPrimary,
    required this.textSecondary,
  });
}

const _darkPreview = _ThemePreviewColors(
  sidebarBg: EchoTheme.sidebarBg,
  mainBg: EchoTheme.mainBg,
  sentBubble: EchoTheme.sentBubble,
  recvBubble: EchoTheme.recvBubble,
  accent: EchoTheme.accent,
  border: EchoTheme.border,
  textPrimary: EchoTheme.textPrimary,
  textSecondary: EchoTheme.textSecondary,
);

const _lightPreview = _ThemePreviewColors(
  sidebarBg: EchoTheme.lightSidebarBg,
  mainBg: EchoTheme.lightMainBg,
  sentBubble: EchoTheme.lightSentBubble,
  recvBubble: EchoTheme.lightRecvBubble,
  accent: EchoTheme.paperAccent,
  border: EchoTheme.lightBorder,
  textPrimary: EchoTheme.lightTextPrimary,
  textSecondary: EchoTheme.lightTextSecondary,
);

const _graphitePreview = _ThemePreviewColors(
  sidebarBg: EchoTheme.graphiteSidebarBg,
  mainBg: EchoTheme.graphiteMainBg,
  sentBubble: EchoTheme.graphiteSentBubble,
  recvBubble: EchoTheme.graphiteRecvBubble,
  accent: EchoTheme.graphiteAccent,
  border: EchoTheme.graphiteBorder,
  textPrimary: EchoTheme.graphiteTextPrimary,
  textSecondary: EchoTheme.graphiteTextSecondary,
);

const _emberPreview = _ThemePreviewColors(
  sidebarBg: EchoTheme.emberSidebarBg,
  mainBg: EchoTheme.emberMainBg,
  sentBubble: EchoTheme.emberSentBubble,
  recvBubble: EchoTheme.emberRecvBubble,
  accent: EchoTheme.emberAccent,
  border: EchoTheme.emberBorder,
  textPrimary: EchoTheme.emberTextPrimary,
  textSecondary: EchoTheme.emberTextSecondary,
);

const _sakuraPreview = _ThemePreviewColors(
  sidebarBg: EchoTheme.sakuraSidebarBg,
  mainBg: EchoTheme.sakuraMainBg,
  sentBubble: EchoTheme.sakuraSentBubble,
  recvBubble: EchoTheme.sakuraRecvBubble,
  accent: EchoTheme.sakuraAccent,
  border: EchoTheme.sakuraBorder,
  textPrimary: EchoTheme.sakuraTextPrimary,
  textSecondary: EchoTheme.sakuraTextSecondary,
);

const _highContrastPreview = _ThemePreviewColors(
  sidebarBg: Color(0xFF0A0A0A),
  mainBg: Color(0xFF000000),
  sentBubble: Color(0xFF7C9BFF),
  recvBubble: Color(0xFF000000),
  accent: Color(0xFF7C9BFF),
  border: Color(0xFF8A8A8A),
  textPrimary: Color(0xFFFFFFFF),
  textSecondary: Color(0xFFCCCCCC),
);

class AppearanceSection extends ConsumerStatefulWidget {
  const AppearanceSection({super.key});

  @override
  ConsumerState<AppearanceSection> createState() => _AppearanceSectionState();
}

class _AppearanceSectionState extends ConsumerState<AppearanceSection> {
  Future<void> _setGifAutoplay(bool value) async {
    await ref.read(gifPlaybackProvider.notifier).setAutoplay(value);
  }

  @override
  Widget build(BuildContext context) {
    final currentTheme = ref.watch(themeProvider);
    // Card order (palette reduction 2026-05-11): Indigo, Graphite, Ember,
    // Paper, Sakura, High contrast. System lives at the top as the "follow
    // device" affordance and is not part of the six-palette set.
    const themeOptions = <_ThemeCardData>[
      _ThemeCardData(
        selection: AppThemeSelection.system,
        label: 'System',
        subtitle: 'Follow device settings',
        preview: null, // special split preview
      ),
      _ThemeCardData(
        selection: AppThemeSelection.indigo,
        label: 'Indigo',
        subtitle: 'Default accent',
        preview: _darkPreview,
      ),
      _ThemeCardData(
        selection: AppThemeSelection.graphite,
        label: 'Graphite',
        subtitle: 'Teal on cool black',
        preview: _graphitePreview,
      ),
      _ThemeCardData(
        selection: AppThemeSelection.ember,
        label: 'Ember',
        subtitle: 'Amber on warm black',
        preview: _emberPreview,
      ),
      _ThemeCardData(
        selection: AppThemeSelection.paper,
        label: 'Paper',
        subtitle: 'Warm off-white',
        preview: _lightPreview,
      ),
      _ThemeCardData(
        selection: AppThemeSelection.sakura,
        label: 'Sakura',
        subtitle: 'Soft pink pastels',
        preview: _sakuraPreview,
      ),
      _ThemeCardData(
        selection: AppThemeSelection.highContrast,
        label: 'High contrast',
        subtitle: 'WCAG AAA accessibility',
        preview: _highContrastPreview,
      ),
    ];

    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Theme',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Choose a theme. All themes are tuned for WCAG AA contrast.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const Divider(height: 24),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              alignment: WrapAlignment.center,
              children: themeOptions
                  .map(
                    (data) => _ThemeCard(
                      data: data,
                      isSelected: currentTheme == data.selection,
                      onTap: () => ref
                          .read(themeProvider.notifier)
                          .setTheme(data.selection),
                    ),
                  )
                  .toList(),
            ),
            const SizedBox(height: 32),
            Text(
              'Message layout',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _LayoutOption(
              label: 'Default',
              subtitle: 'Bubbles aligned by sender, like iMessage or WhatsApp',
              icon: Icons.chat_bubble_outline,
              isSelected:
                  ref.watch(messageLayoutProvider) == MessageLayout.bubbles,
              onTap: () => ref
                  .read(messageLayoutProvider.notifier)
                  .setLayout(MessageLayout.bubbles),
            ),
            const SizedBox(height: 8),
            _LayoutOption(
              label: 'Discord',
              subtitle:
                  'Left-aligned with avatars and usernames, grouped by sender',
              icon: Icons.format_align_left_outlined,
              isSelected:
                  ref.watch(messageLayoutProvider) == MessageLayout.compact,
              onTap: () => ref
                  .read(messageLayoutProvider.notifier)
                  .setLayout(MessageLayout.compact),
            ),
            const SizedBox(height: 8),
            _LayoutOption(
              label: 'Slack',
              subtitle: 'Left-aligned, no bubbles — clean document-style feed',
              icon: Icons.notes_outlined,
              isSelected:
                  ref.watch(messageLayoutProvider) == MessageLayout.plain,
              onTap: () => ref
                  .read(messageLayoutProvider.notifier)
                  .setLayout(MessageLayout.plain),
            ),
            const SizedBox(height: 32),
            // Density tier — UX roadmap Phase 2.  Independent of message
            // layout: density tunes sidebar row spacing without changing
            // bubble style.
            Text(
              'Density',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _LayoutOption(
              label: 'Cozy',
              subtitle: 'More breathing room',
              icon: Icons.density_large,
              isSelected: ref.watch(uiDensityProvider) == UIDensity.cozy,
              onTap: () => ref
                  .read(uiDensityProvider.notifier)
                  .setDensity(UIDensity.cozy),
            ),
            const SizedBox(height: 8),
            _LayoutOption(
              label: 'Normal',
              subtitle: 'Balanced default',
              icon: Icons.density_medium,
              isSelected: ref.watch(uiDensityProvider) == UIDensity.normal,
              onTap: () => ref
                  .read(uiDensityProvider.notifier)
                  .setDensity(UIDensity.normal),
            ),
            const SizedBox(height: 8),
            _LayoutOption(
              label: 'Compact',
              subtitle: 'Power-user dense, Discord-style',
              icon: Icons.density_small,
              isSelected: ref.watch(uiDensityProvider) == UIDensity.compact,
              onTap: () => ref
                  .read(uiDensityProvider.notifier)
                  .setDensity(UIDensity.compact),
            ),
            const SizedBox(height: 32),
            // Channel layout — top chip bar vs Slack/Discord vertical column.
            // The toggle only affects desktop wide layouts; narrow viewports
            // always render the bar because a column doesn't fit on phones.
            Text(
              'Channels',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            _LayoutOption(
              label: 'Bar',
              subtitle: 'Chip row above the chat (current default)',
              icon: Icons.view_stream_outlined,
              isSelected: ref.watch(channelLayoutProvider) == ChannelLayout.bar,
              onTap: () => ref
                  .read(channelLayoutProvider.notifier)
                  .setLayout(ChannelLayout.bar),
            ),
            const SizedBox(height: 8),
            _LayoutOption(
              label: 'Column',
              subtitle: 'Slack/Discord-style vertical channel list',
              icon: Icons.view_sidebar_outlined,
              isSelected:
                  ref.watch(channelLayoutProvider) == ChannelLayout.column,
              onTap: () => ref
                  .read(channelLayoutProvider.notifier)
                  .setLayout(ChannelLayout.column),
            ),
            const SizedBox(height: 24),
            // GIF autoplay
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              title: Text(
                'Auto-play GIFs',
                style: TextStyle(color: context.textPrimary, fontSize: 14),
              ),
              subtitle: Text(
                'When off, GIFs show as static thumbnails with a play button.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: ref.watch(gifPlaybackProvider).autoplayEnabled,
              onChanged: _setGifAutoplay,
            ),
            const SizedBox(height: 32),
            // Advanced color overrides (issue #613)
            Text(
              'Advanced',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Override the active theme\'s primary and accent colors.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 12),
            const AdvancedThemeInline(),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Data holder for each theme card
// ---------------------------------------------------------------------------

class _ThemeCardData {
  final AppThemeSelection selection;
  final String label;
  final String subtitle;

  /// Null means "system" -- renders a split dark/light preview.
  final _ThemePreviewColors? preview;

  const _ThemeCardData({
    required this.selection,
    required this.label,
    required this.subtitle,
    required this.preview,
  });
}

// ---------------------------------------------------------------------------
// Theme card with color-swatch thumbnail
// ---------------------------------------------------------------------------

class _ThemeCard extends StatelessWidget {
  final _ThemeCardData data;
  final bool isSelected;
  final VoidCallback onTap;

  const _ThemeCard({
    required this.data,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '${data.label} theme',
      button: true,
      selected: isSelected,
      child: SizedBox(
        width: 140,
        child: Material(
          color: isSelected ? context.accentLight : Colors.transparent,
          borderRadius: BorderRadius.circular(10),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(10),
            hoverColor: context.surfaceHover,
            child: Container(
              padding: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(10),
                border: Border.all(
                  color: isSelected ? context.accent : context.border,
                  width: isSelected ? 2 : 1,
                ),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // Thumbnail
                  ClipRRect(
                    borderRadius: BorderRadius.circular(6),
                    child: SizedBox(
                      height: 90,
                      width: double.infinity,
                      child: data.preview != null
                          ? _ThemeThumbnail(colors: data.preview!)
                          : _SystemThemeThumbnail(),
                    ),
                  ),
                  const SizedBox(height: 8),
                  // Label row
                  Row(
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              data.label,
                              style: TextStyle(
                                color: isSelected
                                    ? context.accent
                                    : context.textPrimary,
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 1),
                            Text(
                              data.subtitle,
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 11,
                              ),
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            ),
                          ],
                        ),
                      ),
                      if (isSelected)
                        Padding(
                          padding: const EdgeInsets.only(left: 4),
                          child: Icon(
                            Icons.check_circle,
                            size: 18,
                            color: context.accent,
                          ),
                        ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Miniature theme preview: sidebar strip + chat area with message bubbles
// ---------------------------------------------------------------------------

class _ThemeThumbnail extends StatelessWidget {
  final _ThemePreviewColors colors;

  const _ThemeThumbnail({required this.colors});

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: colors.border, width: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5.5),
        child: Row(
          children: [
            // Sidebar strip (30%)
            Expanded(
              flex: 30,
              child: Container(
                color: colors.sidebarBg,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    // Tiny sidebar items
                    const SizedBox(height: 10),
                    _sidebarLine(colors.textSecondary, 0.5, 18),
                    const SizedBox(height: 6),
                    _sidebarLine(colors.accent, 0.8, 22),
                    const SizedBox(height: 6),
                    _sidebarLine(colors.textSecondary, 0.3, 16),
                    const SizedBox(height: 6),
                    _sidebarLine(colors.textSecondary, 0.3, 14),
                  ],
                ),
              ),
            ),
            // Divider line
            Container(width: 0.5, color: colors.border),
            // Chat area (70%)
            Expanded(
              flex: 70,
              child: Container(
                color: colors.mainBg,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Header bar hint
                    Container(
                      height: 3,
                      width: 30,
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: colors.textPrimary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                    // Received message bubble (left)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 42,
                        height: 14,
                        decoration: BoxDecoration(
                          color: colors.recvBubble,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    // Received message bubble (left, shorter)
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 30,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colors.recvBubble,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    // Sent message bubble (right)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 38,
                        height: 14,
                        decoration: BoxDecoration(
                          color: colors.sentBubble,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                    const SizedBox(height: 5),
                    // Sent message bubble (right, shorter)
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 28,
                        height: 10,
                        decoration: BoxDecoration(
                          color: colors.sentBubble,
                          borderRadius: BorderRadius.circular(4),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _sidebarLine(Color color, double opacity, double width) {
    return Padding(
      padding: const EdgeInsets.only(left: 6),
      child: Container(
        height: 3,
        width: width,
        decoration: BoxDecoration(
          color: color.withValues(alpha: opacity),
          borderRadius: BorderRadius.circular(1.5),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// System theme preview: split dark / light halves
// ---------------------------------------------------------------------------

class _SystemThemeThumbnail extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: EchoTheme.border, width: 0.5),
        borderRadius: BorderRadius.circular(6),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(5.5),
        child: Row(
          children: [
            // Dark half
            Expanded(
              child: Container(
                color: EchoTheme.mainBg,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Sidebar hint
                    Container(
                      height: 3,
                      width: 20,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: EchoTheme.textSecondary.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 26,
                        height: 10,
                        decoration: BoxDecoration(
                          color: EchoTheme.recvBubble,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 22,
                        height: 10,
                        decoration: BoxDecoration(
                          color: EchoTheme.sentBubble,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Moon icon hint
                    Center(
                      child: Icon(
                        Icons.dark_mode,
                        size: 14,
                        color: EchoTheme.textSecondary.withValues(alpha: 0.6),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            // Divider
            Container(width: 0.5, color: EchoTheme.border),
            // Light half
            Expanded(
              child: Container(
                color: EchoTheme.lightMainBg,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // Sidebar hint
                    Container(
                      height: 3,
                      width: 20,
                      margin: const EdgeInsets.only(bottom: 8),
                      decoration: BoxDecoration(
                        color: EchoTheme.lightTextSecondary.withValues(
                          alpha: 0.5,
                        ),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
                    Align(
                      alignment: Alignment.centerLeft,
                      child: Container(
                        width: 26,
                        height: 10,
                        decoration: BoxDecoration(
                          color: EchoTheme.lightRecvBubble,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Align(
                      alignment: Alignment.centerRight,
                      child: Container(
                        width: 22,
                        height: 10,
                        decoration: BoxDecoration(
                          color: EchoTheme.lightSentBubble,
                          borderRadius: BorderRadius.circular(3),
                        ),
                      ),
                    ),
                    const Spacer(),
                    // Sun icon hint
                    Center(
                      child: Icon(
                        Icons.light_mode,
                        size: 14,
                        color: EchoTheme.lightTextSecondary.withValues(
                          alpha: 0.6,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Layout option (reused for message layout choices, kept as vertical list)
// ---------------------------------------------------------------------------

class _LayoutOption extends StatelessWidget {
  final String label;
  final String subtitle;
  final IconData icon;
  final bool isSelected;
  final VoidCallback onTap;

  const _LayoutOption({
    required this.label,
    required this.subtitle,
    required this.icon,
    required this.isSelected,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: '$label layout',
      button: true,
      selected: isSelected,
      child: Material(
        color: isSelected ? context.accentLight : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(10),
          hoverColor: context.surfaceHover,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 14),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: isSelected ? context.accent : context.border,
                width: 1,
              ),
            ),
            child: Row(
              children: [
                Icon(
                  icon,
                  size: 22,
                  color: isSelected ? context.accent : context.textSecondary,
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        label,
                        style: TextStyle(
                          color: isSelected
                              ? context.accent
                              : context.textPrimary,
                          fontSize: 14,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: context.textMuted,
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
                if (isSelected)
                  Icon(Icons.check_circle, size: 20, color: context.accent),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
