import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// System tray integration for desktop platforms (Linux, Windows, macOS).
///
/// Initialise once after login with [TrayService.init]. Updates the tray
/// tooltip to reflect the current unread message count via [updateBadge].
/// The context menu provides Show / Hide / Quit actions; the close button
/// minimises the app to the tray instead of quitting.
///
/// **Platform behavior**:
/// - **Windows / macOS**: left-click toggles the window directly via
///   [onTrayIconMouseDown]; right-click opens the context menu.
/// - **Linux** (libappindicator / StatusNotifierItem): the D-Bus protocol
///   that GNOME/KDE shells implement does NOT deliver MouseDown events
///   when a context menu is attached — any click opens the menu. The menu
///   items therefore ARE the interaction surface on Linux. Show / Hide /
///   Quit are first-class entries so users can toggle visibility in two
///   clicks. Switching tray packages does not help: `system_tray` has the
///   same SNI limitation; `tray_icon` uses deprecated GtkStatusIcon (#558).
///
/// Safe to call on all platforms — all methods are no-ops on web and mobile.
class TrayService with TrayListener, WindowListener {
  TrayService._();

  static final TrayService instance = TrayService._();

  bool _initialised = false;

  /// Whether tray is supported on the current platform.
  static bool get isSupported =>
      Platform.isLinux || Platform.isWindows || Platform.isMacOS;

  /// Initialise the system tray. Safe to call multiple times — subsequent
  /// calls are no-ops.
  Future<void> init() async {
    if (!isSupported || _initialised) return;

    // Initialise window_manager first so we can intercept the close event.
    await windowManager.ensureInitialized();
    await windowManager.setPreventClose(true);
    windowManager.addListener(this);

    // Each step is guarded so a failure later in the sequence (notably
    // setContextMenu, which is flaky on some Linux compositors) doesn't
    // leave the icon unresponsive: the click listener still attaches
    // even if the menu can't be installed, which keeps Windows/macOS
    // left-click usable.  On Linux the menu IS the interaction surface
    // (see class docstring), so install failure here means tray is
    // effectively dead until next login.
    var iconShown = false;
    try {
      await trayManager.setIcon(_iconPath());
      iconShown = true;
    } catch (e) {
      debugPrint('[TrayService] setIcon failed: $e');
    }

    try {
      await trayManager.setToolTip('Echo');
    } catch (e) {
      debugPrint('[TrayService] setToolTip failed: $e');
    }

    // Attach listener before menu so taps work even if menu install fails.
    trayManager.addListener(this);

    try {
      await _setContextMenu();
    } catch (e) {
      debugPrint('[TrayService] setContextMenu failed: $e');
    }

    if (iconShown) {
      _initialised = true;
    } else {
      trayManager.removeListener(this);
    }
  }

  /// Call when [TrayService] is no longer needed (e.g. user logs out).
  Future<void> dispose() async {
    if (!_initialised) return;
    trayManager.removeListener(this);
    windowManager.removeListener(this);
    await trayManager.destroy();
    await windowManager.setPreventClose(false);
    _initialised = false;
  }

  /// Update the tray tooltip to show the current unread count.
  Future<void> updateBadge(int unreadCount) async {
    if (!_initialised) return;
    final label = unreadCount > 0
        ? 'Echo - $unreadCount unread message${unreadCount == 1 ? '' : 's'}'
        : 'Echo';
    await trayManager.setToolTip(label);
  }

  // ── WindowListener: minimise to tray on close ─────────────────────────────

  @override
  void onWindowClose() async {
    await windowManager.hide();
  }

  // ── TrayListener ──────────────────────────────────────────────────────────

  @override
  void onTrayIconMouseDown() {
    // Windows + macOS path: the OS delivers a real MouseDown, so we toggle
    // the window directly.  Linux/libappindicator never fires this when a
    // context menu is attached -- any click opens the menu instead, and
    // the user toggles via the Show/Hide menu entries (#558).
    _toggleWindow();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) {
    switch (menuItem.key) {
      case 'show':
        windowManager.show();
        windowManager.focus();
      case 'hide':
        windowManager.hide();
      case 'quit':
        windowManager.setPreventClose(false);
        windowManager.close();
    }
  }

  // ── Helpers ───────────────────────────────────────────────────────────────

  String _iconPath() {
    return 'assets/images/echo_logo_white.png';
  }

  Future<void> _setContextMenu() async {
    // Show / Hide are first-class menu items because on Linux any click on
    // the icon opens this menu (libappindicator/SNI does not deliver
    // MouseDown when a menu is attached) -- they are the only path to
    // toggle window visibility on that platform (#558).
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Show Echo'),
          MenuItem(key: 'hide', label: 'Hide Echo'),
          MenuItem.separator(),
          MenuItem(key: 'quit', label: 'Quit'),
        ],
      ),
    );
  }

  Future<void> _toggleWindow() async {
    final isVisible = await windowManager.isVisible();
    if (isVisible) {
      final isFocused = await windowManager.isFocused();
      if (isFocused) {
        await windowManager.hide();
      } else {
        await windowManager.focus();
      }
    } else {
      await windowManager.show();
      await windowManager.focus();
    }
  }
}
