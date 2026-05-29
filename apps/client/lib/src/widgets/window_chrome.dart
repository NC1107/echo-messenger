import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

import '../theme/echo_theme.dart';

/// True on any desktop platform — all three use [TitleBarStyle.hidden] for
/// the integrated chrome, so all three need custom window control buttons.
bool get _needsCustomButtons {
  if (kIsWeb) return false;
  return Platform.isLinux || Platform.isWindows || Platform.isMacOS;
}

/// Wraps a region of the app chrome so dragging it moves the native window.
///
/// Uses [GestureDetector.onPanDown] (fires on pointer-down, before gesture
/// resolution) rather than [onPanStart] for reliable GTK/X11 compatibility —
/// [gtk_window_begin_move_drag] must be called as close to the button-press
/// event as possible; [onPanStart] fires too late on many compositors.
///
/// Double-tapping the area toggles maximize/restore.
/// No-op on web and mobile.
class AppDragArea extends StatelessWidget {
  const AppDragArea({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return child;
    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
      return child;
    }
    return GestureDetector(
      behavior: HitTestBehavior.translucent,
      onPanDown: (_) => windowManager.startDragging(),
      onDoubleTap: () async {
        if (await windowManager.isMaximized()) {
          windowManager.unmaximize();
        } else {
          windowManager.maximize();
        }
      },
      child: child,
    );
  }
}

/// Compact minimize / maximize-restore / close buttons that replace the
/// native OS window controls on Linux and Windows desktop.
///
/// Returns [SizedBox.shrink] on web, mobile, and macOS (macOS gets native
/// traffic lights via [TitleBarStyle.hiddenInset]).
class AppWindowButtons extends StatefulWidget {
  const AppWindowButtons({super.key});

  @override
  State<AppWindowButtons> createState() => _AppWindowButtonsState();
}

class _AppWindowButtonsState extends State<AppWindowButtons>
    with WindowListener {
  bool _isMaximized = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
    _syncMaximized();
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  Future<void> _syncMaximized() async {
    final maximized = await windowManager.isMaximized();
    if (mounted) setState(() => _isMaximized = maximized);
  }

  @override
  void onWindowMaximize() => setState(() => _isMaximized = true);

  @override
  void onWindowUnmaximize() => setState(() => _isMaximized = false);

  @override
  Widget build(BuildContext context) {
    if (!_needsCustomButtons) return const SizedBox.shrink();

    return SizedBox(
      height: 36,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _WinButton(
            icon: Icons.remove,
            tooltip: 'Minimize',
            onTap: windowManager.minimize,
          ),
          _WinButton(
            icon: _isMaximized ? Icons.filter_none : Icons.crop_square,
            tooltip: _isMaximized ? 'Restore' : 'Maximize',
            onTap: _isMaximized
                ? windowManager.unmaximize
                : windowManager.maximize,
          ),
          _WinButton(
            icon: Icons.close,
            tooltip: 'Close',
            onTap: windowManager.close,
            isClose: true,
          ),
        ],
      ),
    );
  }
}

/// Full-width integrated title bar that replaces the OS window chrome.
///
/// Spans the entire app width above all content panels. The whole bar is a
/// drag region; [title] is centered and shows the active conversation name;
/// window controls are anchored to the right edge.
///
/// Optional [onBack] / [onForward] callbacks add browser-style conversation
/// history arrows to the left of the title on Linux/Windows. Pass
/// [canGoBack] / [canGoForward] to enable or grey-out the buttons.
///
/// No-op (zero height) on web and mobile.
class AppTitleBar extends StatelessWidget {
  const AppTitleBar({
    super.key,
    this.title,
    this.onBack,
    this.onForward,
    this.canGoBack = false,
    this.canGoForward = false,
  });

  /// Text centered in the bar — typically the active conversation or group name.
  final String? title;

  /// Called when the user taps the back arrow. Null hides the arrow pair.
  final VoidCallback? onBack;

  /// Called when the user taps the forward arrow.
  final VoidCallback? onForward;

  /// Whether the back arrow is interactive (enabled).
  final bool canGoBack;

  /// Whether the forward arrow is interactive (enabled).
  final bool canGoForward;

