part of '../../conversation_panel.dart';

/// Compose-FAB chrome for the mobile narrow layout: a square accent FAB
/// anchored bottom-right that tap-fires "New chat" and long-press opens
/// a popup with "New chat", "New group", and "Discover groups".
mixin _ConversationPanelComposeFabMixin on ConsumerState<ConversationPanel> {
  /// Square accent FAB anchored bottom-right of the conversation panel.
  ///
  /// Mobile-only (width < 600): the desktop header "+" menu is hidden on
  /// narrow layouts, so this FAB becomes the sole entry-point for compose
  /// actions. A single tap fires "New chat" (primary action). A long-press
  /// opens a popup with "New chat", "New group", and "Discover groups" so
  /// all three are reachable without cluttering the header.
  Widget _buildComposeFab(BuildContext context) {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    if (!isMobile) return const SizedBox.shrink();

    // If no secondary actions are provided we fall back to a plain tap-only FAB.
    final hasMenu = widget.onNewGroup != null || widget.onDiscover != null;

    return Positioned(
      right: EchoSpacing.lg,
      bottom: EchoSpacing.lg,
      child: hasMenu
          ? _ComposeFabMenu(
              onNewChat: widget.onNewChat,
              onNewGroup: widget.onNewGroup,
              onDiscover: widget.onDiscover,
            )
          : Semantics(
              label: 'New chat',
              button: true,
              child: Material(
                color: context.accent,
                borderRadius: BorderRadius.circular(EchoRadii.xl),
                elevation: 4,
                child: InkWell(
                  onTap: widget.onNewChat,
                  borderRadius: BorderRadius.circular(EchoRadii.xl),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Icon(
                      Icons.edit_outlined,
                      color: context.onAccent,
                      size: 22,
                    ),
                  ),
                ),
              ),
            ),
    );
  }
}

// ---------------------------------------------------------------------------
// Mobile compose FAB with long-press popup menu
// ---------------------------------------------------------------------------

/// Pencil FAB used on narrow (mobile) layouts. A single tap triggers the
/// primary "New chat" action. A long-press opens a small popup menu anchored
/// to the button itself with "New chat", "New group", and "Discover groups"
/// so every compose action is reachable one-handed without a header button.
class _ComposeFabMenu extends StatelessWidget {
  const _ComposeFabMenu({this.onNewChat, this.onNewGroup, this.onDiscover});

  final VoidCallback? onNewChat;
  final VoidCallback? onNewGroup;
  final VoidCallback? onDiscover;

  void _openMenu(BuildContext context) {
    final box = context.findRenderObject() as RenderBox?;
    if (box == null) return;
    final offset = box.localToGlobal(Offset.zero);
    final size = box.size;
    final overlay = Overlay.of(context).context.findRenderObject() as RenderBox;

    showMenu<String>(
      context: context,
      color: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: context.border),
      ),
      // Anchor just above the FAB.
      position: RelativeRect.fromRect(
        Rect.fromLTWH(offset.dx, offset.dy, size.width, size.height),
        Offset.zero & overlay.size,
      ),
      items: [
        PopupMenuItem<String>(
          value: 'chat',
          child: Row(
            children: [
              Icon(
                Icons.person_add_outlined,
                size: 18,
                color: context.textSecondary,
              ),
              const SizedBox(width: 10),
              const Text('New chat'),
            ],
          ),
        ),
        if (onNewGroup != null)
          PopupMenuItem<String>(
            value: 'group',
            child: Row(
              children: [
                Icon(
                  Icons.group_add_outlined,
                  size: 18,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 10),
                const Text('New group'),
              ],
            ),
          ),
        if (onDiscover != null)
          PopupMenuItem<String>(
            value: 'discover',
            child: Row(
              children: [
                Icon(
                  Icons.explore_outlined,
                  size: 18,
                  color: context.textSecondary,
                ),
                const SizedBox(width: 10),
                const Text('Discover groups'),
              ],
            ),
          ),
      ],
    ).then((value) {
      switch (value) {
        case 'chat':
          onNewChat?.call();
        case 'group':
          onNewGroup?.call();
        case 'discover':
          onDiscover?.call();
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'New chat. Long-press for more options.',
      button: true,
      child: Material(
        color: context.accent,
        borderRadius: BorderRadius.circular(EchoRadii.xl),
        elevation: 4,
        child: InkWell(
          onTap: onNewChat,
          onLongPress: () => _openMenu(context),
          borderRadius: BorderRadius.circular(EchoRadii.xl),
          child: SizedBox(
            width: 56,
            height: 56,
            child: Icon(Icons.edit_outlined, color: context.onAccent, size: 22),
          ),
        ),
      ),
    );
  }
}
