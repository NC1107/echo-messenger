import 'dart:io' show Platform;
import 'dart:ui' show Offset, Size;

import 'package:flutter/foundation.dart' show kIsWeb;
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
  static Future<void> save() async {
    if (!_isDesktop) return;
    try {
      final prefs = await SharedPreferences.getInstance();
      final size = await windowManager.getSize();
      final position = await windowManager.getPosition();
      await prefs.setDouble(_kWidthKey, size.width);
      await prefs.setDouble(_kHeightKey, size.height);
      await prefs.setDouble(_kXKey, position.dx);
      await prefs.setDouble(_kYKey, position.dy);
    } catch (_) {
      // Never block app shutdown on a failed window-state save.
    }
  }

  /// Restore the previously-saved window size + position, falling back to
  /// the [defaultSize] centered on the primary display when no prior state
  /// is recorded.
  static Future<void> restore() async {
    if (!_isDesktop) return;
    try {
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
      final x = prefs.getDouble(_kXKey);
      final y = prefs.getDouble(_kYKey);
      if (x != null && y != null) {
        await windowManager.setPosition(Offset(x, y));
      } else {
        await windowManager.center();
      }
    } catch (_) {
      // Falling back to whatever size the splash set is acceptable.
    }
  }

  /// Shrink the window to a 300×300 splash and center it on screen. Used by
  /// the splash screen during auto-login so boot feels lightweight.
  static Future<void> enterSplash() async {
    if (!_isDesktop) return;
    try {
      await windowManager.setSize(const Size(300, 300));
      await windowManager.center();
    } catch (_) {
      // Splash-size failures are non-fatal; the user just sees the default
      // material window during boot.
    }
  }
}
