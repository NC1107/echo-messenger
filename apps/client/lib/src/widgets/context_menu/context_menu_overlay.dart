/// Desktop / web context-menu layout: a floating rounded card
/// anchored to the click point, clamped to the viewport, with a
/// 120ms fade+scale entry. Submenus replace the contents of the
/// same card via an in-place stack push, not nested popovers, so
/// dismiss and focus stay simple.
library;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../theme/echo_theme.dart';
import 'context_menu_item.dart';
import 'echo_context_menu.dart';

const double _menuWidth = 220;
const double _viewportPadding = 8;

/// Opens the desktop overlay variant. Returns when the menu is
/// dismissed (tap outside, Esc, or action selected).
Future<void> showContextMenuOverlay({
  required BuildContext context,
  required Offset anchor,
  required ContextMenuModel model,
}) {
  return Navigator.of(
    context,
    rootNavigator: true,
  ).push(_ContextMenuRoute(anchor: anchor, model: model));
}

/// Custom route so we can paint the menu inside the modal barrier's
/// own subtree (handles dismiss-on-tap-outside for free) while still
/// owning the slide/scale animation curves.
class _ContextMenuRoute extends PopupRoute<void> {
  _ContextMenuRoute({required this.anchor, required this.model});

  final Offset anchor;
  final ContextMenuModel model;

  @override
  Color? get barrierColor => null; // Transparent — tap outside dismisses.

  @override
  bool get barrierDismissible => true;

  @override
  String? get barrierLabel => 'Dismiss context menu';

  @override
  Duration get transitionDuration => const Duration(milliseconds: 120);

  @override
  Widget buildPage(
    BuildContext context,
    Animation<double> animation,
    Animation<double> secondaryAnimation,
  ) {
    return _ContextMenuOverlay(
      anchor: anchor,
      model: model,
      animation: animation,
    );
  }
}

class _ContextMenuOverlay extends StatefulWidget {
  const _ContextMenuOverlay({
    required this.anchor,
    required this.model,
    required this.animation,
  });

  final Offset anchor;
  final ContextMenuModel model;
  final Animation<double> animation;

  @override
  State<_ContextMenuOverlay> createState() => _ContextMenuOverlayState();
}

class _ContextMenuOverlayState extends State<_ContextMenuOverlay> {
  /// Stack of menu frames. Root is `model`; each "Submenu" tap pushes
  /// a new ContextMenuModel synthesised from the action's `submenu`.
  late final List<ContextMenuModel> _stack = [widget.model];

  void _pushSubmenu(ContextMenuAction action) {
    if (action.submenu == null) return;
    setState(() {
      _stack.add(
        ContextMenuModel(sections: action.submenu!, title: action.label),
      );
    });
  }

  void _popSubmenu() {
    if (_stack.length <= 1) {
      Navigator.of(context).pop();
      return;
    }
    setState(() => _stack.removeLast());
  }

  void _handleActivate(ContextMenuAction action) {
    if (action.submenu != null) {
      _pushSubmenu(action);
      return;
    }
    Navigator.of(context).pop();
    // Run the action AFTER the route is gone so it sees the parent
    // context unobstructed (showSnackBar, navigation, dialogs all
    // need the post-dismiss tree).
    WidgetsBinding.instance.addPostFrameCallback((_) => action.onTap?.call());
  }

  @override
  Widget build(BuildContext context) {
    final mq = MediaQuery.of(context);
    final size = mq.size;
    final current = _stack.last;
    final isSubmenu = _stack.length > 1;

    // Anchor + clamp. We always try to place the menu's top-left at
    // the click; if that overflows the viewport (right or bottom),
    // clamp inside the safe area. No flipping — keeps geometry
    // predictable when menus contain submenus of differing heights.
    final menuHeight = _estimateMenuHeight(current);
    var left = widget.anchor.dx;
    var top = widget.anchor.dy;
    if (left + _menuWidth + _viewportPadding > size.width) {
      left = size.width - _menuWidth - _viewportPadding;
    }
    if (top + menuHeight + _viewportPadding > size.height) {
      top = size.height - menuHeight - _viewportPadding;
    }
    if (left < _viewportPadding) left = _viewportPadding;
    if (top < _viewportPadding) top = _viewportPadding;

    // Origin for the scale-from-anchor transform is the click point
    // relative to the menu's own rect — so the menu visually expands
    // from where the user clicked.
    final originX = ((widget.anchor.dx - left) / _menuWidth).clamp(0.0, 1.0);
    final originY = ((widget.anchor.dy - top) / menuHeight).clamp(0.0, 1.0);

    return Stack(
      children: [
        Positioned(
          left: left,
          top: top,
          child: _MenuCard(
            animation: widget.animation,
            origin: Alignment(originX * 2 - 1, originY * 2 - 1),
            child: _MenuContents(
              model: current,
              isSubmenu: isSubmenu,
              onActivate: _handleActivate,
              onBack: _popSubmenu,
            ),
          ),
        ),
      ],
    );
  }

