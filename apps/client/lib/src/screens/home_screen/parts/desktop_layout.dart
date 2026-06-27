part of '../../home_screen.dart';

/// Desktop (≥900px) layout for [HomeScreen]: the title bar + sidebar +
/// chat + optional members-panel three-column composition, the
/// collapsible sidebar (expanded conversation panel, collapsed rail,
/// settings panel), the draggable resize handle, and the lounge/chat/
/// settings switching logic that decides what to render in the right
/// panel. Also hosts the conversation panel factory (`_buildConversationPanel`)
/// because the same builder feeds both the desktop sidebar and the
/// narrow Chats tab.
mixin _HomeScreenDesktopLayoutMixin
    on
        ConsumerState<HomeScreen>,
        _HomeScreenActionsMixin,
        _HomeScreenListenersMixin {
  // `_self` is provided by `_HomeScreenActionsMixin`.

  ConversationPanel _buildConversationPanel({VoidCallback? onCollapseSidebar}) {
    return ConversationPanel(
      selectedConversationId: _self._selectedConversation?.id,
      onConversationTap: _selectConversation,
      onNewChat: _openNewMessage,
      onNewGroup: _openCreateGroup,
      onDiscover: _openDiscoverGroups,
      onSavedMessages: _openSavedMessages,
      onThreads: () => context.push(routeThreads),
      onCollapseSidebar: onCollapseSidebar,
      onSettings: _openSettings,
      onShowContacts: _openContacts,
      onGlobalSearch: _showGlobalSearch,
      onShowKeyboardShortcuts: _showKeyboardShortcuts,
      onMessageContact: _messageContact,
      externalSearchFocusNode: _self._searchFocusNode,
      onNavigateToLounge: () => setState(() {
        _self._showingLounge = true;
        _self._userDismissedLounge = false;
      }),
    );
  }

  /// Builds a collapsed sidebar showing only avatars.
  Widget _buildCollapsedSidebar() {
    final conversationsState = ref.watch(conversationsProvider);
    final myUserId = ref.watch(authProvider).userId ?? '';
    final serverUrl = ref.read(serverUrlProvider);
    final conversations = conversationsState.conversations;

    return Container(
      width: _HomeScreenState._sidebarCollapsedWidth,
      color: context.sidebarBg,
      child: Column(
        children: [
          // Header with expand button
          Container(
            height: 56,
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.border, width: 1),
              ),
            ),
            child: Center(
              child: IconButton(
                icon: const Icon(Icons.chevron_right, size: 20),
                color: context.textSecondary,
                tooltip: 'Expand sidebar',
                onPressed: () =>
                    setState(() => _self._sidebarCollapsed = false),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
              ),
            ),
          ),
          // Conversation avatars
          Expanded(
            child: ListView.builder(
              padding: const EdgeInsets.symmetric(vertical: 8),
              itemCount: conversations.length,
              itemBuilder: (context, index) {
                final conv = conversations[index];
                final displayName = conv.displayName(myUserId);
                final isSelected = conv.id == _self._selectedConversation?.id;

                // KeyedSubtree binds element identity to conv.id so list reorders don't misbind (TD-10).
                return KeyedSubtree(
                  key: ValueKey('conv-rail-${conv.id}'),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Tooltip(
                      message: displayName,
                      preferBelow: false,
                      child: Semantics(
                        label: 'conversation: $displayName',
                        button: true,
                        child: GestureDetector(
                          onTap: () => _selectConversation(conv),
                          child: SizedBox(
                            width: 44,
                            height: 44,
                            // Stack lets the selection pill sit beside the centred avatar (matches conversation_item).
                            child: Stack(
                              children: [
                                Center(
                                  child: _buildRailAvatar(
                                    conv,
                                    displayName,
                                    myUserId,
                                    serverUrl,
                                  ),
                                ),
                                if (isSelected)
                                  Positioned(
                                    left: 0,
                                    top: 8,
                                    bottom: 8,
                                    child: IgnorePointer(
                                      child: Container(
                                        width: 4,
                                        decoration: BoxDecoration(
                                          color: context.activeRowAccent,
                                          borderRadius: BorderRadius.circular(
                                            2,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
          // Active-voice strip — vertical mic / deafen / hangup column
          // shown above the settings icon when a call is in progress.
          // Without this the dock vanishes the moment the user collapses
          // the sidebar (image #41).
          _buildCollapsedVoiceDock(),
          // Settings icon at bottom
          Container(
            height: 60,
            decoration: BoxDecoration(
              color: context.mainBg,
              border: Border(top: BorderSide(color: context.border, width: 1)),
            ),
            child: Center(
              child: Builder(
                builder: (context) {
                  final updateState = ref.watch(updateProvider);
                  final showUpdateDot =
                      updateState.updateAvailable && !updateState.dismissed;
                  return Stack(
                    clipBehavior: Clip.none,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.settings_outlined, size: 18),
                        color: context.textSecondary,
                        tooltip: 'Settings',
                        onPressed: _openSettings,
                        padding: EdgeInsets.zero,
                        constraints: const BoxConstraints(
                          minWidth: 44,
                          minHeight: 44,
                        ),
                      ),
                      if (showUpdateDot)
                        Positioned(
                          top: 10,
                          right: 10,
                          // `sidebarBg` ring contrasts with the footer chip's `mainBg` so the dot stays visible.
                          child: _DotBadge(
                            ringColor: context.sidebarBg,
                            bgColor: context.accent,
                          ),
                        ),
                    ],
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  /// Avatar for one collapsed-rail conversation: group icon or DM peer avatar.
  /// Extracted from [_buildCollapsedSidebar] to keep it within the
  /// cognitive-complexity budget (S3776).
  Widget _buildRailAvatar(
    Conversation conv,
    String displayName,
    String myUserId,
    String serverUrl,
  ) {
    final String? avatarUrl;
    if (conv.isGroup) {
      avatarUrl = resolveAvatarUrl(conv.iconUrl, serverUrl);
    } else {
      final peer = conv.members.where((m) => m.userId != myUserId).firstOrNull;
      avatarUrl = resolveAvatarUrl(peer?.avatarUrl, serverUrl);
    }
    return buildAvatar(
      name: displayName,
      radius: 18,
      imageUrl: avatarUrl,
      bgColor: conv.isGroup ? groupAvatarColor(displayName) : null,
      fallbackIcon: conv.isGroup
          ? const Icon(Icons.group, size: 16, color: Colors.white)
          : null,
    );
  }

  /// Vertical voice-dock strip shown in the collapsed rail during a call;
  /// empty when no call is active.
  Widget _buildCollapsedVoiceDock() {
    final voiceLk = ref.watch(livekitVoiceProvider);
    if (!voiceLk.isActive || voiceLk.channelId == null) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Center(
        child: VoiceDock(
          collapsed: true,
          onNavigateToLounge: () => setState(() {
            _self._showingLounge = true;
            _self._userDismissedLounge = false;
          }),
        ),
      ),
    );
  }

  /// Builds the settings sidebar panel (replaces conversations when settings open).
  Widget _buildSettingsSidebar(double width) {
    return Container(
      width: width,
      color: context.sidebarBg,
      child: Column(
        children: [
          // Header with back button
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: BoxDecoration(
              border: Border(
                bottom: BorderSide(color: context.border, width: 1),
              ),
            ),
            child: Row(
              children: [
                IconButton(
                  icon: const Icon(Icons.arrow_back, size: 20),
                  color: context.textSecondary,
                  tooltip: 'Back to conversations',
                  onPressed: () => setState(() => _self._showSettings = false),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  'Settings',
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
          // Settings nav list
          Expanded(
            child: SettingsRootView(
              selected: _self._settingsSection,
              onTap: (section) =>
                  setState(() => _self._settingsSection = section),
              onLogout: _logout,
            ),
          ),
        ],
      ),
    );
  }

  /// Desktop layout: sidebar + flex chat + optional 280px members panel
  Widget _buildDesktopLayout() {
    final sidebarWidth = _self._sidebarWidth;

    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    _autoShowLoungeOnJoin(voiceActive);

    final rightPanel = _resolveRightPanel(voiceActive);
    final animatedSidebarWidth = _self._sidebarCollapsed
        ? _HomeScreenState._sidebarCollapsedWidth
        : sidebarWidth;

    // Show the overlay window controls when the right panel is not a
    // ChatPanel (which provides its own AppWindowButtons in its header).
    final myUserId = ref.watch(authProvider).userId ?? '';
    final titleBarText =
        (!_self._showSettings && _self._selectedConversation != null)
        ? _self._selectedConversation!.displayName(myUserId)
        : null;

    final loungeFullscreen =
        voiceActive &&
        _self._showingLounge &&
        ref.watch(voiceLoungeFullscreenProvider);

    return Scaffold(
      body: Column(
        children: [
          if (!loungeFullscreen)
            AppTitleBar(
              title: titleBarText,
              onBack: _goBackConversation,
              onForward: _goForwardConversation,
              canGoBack: _self._canGoBack,
              canGoForward: _self._canGoForward,
            ),
          Expanded(
            child: Stack(
              children: [
                Row(
                  children: [
                    if (!loungeFullscreen) ...[
                      _buildDesktopSidebar(sidebarWidth, animatedSidebarWidth),
                      _buildResizeHandle(),
                    ],
                    // Stable key so toggling fullscreen (which adds/removes
                    // the leading sidebar + trailing members siblings) REORDERS
                    // this slot instead of re-inflating it. Without it the
                    // VoiceLoungeScreen State was torn down + rebuilt on every
                    // fullscreen toggle — which broke fullscreen (dispose
                    // clears the flag) and thrashed canvas/LiveKit state.
                    Expanded(
                      key: const ValueKey('home-right-panel'),
                      child: rightPanel,
                    ),
                    if (!loungeFullscreen) ..._buildMembersPanel(),
                  ],
                ),
                // Voice dock moved inline into ConversationPanel — float overlay occluded sidebar chrome (F-029).
                if (_self._whatsNewNotes != null)
                  WhatsNewInlineOverlay(
                    notes: _self._whatsNewNotes!,
                    onDismiss: () =>
                        setState(() => _self._whatsNewNotes = null),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  /// Auto-show lounge on initial voice join; reset dismiss flag when voice
  /// becomes inactive so the next join auto-shows again.
  void _autoShowLoungeOnJoin(bool voiceActive) {
    if (voiceActive && !_self._showingLounge && !_self._userDismissedLounge) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) {
          final voiceLk = ref.read(voiceRtcProvider);
          DebugLogService.instance.log(
            LogLevel.info,
            'HomeScreen',
            'auto-showing lounge: '
                'channelId=${voiceLk.channelId ?? "none"} '
                'conversationId=${voiceLk.conversationId ?? "none"}',
          );
          setState(() => _self._showingLounge = true);
        }
      });
    }
    if (!voiceActive && _self._userDismissedLounge) {
      _self._userDismissedLounge = false;
    }
  }

  /// Determine the right-panel content based on settings, voice, or chat.
  Widget _resolveRightPanel(bool voiceActive) {
    if (_self._showSettings) {
      return SettingsContent(
        key: ValueKey(_self._settingsSection),
        section: _self._settingsSection,
      );
    }
    if (voiceActive && _self._showingLounge) {
      return VoiceLoungeScreen(
        onBackToChat: () {
          setState(() {
            _self._showingLounge = false;
            _self._userDismissedLounge = true;
          });
        },
        membersPanelVisible: _self._showMembers,
        onToggleMembersPanel: _toggleMembers,
      );
    }
    if (_self._selectedConversation != null) {
      return ChatPanel(
        conversation: _self._selectedConversation,
        onGroupInfo: _showGroupInfo,
        onMembersToggle: _self._selectedConversation?.isGroup == true
            ? _toggleMembers
            : null,
        hideVoiceDock: true,
        initialMessageId: _self._pendingMessageId,
        onShowLounge: () => setState(() {
          _self._showingLounge = true;
          _self._userDismissedLounge = false;
        }),
      );
    }
    return _buildEmptyState();
  }

  /// Desktop sidebar: either settings sidebar or conversation panel
  /// (collapsible with animated width).
  Widget _buildDesktopSidebar(double sidebarWidth, double animatedWidth) {
    if (_self._showSettings) return _buildSettingsSidebar(sidebarWidth);
    return AnimatedContainer(
      duration: const Duration(milliseconds: 200),
      curve: Curves.easeInOut,
      width: animatedWidth,
      clipBehavior: Clip.hardEdge,
      decoration: const BoxDecoration(),
      child: _self._sidebarCollapsed
          ? _buildCollapsedSidebar()
          : _buildConversationPanel(
              onCollapseSidebar: () =>
                  setState(() => _self._sidebarCollapsed = true),
            ),
    );
  }

  /// Draggable resize handle between sidebar and content area.
  ///
  /// The hit area stays at 12 px (forgiving for the mouse) but the visible
  /// seam was previously a 1 px border with no hover state — users would
  /// hunt-and-peck for the handle. Hovering now brightens the seam to the
  /// accent colour so the affordance is obvious, while the underlying drag /
  /// double-click / pull-through behaviour is unchanged.
  Widget _buildResizeHandle() {
    return _ResizeHandle(
      isCollapsed: _self._sidebarCollapsed,
      onHorizontalDragUpdate: (details) {
        if (_self._sidebarCollapsed) return;
        // Lower clamp allows pull-through to compact mode without hiding mid-drag (#739); upper scales with viewport.
        final maxWidth = _HomeScreenState._sidebarMaxWidthFor(
          MediaQuery.of(context).size.width,
        );
        setState(() {
          _self._sidebarWidth = (_self._sidebarWidth + details.delta.dx).clamp(
            _HomeScreenState._sidebarPullThroughWidth,
            maxWidth,
          );
        });
      },
      onHorizontalDragEnd: (details) {
        setState(() {
          if (_self._sidebarWidth < _HomeScreenState._sidebarMinWidth) {
            // User pulled past the min — snap to compact and restore the
            // expanded default for the next expand-from-compact toggle.
            _self._sidebarCollapsed = true;
            _self._sidebarWidth = _HomeScreenState._sidebarDefaultWidth;
          }
        });
      },
      onDoubleTap: () {
        setState(() {
          if (_self._sidebarCollapsed) {
            _self._sidebarCollapsed = false;
            _self._sidebarWidth = _HomeScreenState._sidebarDefaultWidth;
          } else {
            _self._sidebarCollapsed = true;
          }
        });
      },
    );
  }

  /// Members panel on the right side. Width is user-resizable via a drag
  /// handle (mirrors the left sidebar) and persisted in
  /// `_HomeScreenState._membersPanelWidth` for the lifetime of the screen.
  List<Widget> _buildMembersPanel() {
    if (_self._showSettings ||
        !_self._showMembers ||
        _self._selectedConversation == null ||
        !_self._selectedConversation!.isGroup) {
      return const [];
    }
    return [
      _buildMembersResizeHandle(),
      MembersPanel(
        conversation: _self._selectedConversation,
        width: _self._membersPanelWidth,
        onGroupLeft: () {
          setState(() {
            _self._selectedConversation = null;
            _self._showMembers = false;
            _self._narrowPanelIndex = 0;
          });
        },
      ),
    ];
  }

  /// Drag handle that lets the user resize the members panel. Visually
  /// identical to [_buildResizeHandle] (the sidebar's handle); horizontal
  /// drag updates clamp to [MembersPanel.minWidth] .. [MembersPanel.maxWidth].
  Widget _buildMembersResizeHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: Semantics(
        label: 'Resize members panel',
        child: GestureDetector(
          onHorizontalDragUpdate: (details) {
            // Dragging the handle LEFT widens the panel (the handle sits on
            // its left edge), so subtract the delta.
            setState(() {
              _self._membersPanelWidth =
                  (_self._membersPanelWidth - details.delta.dx).clamp(
                    MembersPanel.minWidth,
                    MembersPanel.maxWidth,
                  );
            });
          },
          onDoubleTap: () {
            setState(() {
              _self._membersPanelWidth = MembersPanel.defaultWidth;
            });
          },
          child: Container(
            width: 12,
            color: Colors.transparent,
            child: Center(child: Container(width: 1, color: context.border)),
          ),
        ),
      ),
    );
  }
}

/// Sidebar resize handle. Stateful so the seam can highlight on hover and
/// while a drag is in flight, without forcing a rebuild of the whole
/// HomeScreen on every pointer enter/exit.
class _ResizeHandle extends StatefulWidget {
  final bool isCollapsed;
  final GestureDragUpdateCallback onHorizontalDragUpdate;
  final GestureDragEndCallback onHorizontalDragEnd;
  final VoidCallback onDoubleTap;

  const _ResizeHandle({
    required this.isCollapsed,
    required this.onHorizontalDragUpdate,
    required this.onHorizontalDragEnd,
    required this.onDoubleTap,
  });

  @override
  State<_ResizeHandle> createState() => _ResizeHandleState();
}

class _ResizeHandleState extends State<_ResizeHandle> {
  bool _hovering = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final highlighted = _hovering || _dragging;
    final seamColor = highlighted ? context.accent : context.border;
    final seamWidth = highlighted ? 2.0 : 1.0;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hovering = true),
      onExit: (_) => setState(() => _hovering = false),
      child: Tooltip(
        message: 'Drag to resize, double-click to collapse',
        waitDuration: const Duration(milliseconds: 500),
        child: Semantics(
          label: 'Resize sidebar',
          child: GestureDetector(
            onHorizontalDragStart: (_) => setState(() => _dragging = true),
            onHorizontalDragUpdate: widget.onHorizontalDragUpdate,
            onHorizontalDragEnd: (details) {
              setState(() => _dragging = false);
              widget.onHorizontalDragEnd(details);
            },
            onHorizontalDragCancel: () => setState(() => _dragging = false),
            onDoubleTap: widget.onDoubleTap,
            // Container is `double.infinity` tall via Row's cross-axis
            // stretch, transparent fill keeps the full 12 px as hit area.
            child: Container(
              width: 12,
              color: Colors.transparent,
              alignment: Alignment.center,
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 120),
                curve: Curves.easeOut,
                width: seamWidth,
                color: seamColor,
              ),
            ),
          ),
        ),
      ),
    );
  }
}
