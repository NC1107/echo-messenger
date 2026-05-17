import 'dart:io' show Platform;
import 'dart:ui' show Offset, Size;

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
  /// app during the 300×300 splash would write the splash's top-left position
  /// — which sits near the center of the monitor — and on the next launch
  /// [restore] would apply those center-screen coordinates to the full-size
  /// window, pushing it off the bottom-right edge.
  static Future<void> save() async {
    if (!_isDesktop) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final size = await windowManager.getSize();
      // Do not persist geometry while the window is in the small splash state.
      // The splash is 300×300; the minimum restore size is 720×480. Any window
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
        await windowManager.center();
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

  /// Shrink the window to a 300×300 chromeless splash and center it on
  /// screen — matches Discord's boot flow. The title bar is removed via
  /// [TitleBarStyle.hidden] and re-attached by [restore] on completion.
  ///
  /// Centering is done AFTER the size change and again after a short
  /// settle so window managers that snap the resize against the old anchor
  /// don't leave the splash hanging off the edge of the display.
  static Future<void> enterSplash() async {
    if (!_isDesktop) return;
    try {
      await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
      await windowManager.setSize(const Size(300, 300));
      await windowManager.center();
      // Some Wayland/X11 compositors apply the size change asynchronously,
      // so the first center() can race against the resize. Re-center on
      // the next frame to land where the user expects.
      await Future<void>.delayed(const Duration(milliseconds: 16));
      await windowManager.center();
    } catch (_) {
      // Splash-size failures are non-fatal; the user just sees the default
      // material window during boot.
    }
  }
}