  double _estimateMenuHeight(ContextMenuModel model) {
    // Rough lower bound used only for viewport clamping. Real
    // intrinsic size handles itself once painted.
    const headerRow = 56.0;
    const itemRow = 36.0;
    const divider = 13.0;
    const padding = 12.0;
    var h = padding * 2;
    if (model.header != null) h += headerRow;
    if (model.title != null) h += 32;
    for (var i = 0; i < model.sections.length; i++) {
      if (i > 0) h += divider;
      h += model.sections[i].actions.length * itemRow;
    }
    return h;
  }
}

class _MenuCard extends StatelessWidget {
  const _MenuCard({
    required this.animation,
    required this.origin,
    required this.child,
  });

  final Animation<double> animation;
  final Alignment origin;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final scale = Tween<double>(
      begin: 0.95,
      end: 1.0,
    ).animate(CurvedAnimation(parent: animation, curve: Curves.easeOutCubic));
    return FadeTransition(
      opacity: animation,
      child: ScaleTransition(
        scale: scale,
        alignment: origin,
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: _menuWidth,
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(10),
              border: Border.all(color: context.border),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.28),
                  blurRadius: 24,
                  offset: const Offset(0, 8),
                ),
              ],
            ),
            child: child,
          ),
        ),
      ),
    );
  }
}

class _MenuContents extends StatelessWidget {
  const _MenuContents({
    required this.model,
    required this.isSubmenu,
    required this.onActivate,
    required this.onBack,
  });

  final ContextMenuModel model;
  final bool isSubmenu;
  final ValueChanged<ContextMenuAction> onActivate;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    final children = <Widget>[];

    if (isSubmenu) {
      children.add(_SubmenuHeader(title: model.title ?? '', onBack: onBack));
    } else if (model.header != null) {
      children.add(_renderHeader(context, model.header!));
    }

    for (var i = 0; i < model.sections.length; i++) {
      if (i > 0 || children.isNotEmpty) {
        children.add(const ContextMenuDivider());
      }
      for (final action in model.sections[i].actions) {
        children.add(ContextMenuItem(action: action, onActivate: onActivate));
      }
    }

    // Dismiss on Esc — keyboard navigation proper is deferred to a
    // follow-up, but Esc-to-close is one shortcut and ubiquitous
    // enough that omitting it would surprise people.
    return Shortcuts(
      shortcuts: const {
        SingleActivator(LogicalKeyboardKey.escape): _DismissIntent(),
      },
      child: Actions(
        actions: {
          _DismissIntent: CallbackAction<_DismissIntent>(
            onInvoke: (_) {
              Navigator.of(context).pop();
              return null;
            },
          ),
        },
        child: Focus(
          autofocus: true,
          child: Padding(
            padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 4),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: children,
            ),
          ),
        ),
      ),
    );
  }

  Widget _renderHeader(BuildContext context, ContextMenuHeader header) {
    return switch (header) {
      InlineReactionsHeader h => _InlineReactionsRow(header: h),
    };
  }
}

class _SubmenuHeader extends StatelessWidget {
  const _SubmenuHeader({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onBack,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.chevron_left, size: 18, color: context.textPrimary),
            const SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 13.5,
                fontWeight: FontWeight.w600,
                color: context.textPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _InlineReactionsRow extends StatelessWidget {
  const _InlineReactionsRow({required this.header});

  final InlineReactionsHeader header;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
      child: Row(
        children: [
          for (final emoji in header.emojis.take(4))
            Expanded(
              child: _EmojiButton(
                emoji: emoji,
                onTap: () {
                  Navigator.of(context).pop();
                  WidgetsBinding.instance.addPostFrameCallback(
                    (_) => header.onPick(emoji),
                  );
                },
              ),
            ),
          _EmojiButton(
            icon: Icons.add_reaction_outlined,
            onTap: header.onOpenFullPicker,
          ),
        ],
      ),
    );
  }
}

class _EmojiButton extends StatefulWidget {
  const _EmojiButton({this.emoji, this.icon, required this.onTap})
    : assert(emoji != null || icon != null);

  final String? emoji;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  State<_EmojiButton> createState() => _EmojiButtonState();
}

class _EmojiButtonState extends State<_EmojiButton> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.click,
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: GestureDetector(
        onTap: widget.onTap,
        child: Container(
          height: 36,
          margin: const EdgeInsets.symmetric(horizontal: 2),
          decoration: BoxDecoration(
            color: _hover ? context.surfaceHover : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          alignment: Alignment.center,
          child: widget.emoji != null
              ? Text(
                  widget.emoji!,
                  style: const TextStyle(
                    fontSize: 20,
                    fontFamily: 'NotoEmoji',
                    height: 1.0,
                  ),
                )
              : Icon(widget.icon, size: 18, color: context.textPrimary),
        ),
      ),
    );
  }
}

class _DismissIntent extends Intent {
  const _DismissIntent();
}
