import 'dart:io' show Platform;
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:screen_retriever/screen_retriever.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:window_manager/window_manager.dart';

/// Persists and restores the native window geometry across app launches so the
/// post-splash window expands to the user's last layout instead of the
/// Material default. Pairs with the Discord-style small-splash flow that
/// shrinks the window during boot.
///
/// No-ops on web/mobile — `windowManager` is desktop-only (Linux, Windows,
/// macOS). Failures are swallowed so a busted SharedPreferences box never
/// blocks startup.
class WindowStateService {
  static const _kWidthKey = 'window.width';
  static const _kHeightKey = 'window.height';
  static const _kXKey = 'window.x';
  static const _kYKey = 'window.y';

  /// Default window size on first launch (matches the GTK runner's
  /// `gtk_window_set_default_size(1280, 720)`).
  static const Size defaultSize = Size(1280, 720);

  /// Default top-left anchor on first launch — small inset off the screen
  /// corner so the title bar doesn't kiss the edge. Both [enterSplash] and
  /// [restore] use this so the splash and the post-splash window line up
  /// (no visible jump when the window grows).
  static const Offset _kTopLeftAnchor = Offset(40, 40);

  /// True on a desktop platform where `window_manager` is supported.
  static bool get _isDesktop {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  }

  /// Save the current window size + position to SharedPreferences.
  ///
  /// Position is clamped on restore to stay on-screen; here we just store
  /// whatever the user last positioned the window to.
  ///
  /// Skips saving when the window is in splash state (smaller than the
  /// minimum restore thresholds of 720×480). Without this guard, closing the
  /// app during the 320×440 splash would write the splash's top-left position
  /// — which sits near the center of the monitor — and on the next launch
  /// [restore] would apply those center-screen coordinates to the full-size
  /// window, pushing it off the bottom-right edge.
  static Future<void> save() async {
    if (!_isDesktop) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final size = await windowManager.getSize();
      // Do not persist geometry while the window is in the small splash state.
      // The splash is 320×440; the minimum restore size is 720×480. Any window
      // smaller than those thresholds means we are still in (or were left in)
      // the splash phase and the coordinates would corrupt the next launch.
      if (size.width < 720.0 || size.height < 480.0) return;
      await prefs.setDouble(_kWidthKey, size.width);
      await prefs.setDouble(_kHeightKey, size.height);
      try {
        final pos = await windowManager.getPosition();
        await prefs.setDouble(_kXKey, pos.dx);
        await prefs.setDouble(_kYKey, pos.dy);
      } catch (_) {
        // getPosition isn't reliable on all platforms; size alone is fine.
      }
    } catch (_) {
      // Never block app shutdown on a failed window-state save.
    }
  }

  /// Restore the previously-saved window size + position AND re-attach the
  /// native title bar that [enterSplash] removed. Falls back to [defaultSize]
  /// centered on the primary display when no prior state is recorded.
  static Future<void> restore() async {
    if (!_isDesktop) return;
    try {
      // Keep the window frameless permanently for the integrated title bar.
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);

      // Set minimum window size so users can't shrink into an unusable state.
      await windowManager.setMinimumSize(const Size(720, 480));

      final prefs = await SharedPreferences.getInstance();
      final width = prefs.getDouble(_kWidthKey) ?? defaultSize.width;
      final height = prefs.getDouble(_kHeightKey) ?? defaultSize.height;
      // Clamp to sensible minimums so a stale 100x100 setting can't render
      // a useless window.
      final size = Size(
        width.clamp(720.0, 10000.0),
        height.clamp(480.0, 10000.0),
      );
      await windowManager.setSize(size);
      // Restore saved (x, y) only when both axes land inside the current
      // primary display.  A multi-monitor disconnect or resolution change
      // can park a previously valid coordinate halfway off-screen, leaving
      // the user with a window they can barely grab (#whats-new-titlebar).
      final savedX = prefs.getDouble(_kXKey);
      final savedY = prefs.getDouble(_kYKey);
      if (savedX != null &&
          savedY != null &&
          await _isOnScreen(savedX, savedY, size)) {
        await windowManager.setPosition(Offset(savedX, savedY));
      } else {
        // First-launch default: centre the full-size window on the primary
        // display. Earlier this snapped to the same top-left anchor as the
        // splash, which made the post-splash window appear to "grow" out of
        // the splash's exact corner instead of being a separate window
        // landing in a natural place. center() handles multi-monitor and
        // window-manager work-area quirks better than us math'ing it.
        try {
          await windowManager.center();
        } catch (_) {
          // Fall back to the safe inset if center() is unsupported on
          // this compositor.
          await windowManager.setPosition(_kTopLeftAnchor);
        }
      }
    } catch (_) {
      // Falling back to whatever size the splash set is acceptable.
    }
  }

  /// True when at least 200 px of the window's top-left corner stays inside
  /// the primary display's work area, so the user can always grab the
  /// integrated title bar to drag the window back into view.
  static Future<bool> _isOnScreen(double x, double y, Size size) async {
    try {
      final display = await screenRetriever.getPrimaryDisplay();
      final screenSize = display.size;
      const minVisible = 200.0;
      final maxX = screenSize.width - minVisible;
      final maxY = screenSize.height - minVisible;
      // Allow slight negative for stacked-window managers that report the
      // titlebar above the work area, but never more than 50 px.
      return x > -50.0 && y > -50.0 && x < maxX && y < maxY;
    } catch (_) {
      // If we can't introspect the display, prefer center() over a stale
      // saved coordinate.
      return false;
    }
  }

  /// Resize the chromeless splash window to a size that comfortably fits
  /// the update prompt (logo, version cycle, progress bar, full-width
  /// action button, error text, Skip). The splash's 320×440 is too tight
  /// for an actionable screen — buttons crowd the edges and longer error
  /// strings wrap awkwardly. Keeps the splash chrome (transparent
  /// background, hidden title bar) so the swap stays seamless.
  static Future<void> enterUpdatePrompt() async {
    if (!_isDesktop) return;
    try {
      await windowManager.setSize(const Size(400, 520));
    } catch (_) {
      // Resize failure is non-fatal — the user still sees the 320×440
      // splash-sized prompt, just a bit cramped.
    }
  }

  /// Shrink the window to a 320×440 chromeless splash and anchor it near
  /// the top-left of the primary display so it lines up with where the
  /// post-splash window will appear (eliminating the small-to-large jump
  /// users were seeing on first launch). The title bar is removed via
  /// [TitleBarStyle.hidden] and re-attached by [restore] on completion.
  ///
  /// Also makes the window transparent so the splash's rounded corners
  /// aren't framed by a rectangular OS chrome around them. Reverted by
  /// [restore]. Window-level transparency requires a compositing window
  /// manager; if unsupported the window just stays opaque with squared
  /// corners, which is also acceptable.
  static Future<void> enterSplash() async {
    if (!_isDesktop) return;
    try {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setSize(const Size(320, 440));
      // Make the window background transparent so the splash card's
      // rounded corners blend into the desktop instead of being framed
      // by a rectangular OS surface.
      try {
        await windowManager.setBackgroundColor(const Color(0x00000000));
        await windowManager.setHasShadow(false);
      } catch (_) {
        // Transparency is best-effort; not every compositor supports it.
      }
      // Anchor the splash near the top-left of the primary display so the
      // post-splash window (which restores to a saved position OR the same
      // top-left anchor) doesn't visibly jump on first launch. Wayland/X11
      // compositors can apply the size change asynchronously, so we set
      // the position again on the next frame as a safety net.
      await windowManager.setPosition(_kTopLeftAnchor);
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await windowManager.setPosition(_kTopLeftAnchor);
    } catch (_) {
      // Splash-size failures are non-fatal; the user just sees the default
      // material window during boot.
    }
  }
}
