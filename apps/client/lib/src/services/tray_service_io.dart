import 'dart:io';

import 'package:tray_manager/tray_manager.dart';
import 'package:window_manager/window_manager.dart';

/// System tray integration for desktop platforms (Linux, Windows, macOS).
///
/// Initialise once after login with [TrayService.init]. Updates the tray
/// tooltip to reflect the current unread message count via [updateBadge].
/// The context menu provides "Show Echo" and "Quit" actions. Clicking the
/// tray icon toggles the main window visibility. The close button minimises
/// the app to the tray instead of quitting.
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

    await trayManager.setIcon(_iconPath());
    await trayManager.setToolTip('Echo');
    await _setContextMenu();
    trayManager.addListener(this);

    _initialised = true;
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
    await trayManager.setContextMenu(
      Menu(
        items: [
          MenuItem(key: 'show', label: 'Show Echo'),
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
