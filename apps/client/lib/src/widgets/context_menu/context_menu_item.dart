/// Single row inside the Echo context menu: label left, icon right,
/// optional shortcut hint, optional submenu chevron. 36px tap target.
/// Hover-state painted directly so we don't pull in Material's
/// InkWell ripple — Discord-style menus snap, they don't ripple.
library;

import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import 'echo_context_menu.dart';

class ContextMenuItem extends StatefulWidget {
  const ContextMenuItem({
    super.key,
    required this.action,
    required this.onActivate,
    this.dense = false,
  });

  final ContextMenuAction action;

  /// Called for both terminal taps (with `submenu == null`) and
  /// submenu-opening taps. The overlay decides what to do based on
  /// `action.submenu`.
  final ValueChanged<ContextMenuAction> onActivate;

  /// Tightens vertical padding for inline header rows (e.g. the
  /// emoji strip's "Add Reaction" entry-point row).
  final bool dense;

  @override
  State<ContextMenuItem> createState() => _ContextMenuItemState();
}

class _ContextMenuItemState extends State<ContextMenuItem> {
  bool _hover = false;
  bool _pressed = false;

  @override
  Widget build(BuildContext context) {
    final action = widget.action;
    final danger = action.isDanger;
    final base = danger ? EchoTheme.danger : context.textPrimary;
    // Hover bg uses the surface-hover token directly so the menu sits
    // consistently with sidebar/list hover states elsewhere in the app.
    final hoverBg = danger
        ? EchoTheme.danger.withValues(alpha: 0.12)
        : context.surfaceHover;

    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() {
        _hover = false;
        _pressed = false;
      }),
      child: GestureDetector(
        onTapDown: (_) => setState(() => _pressed = true),
        onTapCancel: () => setState(() => _pressed = false),
        onTapUp: (_) {
          setState(() => _pressed = false);
          widget.onActivate(action);
        },
        behavior: HitTestBehavior.opaque,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 80),
          padding: EdgeInsets.symmetric(
            horizontal: 12,
            vertical: widget.dense ? 6 : 9,
          ),
          decoration: BoxDecoration(
            color: _resolveBackground(hoverBg),
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            children: [
              Expanded(
                child: Text(
                  action.label,
                  style: TextStyle(
                    fontSize: 13.5,
                    color: base,
                    fontWeight: FontWeight.w500,
                    height: 1.2,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (action.shortcut != null) ...[
                Text(
                  action.shortcut!,
                  style: EchoTheme.mono(
                    fontSize: 11,
                    color: context.textMuted,
                    letterSpacing: 0.3,
                  ),
                ),
                const SizedBox(width: 10),
              ],
              if (action.submenu != null)
                Icon(Icons.chevron_right, size: 18, color: base)
              else
                Icon(action.icon, size: 16, color: base),
            ],
          ),
        ),
      ),
    );
  }

  Color _resolveBackground(Color hoverBg) {
    if (_pressed) return hoverBg.withValues(alpha: 0.9);
    if (_hover) return hoverBg;
    return Colors.transparent;
  }
}

/// 1px horizontal divider painted between sections. Inset to match
/// the row padding so it visually tracks the menu's gutter.
class ContextMenuDivider extends StatelessWidget {
  const ContextMenuDivider({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 1,
      margin: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
      color: context.border,
    );
  }
}
