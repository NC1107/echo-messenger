/// Shared theme-preview thumbnails used by the Settings → Appearance picker
/// and the onboarding wizard's "Choose your look" step.
///
/// The thumbnail renders a miniature sidebar + chat-bubble preview of a
/// theme so users see the actual sent/received bubble colours instead of a
/// single accent swatch. The system option renders a split dark/light
/// preview with a moon + sun glyph.
library;

import 'package:flutter/material.dart';

import '../theme/echo_theme.dart';

/// Palette tuple a theme thumbnail renders. Mirrors the runtime
/// EchoTheme tokens at a one-time snapshot so the thumbnail is `const`-able
/// and never has to read from `Theme.of(context)`.
class ThemePreviewColors {
  final Color sidebarBg;
  final Color mainBg;
  final Color sentBubble;
  final Color recvBubble;
  final Color accent;
  final Color border;
  final Color textPrimary;
  final Color textSecondary;

  const ThemePreviewColors({
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

const darkPreview = ThemePreviewColors(
  sidebarBg: EchoTheme.sidebarBg,
  mainBg: EchoTheme.mainBg,
  sentBubble: EchoTheme.sentBubble,
  recvBubble: EchoTheme.recvBubble,
  accent: EchoTheme.accent,
  border: EchoTheme.border,
  textPrimary: EchoTheme.textPrimary,
  textSecondary: EchoTheme.textSecondary,
);

/// Indigo is the default dark theme — same palette as [darkPreview].
/// Named alias so callers can reference it by theme name without knowing
/// that "Indigo" and "dark" are the same underlying palette.
const indigoPreview = darkPreview;

const lightPreview = ThemePreviewColors(
  sidebarBg: EchoTheme.lightSidebarBg,
  mainBg: EchoTheme.lightMainBg,
  sentBubble: EchoTheme.lightSentBubble,
  recvBubble: EchoTheme.lightRecvBubble,
  accent: EchoTheme.paperAccent,
  border: EchoTheme.lightBorder,
  textPrimary: EchoTheme.lightTextPrimary,
  textSecondary: EchoTheme.lightTextSecondary,
);

const graphitePreview = ThemePreviewColors(
  sidebarBg: EchoTheme.graphiteSidebarBg,
  mainBg: EchoTheme.graphiteMainBg,
  sentBubble: EchoTheme.graphiteSentBubble,
  recvBubble: EchoTheme.graphiteRecvBubble,
  accent: EchoTheme.graphiteAccent,
  border: EchoTheme.graphiteBorder,
  textPrimary: EchoTheme.graphiteTextPrimary,
  textSecondary: EchoTheme.graphiteTextSecondary,
);

const emberPreview = ThemePreviewColors(
  sidebarBg: EchoTheme.emberSidebarBg,
  mainBg: EchoTheme.emberMainBg,
  sentBubble: EchoTheme.emberSentBubble,
  recvBubble: EchoTheme.emberRecvBubble,
  accent: EchoTheme.emberAccent,
  border: EchoTheme.emberBorder,
  textPrimary: EchoTheme.emberTextPrimary,
  textSecondary: EchoTheme.emberTextSecondary,
);

const sakuraPreview = ThemePreviewColors(
  sidebarBg: EchoTheme.sakuraSidebarBg,
  mainBg: EchoTheme.sakuraMainBg,
  sentBubble: EchoTheme.sakuraSentBubble,
  recvBubble: EchoTheme.sakuraRecvBubble,
  accent: EchoTheme.sakuraAccent,
  border: EchoTheme.sakuraBorder,
  textPrimary: EchoTheme.sakuraTextPrimary,
  textSecondary: EchoTheme.sakuraTextSecondary,
);

const highContrastPreview = ThemePreviewColors(
  sidebarBg: Color(0xFF0A0A0A),
  mainBg: Color(0xFF000000),
  sentBubble: Color(0xFF7C9BFF),
  recvBubble: Color(0xFF000000),
  accent: Color(0xFF7C9BFF),
  border: Color(0xFF8A8A8A),
  textPrimary: Color(0xFFFFFFFF),
  textSecondary: Color(0xFFCCCCCC),
);

/// Miniature chat preview rendered inside a theme card. Stateless and
/// const-instantiable so it can live inside `const`-built theme grids.
class ThemeThumbnail extends StatelessWidget {
  final ThemePreviewColors colors;

  const ThemeThumbnail({super.key, required this.colors});

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
            Container(width: 0.5, color: colors.border),
            // Chat area (70%)
            Expanded(
              flex: 70,
              child: Container(
                color: colors.mainBg,
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: 3,
                      width: 30,
                      margin: const EdgeInsets.only(bottom: 10),
                      decoration: BoxDecoration(
                        color: colors.textPrimary.withValues(alpha: 0.3),
                        borderRadius: BorderRadius.circular(1.5),
                      ),
                    ),
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

/// "Follow device" preview: side-by-side dark + light halves with a
/// moon/sun glyph so the card reads as "system follows your OS setting".
class SystemThemeThumbnail extends StatelessWidget {
  const SystemThemeThumbnail({super.key});

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
            Container(width: 0.5, color: EchoTheme.border),
            // Light half
            Expanded(
              child: Container(
                color: EchoTheme.lightMainBg,
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
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
