import 'dart:io' show Platform;

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:window_manager/window_manager.dart';

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
      height: 60,
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
        ? Colors.red.withValues(alpha: 0.85)
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
            height: 60,
            color: _hovered ? hoverBg : Colors.transparent,
            alignment: Alignment.center,
            child: Icon(widget.icon, size: 14, color: iconColor),
          ),
        ),
      ),
    );
  }
}
