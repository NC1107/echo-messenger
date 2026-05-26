part of '../../conversation_panel.dart';

/// Header chrome: top logo bar with action icons, the "+" new-action menu,
/// the All/DMs/Groups filter chips, and the bottom user-status bar with
/// the presence picker. Pure UI builders — all state mutation lives in
/// the actions mixin.
mixin _ConversationPanelHeaderMixin
    on ConsumerState<ConversationPanel>, _ConversationPanelActionsMixin {
  Widget _buildLogoHeader(BuildContext context, int pendingCount) {
    // Use the larger title style on mobile (full-screen), smaller on desktop
    // sidebar where horizontal real-estate is tight.
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    final titleSize = isMobile ? 28.0 : 17.0;
    final titleWeight = isMobile ? FontWeight.w700 : FontWeight.w700;
    final headerHeight = isMobile ? 64.0 : 56.0;

    return Container(
      height: headerHeight,
      padding: const EdgeInsets.symmetric(horizontal: EchoSpacing.lg),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          Expanded(
            child: Row(
              children: [
                // Anchor status dot to a fixed-size icon (wrapping "Chats" text placed dot at "s" lower-right).
                const ConnectionStatusBadge(child: EchoLogoIcon(size: 22)),
                const SizedBox(width: 10),
                Text(
                  isMobile ? 'Chats' : 'Echo',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: titleSize,
                    fontWeight: titleWeight,
                    letterSpacing: isMobile ? -0.5 : 0,
                  ),
                ),
              ],
            ),
          ),
          // Right: non-draggable action buttons.
          // All icons at 18px with uniform 44x44 tap targets per WCAG 2.5.5.
          if (widget.onScanQr != null)
            Semantics(
              label: 'scan QR to add contact',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.qr_code_scanner, size: 18),
                color: context.textSecondary,
                tooltip: 'Scan QR to add contact',
                onPressed: widget.onScanQr,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ),
          const SizedBox(width: 2),
          _buildNewActionMenu(context, pendingCount),
          if (!isMobile && widget.onShowKeyboardShortcuts != null) ...[
            const SizedBox(width: 2),
            Semantics(
              label: 'show keyboard shortcuts',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.help_outline, size: 18),
                color: context.textSecondary,
                tooltip: 'Keyboard shortcuts (Ctrl+/)',
                onPressed: widget.onShowKeyboardShortcuts,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ),
          ],
          // Single search entrypoint on mobile + desktop (feedback_desktop_search memory rule).
          if (widget.onGlobalSearch != null) ...[
            const SizedBox(width: 2),
            Semantics(
              label: 'global search',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.search_outlined, size: 18),
                color: context.textSecondary,
                tooltip: isMobile
                    ? 'Search messages'
                    : 'Search messages (Ctrl+Shift+F)',
                onPressed: widget.onGlobalSearch,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ),
          ],
          if (widget.onCollapseSidebar != null) ...[
            const SizedBox(width: 2),
            Semantics(
              label: 'collapse sidebar',
              button: true,
              child: IconButton(
                icon: const Icon(Icons.chevron_left, size: 18),
                color: context.textSecondary,
                tooltip: 'Collapse sidebar',
                onPressed: widget.onCollapseSidebar,
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNewActionMenu(BuildContext context, int pendingCount) {
    // On mobile (narrow) the pencil FAB already exposes these actions;
    // hide the "+" header button there to avoid duplication.
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    if (isMobile) return const SizedBox.shrink();

    return Stack(
      clipBehavior: Clip.none,
      children: [
        Semantics(
          label: 'new chat menu',
          button: true,
          child: PopupMenuButton<String>(
            icon: Icon(Icons.add, size: 18, color: context.textSecondary),
            tooltip: 'New',
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            // Menu minimum width so text never clips on narrow viewports
            menuPadding: const EdgeInsets.symmetric(vertical: 4),
            popUpAnimationStyle: AnimationStyle.noAnimation,
            offset: const Offset(0, 36),
            onSelected: (value) {
              switch (value) {
                case 'chat':
                  widget.onNewChat?.call();
                case 'group':
                  widget.onNewGroup?.call();
                case 'discover':
                  widget.onDiscover?.call();
                case 'saved':
                  widget.onSavedMessages?.call();
              }
            },
            itemBuilder: (context) => const [
              PopupMenuItem(
                value: 'chat',
                child: SizedBox(
                  width: 200,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.person_add_outlined, size: 18),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'New Chat',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'group',
                child: SizedBox(
                  width: 200,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.group_add_outlined, size: 18),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'New Group',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'discover',
                child: SizedBox(
                  width: 200,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.explore_outlined, size: 18),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Discover Groups',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              PopupMenuItem(
                value: 'saved',
                child: SizedBox(
                  width: 200,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.bookmark_border_outlined, size: 18),
                      SizedBox(width: 10),
                      Flexible(
                        child: Text(
                          'Saved Messages',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
        if (pendingCount > 0 &&
            (kIsWeb ||
                defaultTargetPlatform == TargetPlatform.android ||
                defaultTargetPlatform == TargetPlatform.iOS))
          Positioned(
            // Re-center the badge on the larger 44×44 button.
            top: 6,
            right: 6,
            child: IgnorePointer(
              child: Container(
                width: 14,
                height: 14,
                decoration: const BoxDecoration(
                  color: EchoTheme.danger,
                  shape: BoxShape.circle,
                ),
                child: Center(
                  child: Text(
                    pendingCount > 9 ? '9+' : '$pendingCount',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 10,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildFilterChips() {
    final activeFilter = ref.watch(conversationFilterTypeProvider);
    return Padding(
      padding: const EdgeInsets.symmetric(
        horizontal: EchoSpacing.lg,
        vertical: EchoSpacing.xs,
      ),
      child: Row(
        children: [
          _buildChip('All', ConversationFilterType.all, activeFilter),
          const SizedBox(width: 6),
          _buildChip(
            'DMs',
            ConversationFilterType.dms,
            activeFilter,
            icon: Icons.person_outline,
          ),
          const SizedBox(width: 6),
          _buildChip(
            'Groups',
            ConversationFilterType.groups,
            activeFilter,
            icon: Icons.groups_outlined,
          ),
        ],
      ),
    );
  }

  Widget _buildChip(
    String label,
    ConversationFilterType filter,
    ConversationFilterType activeFilter, {
    IconData? icon,
  }) {
    final isSelected = activeFilter == filter;
    // White, not onPrimary — onPrimary resolves dark on graphite/ember/neon themes.
    final chipColor = isSelected ? Colors.white : context.textSecondary;
    final chipWeight = isSelected ? FontWeight.w600 : FontWeight.w500;
    return GestureDetector(
      onTap: () => _onFilterChanged(filter),
      // Opaque so taps in the transparent vertical padding still register.
      behavior: HitTestBehavior.opaque,
      child: Container(
        // Outer wrapper provides the 44x44 tap target without enlarging the
        // visual pill -- the inner Container keeps the compact 28px chip.
        constraints: const BoxConstraints(minHeight: 44, minWidth: 44),
        alignment: Alignment.center,
        child: AnimatedContainer(
          duration: MotionDurations.quick,
          curve: MotionCurves.emphasis,
          height: 28,
          padding: const EdgeInsets.symmetric(horizontal: 12),
          decoration: BoxDecoration(
            color: isSelected ? context.accent : context.surface,
            borderRadius: BorderRadius.circular(14),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (icon != null) ...[
                Icon(icon, size: 14, color: chipColor),
                const SizedBox(width: 4),
              ],
              Text(
                label,
                style: TextStyle(
                  color: chipColor,
                  fontSize: 12,
                  fontWeight: chipWeight,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildUserStatusBar(
    BuildContext context, {
    required String myUsername,
    required String serverUrl,
    required String? avatarUrl,
    required bool wsConnected,
    required bool wsReplaced,
    required String presenceStatus,
  }) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: EchoSpacing.lg),
      decoration: BoxDecoration(
        color: context.mainBg,
        border: Border(top: BorderSide(color: context.border, width: 1)),
      ),
      child: Row(
        children: [
          _buildUserAvatar(
            context,
            myUsername,
            serverUrl,
            avatarUrl,
            wsConnected,
            presenceStatus,
          ),
          const SizedBox(width: 10),
          _buildUserNameAndStatus(context, myUsername, wsConnected, wsReplaced),
          Semantics(
            label: 'open settings',
            button: true,
            child: IconButton(
              icon: const Icon(Icons.settings_outlined, size: 18),
              color: context.textSecondary,
              tooltip: 'Settings',
              onPressed: widget.onSettings,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserAvatar(
    BuildContext context,
    String myUsername,
    String serverUrl,
    String? avatarUrl,
    bool wsConnected,
    String presenceStatus,
  ) {
    final dotColor = wsConnected
        ? presenceColor(presenceStatus)
        : EchoTheme.warning;

    return Semantics(
      label: 'Status: $presenceStatus. Tap to change.',
      button: true,
      child: PopupMenuButton<String>(
        key: const Key('status-picker'),
        tooltip: 'Change status',
        offset: const Offset(0, -160),
        onSelected: (status) {
          ref.read(authProvider.notifier).setPresenceStatus(status);
        },
        itemBuilder: (_) => const [
          PopupMenuItem(
            value: 'online',
            child: _StatusMenuItem(label: 'Online', color: EchoTheme.online),
          ),
          PopupMenuItem(
            value: 'away',
            child: _StatusMenuItem(label: 'Away', color: EchoTheme.warning),
          ),
          PopupMenuItem(
            value: 'dnd',
            child: _StatusMenuItem(
              label: 'Do Not Disturb',
              color: EchoTheme.danger,
            ),
          ),
          PopupMenuItem(
            value: 'invisible',
            child: _StatusMenuItem(
              label: 'Invisible',
              color: Color(0xFF6B6B6F),
            ),
          ),
        ],
        child: Stack(
          children: [
            buildAvatar(
              name: myUsername,
              radius: 16,
              bgColor: context.accent,
              imageUrl: resolveAvatarUrl(avatarUrl, serverUrl),
            ),
            Positioned(
              bottom: 0,
              right: 0,
              child: Container(
                width: 10,
                height: 10,
                decoration: BoxDecoration(
                  color: dotColor,
                  shape: BoxShape.circle,
                  border: Border.all(color: context.mainBg, width: 2),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  static String _connectionStatusLabel(bool wsReplaced, bool wsConnected) {
    if (wsReplaced) return 'Session replaced';
    if (wsConnected) return 'Online';
    return 'Reconnecting...';
  }

  Widget _buildUserNameAndStatus(
    BuildContext context,
    String myUsername,
    bool wsConnected,
    bool wsReplaced,
  ) {
    return Expanded(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            myUsername,
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
            ),
            overflow: TextOverflow.ellipsis,
          ),
          Text(
            _connectionStatusLabel(wsReplaced, wsConnected),
            style: TextStyle(
              color: wsConnected ? EchoTheme.online : EchoTheme.warning,
              fontSize: 11,
            ),
          ),
        ],
      ),
    );
  }
}

/// Row widget used inside the status picker popup menu.
///
/// Each entry shows a coloured presence dot and a label, matching the visual
/// language used in conversation list items and user profile screens.
class _StatusMenuItem extends StatelessWidget {
  const _StatusMenuItem({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 10),
        Text(label),
      ],
    );
  }
}