  @override
  Widget build(BuildContext context) {
    if (kIsWeb) return const SizedBox.shrink();
    if (!Platform.isLinux && !Platform.isWindows && !Platform.isMacOS) {
      return const SizedBox.shrink();
    }

    // Nav arrows only render on Linux/Windows; macOS traffic-light cluster
    // occupies the same left region (72 px inset), so we skip them there.
    final bool showNavArrows = onBack != null && !Platform.isMacOS;
    final double leftInset = Platform.isMacOS ? 72.0 : 0.0;

    // Clamp text scale to 1.2x — 1.5x overflows the 36px title bar into the window controls.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Container(
        height: 36,
        decoration: BoxDecoration(
          color: context.sidebarBg,
          border: Border(bottom: BorderSide(color: context.border, width: 1)),
        ),
        child: Stack(
          children: [
            // Full-width drag area underneath everything.
            const Positioned.fill(child: AppDragArea(child: SizedBox.expand())),
            // Back / forward navigation arrows on the left edge (Linux/Windows).
            if (showNavArrows)
              Positioned(
                left: 0,
                top: 0,
                bottom: 0,
                child: _NavArrows(
                  onBack: onBack!,
                  onForward: onForward,
                  canGoBack: canGoBack,
                  canGoForward: canGoForward,
                ),
              ),
            // IgnorePointer so clicks fall through to drag; inset avoids
            // nav arrows on Linux/Windows, traffic-light cluster on macOS.
            if (title != null && title!.isNotEmpty)
              Padding(
                padding: EdgeInsets.only(left: leftInset),
                child: Center(
                  child: IgnorePointer(
                    child: Text(
                      title!,
                      style: TextStyle(
                        color: context.textSecondary,
                        fontSize: 13,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ),
              ),
            // Window controls on top — rendered above drag area so they
            // receive pointer events before the GestureDetector beneath.
            const Positioned(
              right: 0,
              top: 0,
              bottom: 0,
              child: AppWindowButtons(),
            ),
          ],
        ),
      ),
    );
  }
}

/// Back and forward arrow buttons shown in the title bar on Linux/Windows.
class _NavArrows extends StatelessWidget {
  const _NavArrows({
    required this.onBack,
    this.onForward,
    required this.canGoBack,
    required this.canGoForward,
  });

  final VoidCallback onBack;
  final VoidCallback? onForward;
  final bool canGoBack;
  final bool canGoForward;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        _NavArrowButton(
          icon: Icons.arrow_back,
          tooltip: 'Back to previous conversation',
          onTap: canGoBack ? onBack : null,
        ),
        _NavArrowButton(
          icon: Icons.arrow_forward,
          tooltip: 'Forward',
          onTap: (canGoForward && onForward != null) ? onForward! : null,
        ),
      ],
    );
  }
}

/// Single icon button used by [_NavArrows]. Greyed when [onTap] is null.
class _NavArrowButton extends StatefulWidget {
  const _NavArrowButton({
    required this.icon,
    required this.tooltip,
    this.onTap,
  });

  final IconData icon;
  final String tooltip;

  /// Null → disabled (greyed, non-interactive).
  final VoidCallback? onTap;

  @override
  State<_NavArrowButton> createState() => _NavArrowButtonState();
}

class _NavArrowButtonState extends State<_NavArrowButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final bool enabled = widget.onTap != null;
    final Color iconColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: enabled ? 0.75 : 0.25);
    final Color hoverBg = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.12);

    return Semantics(
      label: widget.tooltip,
      button: true,
      enabled: enabled,
      child: Tooltip(
        message: widget.tooltip,
        child: MouseRegion(
          cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
          onEnter: enabled ? (_) => setState(() => _hovered = true) : null,
          onExit: enabled ? (_) => setState(() => _hovered = false) : null,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: widget.onTap,
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 100),
              width: 32,
              height: 36,
              color: (_hovered && enabled) ? hoverBg : Colors.transparent,
              alignment: Alignment.center,
              child: Icon(widget.icon, size: 14, color: iconColor),
            ),
          ),
        ),
      ),
    );
  }
}

class _WinButton extends StatefulWidget {
  final IconData icon;
  final String tooltip;
  final Future<void> Function() onTap;
  final bool isClose;

  const _WinButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
    this.isClose = false,
  });

  @override
  State<_WinButton> createState() => _WinButtonState();
}

class _WinButtonState extends State<_WinButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final iconColor = Theme.of(
      context,
    ).colorScheme.onSurface.withValues(alpha: 0.65);
    final hoverBg = widget.isClose
        ? EchoTheme.danger.withValues(alpha: 0.85)
        : Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.12);

    return Tooltip(
      message: widget.tooltip,
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 100),
            width: 40,
            height: 36,
            color: _hovered ? hoverBg : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 14, color: iconColor),
          ),
        ),
      ),
    );
  }
}
