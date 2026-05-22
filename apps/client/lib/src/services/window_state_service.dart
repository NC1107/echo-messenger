import 'dart:io' show Platform;
import 'dart:ui' show Color, Offset, Size;

import 'package:flutter/foundation.dart' show kIsWeb, visibleForTesting;
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

  /// Maximum allowed drift (in logical pixels) between the position we
  /// requested via [setPosition] and the position the compositor actually
  /// applied. When the drift exceeds this value we fall back to [center()].
  ///
  /// Wayland compositors that run with an XWayland fallback sometimes honour
  /// `setPosition` on the first call but then silently undo it; compositors
  /// without X11 support always ignore it. 200 px is large enough that a
  /// compositor applying DPI scaling won't false-positive, but small enough to
  /// catch the typical "window stayed at (0,0)" failure mode.
  static const double _kPositionDriftTolerance = 200.0;

  /// True on a desktop platform where `window_manager` is supported.
  static bool get _isDesktop {
    if (kIsWeb) return false;
    return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
  }

  /// Override for tests — set to [true] to simulate a Wayland session, [false]
  /// to simulate X11/non-Wayland, or leave [null] to use env-var detection.
  @visibleForTesting
  static bool? debugOverrideIsWayland;

  /// True when the current Linux session is running under a Wayland compositor.
  ///
  /// On Wayland, `windowManager.setPosition` is a no-op: the Wayland protocol
  /// does not allow clients to dictate their own position — that is the
  /// compositor's exclusive responsibility. Similarly, `getPosition` returns
  /// compositor-local surface coordinates (often (0, 0)) that do not reflect
  /// the window's real on-screen position. Saving and restoring those values
  /// would therefore produce broken results.
  ///
  /// The fix: skip position save/restore on Wayland entirely; restore SIZE
  /// only and let the compositor place the window (as Discord, Slack, and
  /// Chromium all do on Wayland).
  ///
  /// Detection: `WAYLAND_DISPLAY` being set is the canonical signal.
  /// `XDG_SESSION_TYPE=wayland` covers setups where the display variable is
  /// absent but the session type is still declared (some minimal compositors).
  ///
  /// Exposed via [debugOverrideIsWayland] so unit tests can exercise both
  /// branches without touching real environment variables.
  static bool get isWaylandSession {
    if (debugOverrideIsWayland != null) return debugOverrideIsWayland!;
    if (!Platform.isLinux) return false;
    final env = Platform.environment;
    return env.containsKey('WAYLAND_DISPLAY') ||
        env['XDG_SESSION_TYPE']?.toLowerCase() == 'wayland';
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
  ///
  /// Position is also skipped on Wayland because [windowManager.getPosition]
  /// returns compositor-local surface coordinates (typically (0, 0)) that do
  /// not reflect the true on-screen position and would produce invalid saved
  /// values.
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
      // On Wayland, getPosition() returns compositor-local coordinates that
      // don't map to global screen position. Skip saving x/y to prevent bogus
      // values from corrupting the next restore.
      if (!isWaylandSession) {
        try {
          final pos = await windowManager.getPosition();
          await prefs.setDouble(_kXKey, pos.dx);
          await prefs.setDouble(_kYKey, pos.dy);
        } catch (_) {
          // getPosition isn't reliable on all platforms; size alone is fine.
        }
      }
    } catch (_) {
      // Never block app shutdown on a failed window-state save.
    }
  }

  /// Restore the previously-saved window size + position AND re-attach the
  /// native title bar that [enterSplash] removed. Falls back to [defaultSize]
  /// centered on the primary display when no prior state is recorded.
  ///
  /// On Wayland the position restore is skipped entirely — the compositor owns
  /// placement and [windowManager.setPosition] is a no-op. Size is still
  /// restored. On X11/Windows/macOS the full save/restore cycle applies, but
  /// a post-restore drift-check verifies that the compositor actually honoured
  /// the requested position; if it drifted by more than
  /// [_kPositionDriftTolerance] pixels the window is centered as a safety net.
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

      // On Wayland, setPosition is a compositor no-op. Skip position restore
      // and let the compositor decide where to place the window.
      if (!isWaylandSession) {
        // Restore saved (x, y) only when both axes land inside at least one
        // connected display. A multi-monitor disconnect or resolution change
        // can park a previously valid coordinate off-screen.
        final savedX = prefs.getDouble(_kXKey);
        final savedY = prefs.getDouble(_kYKey);
        if (savedX != null &&
            savedY != null &&
            await _isOnScreen(savedX, savedY, size)) {
          await windowManager.setPosition(Offset(savedX, savedY));
          // Safety-net drift check: verify the compositor actually applied the
          // position. If the window drifted by more than the tolerance (e.g.
          // XWayland or a non-standard compositor silently ignored the hint),
          // fall back to center() so the window is always visible.
          await _centerIfDrifted(savedX, savedY);
          return;
        }
      }

      // Wayland, first-launch, or no valid saved position: let the compositor
      // decide placement. center() handles multi-monitor work-area quirks
      // better than hand-computing the offset.
      try {
        await windowManager.center();
      } catch (_) {
        // Fall back to the safe inset if center() is unsupported on
        // this compositor.
        await windowManager.setPosition(_kTopLeftAnchor);
      }
    } catch (_) {
      // Falling back to whatever size the splash set is acceptable.
    }
  }

  /// Checks whether the actual window position has drifted more than
  /// [_kPositionDriftTolerance] pixels from the requested [expectedX]/
  /// [expectedY]. If so — meaning the compositor silently ignored our
  /// `setPosition` call — falls back to [center()] so the user always sees
  /// the window within the visible work area.
  static Future<void> _centerIfDrifted(
    double expectedX,
    double expectedY,
  ) async {
    try {
      final actual = await windowManager.getPosition();
      final dx = (actual.dx - expectedX).abs();
      final dy = (actual.dy - expectedY).abs();
      if (dx > _kPositionDriftTolerance || dy > _kPositionDriftTolerance) {
        await windowManager.center();
      }
    } catch (_) {
      // If we can't read back the position, try centering as a safety net.
      try {
        await windowManager.center();
      } catch (_) {}
    }
  }

  /// True when at least 100 px of the window's top-left corner stays inside
  /// ANY connected display's work area, so the user can always grab the
  /// integrated title bar to drag the window back into view.
  ///
  /// Previously this checked only the PRIMARY display, which caused false
  /// positives (or negatives) when:
  ///   - the window was on a secondary monitor,
  ///   - a monitor was unplugged between sessions (saved coord from the
  ///     now-gone display would fail the primary-only check and fall back to
  ///     center — correct, but the inverse was also possible: a coord that was
  ///     off the primary but within the secondary was wrongly rejected).
  ///
  /// Now we iterate all displays and accept the coordinate if it falls inside
  /// any one of them.
  static Future<bool> _isOnScreen(double x, double y, Size size) async {
    try {
      final displays = await screenRetriever.getAllDisplays();
      const minVisible = 100.0;
      for (final display in displays) {
        final origin = display.visiblePosition ?? Offset.zero;
        final screenSize = display.size;
        final minX = origin.dx - 50.0;
        final minY = origin.dy - 50.0;
        final maxX = origin.dx + screenSize.width - minVisible;
        final maxY = origin.dy + screenSize.height - minVisible;
        if (x >= minX && y >= minY && x < maxX && y < maxY) {
          return true;
        }
      }
      return false;
    } catch (_) {
      // If we can't introspect the display, prefer center() over a stale
      // saved coordinate.
      return false;
    }
  }

  /// Keep the update prompt in the same chromeless 320×440 window the
  /// splash uses, so the two screens read as the same surface and the
  /// swap stays seamless. Previously this widened the window to 400×520,
  /// which left a visible band of empty space around the centred card
  /// because the splash background is transparent at the OS level.
  static Future<void> enterUpdatePrompt() async {
    if (!_isDesktop) return;
    try {
      await windowManager.setSize(const Size(320, 440));
    } catch (_) {
      // Resize failure is non-fatal — the user still sees the prompt
      // at whatever size the splash left the window at.
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
