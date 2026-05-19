/// Mobile context-menu layout: a draggable bottom sheet with the
/// same sections as the desktop overlay. The reaction-emoji strip
/// stays at the top to align with the existing scroll-reaction
/// picker pattern. Submenus push by replacing the sheet's contents
/// (no nested sheets) so dismiss is one swipe regardless of depth.
library;

import 'package:flutter/material.dart';

import '../../theme/echo_theme.dart';
import 'context_menu_item.dart';
import 'echo_context_menu.dart';

Future<void> showContextMenuSheet({
  required BuildContext context,
  required ContextMenuModel model,
}) {
  return showModalBottomSheet<void>(
    context: context,
    backgroundColor: Colors.transparent,
    isScrollControlled: true,
    builder: (sheetContext) => _ContextMenuSheet(model: model),
  );
}

class _ContextMenuSheet extends StatefulWidget {
  const _ContextMenuSheet({required this.model});
  final ContextMenuModel model;

  @override
  State<_ContextMenuSheet> createState() => _ContextMenuSheetState();
}

class _ContextMenuSheetState extends State<_ContextMenuSheet> {
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
    WidgetsBinding.instance.addPostFrameCallback((_) => action.onTap?.call());
  }

  @override
  Widget build(BuildContext context) {
    final current = _stack.last;
    final isSubmenu = _stack.length > 1;
    final viewInsets = MediaQuery.viewInsetsOf(context);

    final rows = <Widget>[];
    if (isSubmenu) {
      rows.add(_SheetHeader(title: current.title ?? '', onBack: _popSubmenu));
    } else if (current.header != null) {
      rows.add(_renderHeader(context, current.header!));
    }
    for (var i = 0; i < current.sections.length; i++) {
      if (i > 0 || rows.isNotEmpty) {
        rows.add(const ContextMenuDivider());
      }
      for (final action in current.sections[i].actions) {
        rows.add(ContextMenuItem(action: action, onActivate: _handleActivate));
      }
    }

    return AnimatedPadding(
      duration: const Duration(milliseconds: 120),
      curve: Curves.easeOutCubic,
      padding: EdgeInsets.only(bottom: viewInsets.bottom),
      child: SafeArea(
        top: false,
        child: Container(
          decoration: BoxDecoration(
            color: context.surface,
            border: Border(top: BorderSide(color: context.border)),
            borderRadius: const BorderRadius.vertical(top: Radius.circular(16)),
          ),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [_DragGrabber(), ...rows],
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

class _DragGrabber extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Container(
        width: 36,
        height: 4,
        margin: const EdgeInsets.only(bottom: 8),
        decoration: BoxDecoration(
          color: context.border,
          borderRadius: BorderRadius.circular(2),
        ),
      ),
    );
  }
}

class _SheetHeader extends StatelessWidget {
  const _SheetHeader({required this.title, required this.onBack});

  final String title;
  final VoidCallback onBack;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onBack,
      behavior: HitTestBehavior.opaque,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 8),
        child: Row(
          children: [
            Icon(Icons.chevron_left, size: 20, color: context.textPrimary),
            const SizedBox(width: 4),
            Text(
              title,
              style: TextStyle(
                fontSize: 14,
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
      padding: const EdgeInsets.fromLTRB(4, 4, 4, 4),
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

class _EmojiButton extends StatelessWidget {
  const _EmojiButton({this.emoji, this.icon, required this.onTap})
    : assert(emoji != null || icon != null);

  final String? emoji;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTap: onTap,
      child: Container(
        height: 44,
        margin: const EdgeInsets.symmetric(horizontal: 2),
        decoration: BoxDecoration(
          color: context.surfaceHover,
          borderRadius: BorderRadius.circular(8),
        ),
        alignment: Alignment.center,
        child: emoji != null
            ? Text(
                emoji!,
                style: const TextStyle(
                  fontSize: 24,
                  fontFamily: 'NotoEmoji',
                  height: 1.0,
                ),
              )
            : Icon(icon, size: 22, color: context.textPrimary),
      ),
    );
  }
}
