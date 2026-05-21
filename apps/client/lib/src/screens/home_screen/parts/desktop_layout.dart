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
      onOpenThreads: _openThreads,
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

                // KeyedSubtree so element identity tracks conv.id rather
                // than the position index — prevents the Stack +
                // conditional selection-pill subtree from briefly
                // binding to the wrong conversation when the list
                // reorders after a new message / pin / delete (TD-10).
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
                            // Stack so the left-edge selection pill can sit
                            // alongside the centred avatar without affecting
                            // its layout. Matches the pattern used in
                            // conversation_item so both sidebars agree.
                            child: Stack(
                              children: [
                                Center(
                                  child: Builder(
                                    builder: (_) {
                                      final String? avatarUrl;
                                      if (conv.isGroup) {
                                        avatarUrl = resolveAvatarUrl(
                                          conv.iconUrl,
                                          serverUrl,
                                        );
                                      } else {
                                        final peer = conv.members
                                            .where((m) => m.userId != myUserId)
                                            .firstOrNull;
                                        avatarUrl = resolveAvatarUrl(
                                          peer?.avatarUrl,
                                          serverUrl,
                                        );
                                      }
                                      return buildAvatar(
                                        name: displayName,
                                        radius: 18,
                                        imageUrl: avatarUrl,
                                        bgColor: conv.isGroup
                                            ? groupAvatarColor(displayName)
                                            : null,
                                        fallbackIcon: conv.isGroup
                                            ? const Icon(
                                                Icons.group,
                                                size: 16,
                                                color: Colors.white,
                                              )
                                            : null,
                                      );
                                    },
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
                          child: _DotBadge(
                            ringColor: context.mainBg,
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

    return Scaffold(
      body: Column(
        children: [
          AppTitleBar(title: titleBarText),
          Expanded(
            child: Stack(
              children: [
                Row(
                  children: [
                    _buildDesktopSidebar(sidebarWidth, animatedSidebarWidth),
                    _buildResizeHandle(),
                    Expanded(child: rightPanel),
                    ..._buildMembersPanel(),
                  ],
                ),
                // Voice dock used to float here as an AnimatedPositioned
                // overlay at bottom: 60, which made it occlude the sidebar
                // chrome (bug-report row, update banner). It now renders
                // inline inside ConversationPanel just above the bottom
                // chrome so everything flows naturally and nothing is
                // covered. F-029 in the 2026-05-19 UI audit.
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
  Widget _buildResizeHandle() {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      child: Semantics(
        label: 'Resize sidebar',
        child: GestureDetector(
          onHorizontalDragUpdate: (details) {
            if (_self._sidebarCollapsed) return;
            // Allow dragging below `_sidebarMinWidth` so users can pull the
            // handle through to compact mode and the drag-end handler can
            // snap to collapsed. The lower clamp keeps the sidebar from
            // disappearing entirely mid-drag (#739).
            setState(() {
              _self._sidebarWidth = (_self._sidebarWidth + details.delta.dx)
                  .clamp(
                    _HomeScreenState._sidebarPullThroughWidth,
                    _HomeScreenState._sidebarMaxWidth,
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
          child: Container(
            width: 12,
            color: Colors.transparent,
            child: Center(child: Container(width: 1, color: context.border)),
          ),
        ),
      ),
    );
  }

  /// Optional 280px members panel on the right side.
  List<Widget> _buildMembersPanel() {
    if (_self._showSettings ||
        !_self._showMembers ||
        _self._selectedConversation == null ||
        !_self._selectedConversation!.isGroup) {
      return const [];
    }
    return [
      Container(width: 1, color: context.border),
      MembersPanel(
        conversation: _self._selectedConversation,
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
}
