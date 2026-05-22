part of '../../home_screen.dart';

/// Mobile (<600px) layout for [HomeScreen]: bottom tab bar with
/// Chats/Discover/Contacts/Settings, the full-screen chat panel that
/// appears when a conversation is open on the Chats tab, the
/// edge-swipe-back gesture that pops chat → conversation list, and the
/// voice-footer rejoin strip shown when the user has dismissed the
/// lounge while a call is still active. The edge-swipe state itself
/// (`_swipeStartX`, `_swipeProgress`, `_swipeSnapController`) lives on
/// the parent state class because `_swipeSnapController` is initialised
/// in `initState` and disposed in `dispose` — splitting that across
/// parts would scatter the animation timing across files.
///
/// The `_MobileTabSpec`, `_UnreadBadge`, and `_DotBadge` classes used by
/// the tab bar (and also by the desktop collapsed-sidebar settings icon
/// in the case of `_DotBadge`) also live in this part — they're scoped
/// to the layout that needs them.
mixin _HomeScreenNarrowLayoutMixin
    on
        ConsumerState<HomeScreen>,
        _HomeScreenActionsMixin,
        _HomeScreenDesktopLayoutMixin {
  // `_self` is provided by `_HomeScreenActionsMixin`.

  /// Build the narrow chat panel with voice banner and edge-swipe support.
  Widget _buildNarrowChatPanel(LiveKitVoiceState voiceRtc, bool voiceActive) {
    // Show voice lounge when voice is active and user hasn't dismissed it
    if (voiceActive && _self._showingLounge) {
      return Scaffold(
        body: SafeArea(
          child: VoiceLoungeScreen(
            onBackToChat: () => setState(() {
              _self._showingLounge = false;
              _self._userDismissedLounge = true;
            }),
          ),
        ),
      );
    }

    final layout = ref.watch(channelLayoutProvider);
    // Discord-style channel drawer: kicks in on the same path the outer
    // edge-swipe-back uses, but only when the user has opted into the
    // column layout AND the open conversation is a group with channels.
    // Otherwise we keep the existing swipe-to-conversations behaviour.
    final useColumnDrawer =
        layout == ChannelLayout.column &&
        (_self._selectedConversation?.isGroup ?? false);

    Widget chatContent = ChatPanel(
      conversation: _self._selectedConversation,
      onGroupInfo: _showGroupInfo,
      onBack: () => setState(() => _self._narrowPanelIndex = 0),
      initialMessageId: _self._pendingMessageId,
      onShowLounge: () => setState(() {
        _self._showingLounge = true;
        _self._userDismissedLounge = false;
      }),
      onConversationSelected: useColumnDrawer
          ? (id) {
              final next = ref
                  .read(conversationsProvider)
                  .conversations
                  .where((c) => c.id == id)
                  .firstOrNull;
              if (next != null) {
                setState(() => _self._selectedConversation = next);
              }
            }
          : null,
    );

    // Note: a "● <channel> — Tap to view voice" rejoin banner used to sit
    // between the chat and a dismissed lounge.  It has been removed because
    // the persistent VoiceDock at the bottom of the sidebar already shows
    // the active voice channel name + status indicator + controls and is
    // tappable to reopen the lounge -- the banner duplicated that affordance.

    return Scaffold(
      body: SafeArea(
        child: PopScope(
          canPop: false,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) setState(() => _self._narrowPanelIndex = 0);
          },
          child: GestureDetector(
            // Suppressed in column mode so the channel-drawer's own
            // edge-swipe wins. The drawer covers the same "go back to
            // navigation" affordance for column users.
            onHorizontalDragStart: useColumnDrawer
                ? null
                : (startDetails) {
                    _self._swipeStartX = startDetails.globalPosition.dx;
                    _self._swipeSnapController.stop();
                  },
            onHorizontalDragUpdate: useColumnDrawer
                ? null
                : (details) {
                    if (_self._swipeStartX == null) return;
                    if (_self._swipeStartX! >=
                        _HomeScreenState._edgeSwipeZone) {
                      return;
                    }

                    final deltaX =
                        details.globalPosition.dx - _self._swipeStartX!;

                    if (deltaX > _HomeScreenState._edgeSwipeThreshold) {
                      // Threshold crossed — complete navigation and reset.
                      _self._swipeStartX = null;
                      setState(() {
                        _self._swipeProgress = 0.0;
                        _self._narrowPanelIndex = 0;
                      });
                      return;
                    }

                    // Update in-progress feedback.
                    final progress =
                        (deltaX.clamp(
                          0.0,
                          _HomeScreenState._edgeSwipeThreshold,
                        ) /
                        _HomeScreenState._edgeSwipeThreshold);
                    setState(() => _self._swipeProgress = progress);
                  },
            onHorizontalDragEnd: useColumnDrawer
                ? null
                : (_) {
                    if (_self._swipeProgress > 0.0) {
                      // Snap back from current progress to 0 over 150 ms.
                      _self._swipeSnapController.value = _self._swipeProgress;
                      _self._swipeSnapController.animateBack(
                        0.0,
                        curve: Curves.easeOut,
                      );
                    }
                    _self._swipeStartX = null;
                  },
            child: Stack(
              children: [
                chatContent,
                // Left-edge peek panel: a narrow strip that slides in from the
                // left proportionally to swipe progress.  At progress=1 it is
                // 80 px wide and fully visible; it fades out as progress falls.
                if (_self._swipeProgress > 0.0)
                  Positioned(
                    left: 0,
                    top: 0,
                    bottom: 0,
                    width: 80,
                    child: Transform.translate(
                      offset: Offset((1.0 - _self._swipeProgress) * -80.0, 0),
                      child: Opacity(
                        opacity: _self._swipeProgress,
                        child: DecoratedBox(
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            boxShadow: [
                              BoxShadow(
                                color: Colors.black.withValues(
                                  alpha: 0.18 * _self._swipeProgress,
                                ),
                                blurRadius: 12,
                                offset: const Offset(4, 0),
                              ),
                            ],
                          ),
                          child: Center(
                            child: Icon(
                              Icons.chevron_right_rounded,
                              color: Theme.of(context).colorScheme.onSurface
                                  .withValues(
                                    alpha: 0.6 * _self._swipeProgress,
                                  ),
                              size: 28,
                            ),
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
    );
  }

  Widget _buildNarrowLayout() {
    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    _autoShowLoungeOnJoin(voiceActive);

    // Voice lounge takes precedence over any tab on mobile narrow.  Without
    // this gate, joining voice from Discover/Contacts/Settings left the user
    // staring at that tab while the lounge state was already true.
    if (voiceActive && _self._showingLounge) {
      return Scaffold(
        body: SafeArea(
          child: VoiceLoungeScreen(
            onBackToChat: () => setState(() {
              _self._showingLounge = false;
              _self._userDismissedLounge = true;
            }),
          ),
        ),
      );
    }

    // When on the Chats tab AND a conversation is open, render the chat
    // full-screen with no bottom tab bar. Pressing back returns to the
    // conversation list with the tab bar visible.
    if (_self._mobileTabIndex == 0 &&
        _self._narrowPanelIndex == 1 &&
        _self._selectedConversation != null) {
      return _buildNarrowChatPanel(voiceRtc, voiceActive);
    }

    final Widget body;
    switch (_self._mobileTabIndex) {
      case 1:
        body = DiscoverGroupsScreen(onCreateGroup: _openCreateGroup);
      case 2:
        body = const ContactsScreen();
      case 3:
        body = const SettingsScreen();
      case 0:
      default:
        body = SafeArea(child: _buildConversationPanel());
    }

    return Scaffold(
      body: Column(
        children: [
          Expanded(child: body),
          // Show the voice footer between the content and the tab bar when
          // the user is in a call but has dismissed the lounge overlay.
          if (voiceActive && !_self._showingLounge)
            VoiceFooter(
              onNavigateToLounge: () => setState(() {
                _self._showingLounge = true;
                _self._userDismissedLounge = false;
              }),
            ),
        ],
      ),
      bottomNavigationBar: _buildMobileTabBar(),
    );
  }

  /// Bottom tab bar shown on the mobile narrow viewport. Switching tabs
  /// preserves each tab's local state via the parent state holder, and
  /// resets the chat-detail navigation when switching away from Chats.
  Widget _buildMobileTabBar() {
    final unreadTotal = ref
        .watch(conversationsProvider)
        .conversations
        .fold<int>(0, (s, c) => s + c.unreadCount);
    final updateState = ref.watch(updateProvider);
    final showUpdateDot = updateState.updateAvailable && !updateState.dismissed;

    final tabs = _buildMobileTabSpecs(unreadTotal, showUpdateDot);

    return Material(
      color: context.sidebarBg,
      child: SafeArea(
        top: false,
        child: Container(
          height: 64,
          decoration: BoxDecoration(
            border: Border(top: BorderSide(color: context.border, width: 1)),
          ),
          child: Row(
            children: List.generate(tabs.length, (i) {
              return _buildMobileTabItem(tabs[i], i);
            }),
          ),
        ),
      ),
    );
  }

  List<_MobileTabSpec> _buildMobileTabSpecs(
    int unreadTotal,
    bool showUpdateDot,
  ) {
    return <_MobileTabSpec>[
      _MobileTabSpec(
        label: 'Chats',
        outlinedIcon: Icons.chat_bubble_outline,
        filledIcon: Icons.chat_bubble,
        badge: unreadTotal,
      ),
      const _MobileTabSpec(
        label: 'Discover',
        outlinedIcon: Icons.explore_outlined,
        filledIcon: Icons.explore,
      ),
      const _MobileTabSpec(
        label: 'Contacts',
        outlinedIcon: Icons.people_outline,
        filledIcon: Icons.people,
      ),
      _MobileTabSpec(
        label: 'Settings',
        outlinedIcon: Icons.settings_outlined,
        filledIcon: Icons.settings,
        showDot: showUpdateDot,
      ),
    ];
  }

  Widget _buildMobileTabItem(_MobileTabSpec tab, int index) {
    final isActive = index == _self._mobileTabIndex;
    return Expanded(
      child: Semantics(
        selected: isActive,
        button: true,
        // "Chats tab", "Discover tab", etc. The trailing word matches
        // the e2e a11y selectors (`getByRole('button', { name: /chats
        // tab/i })`) and reads naturally to screen readers.
        label: '${tab.label} tab',
        child: InkWell(
          onTap: () {
            if (index == _self._mobileTabIndex) return;
            HapticFeedback.selectionClick();
            setState(() {
              _self._mobileTabIndex = index;
              if (index != 0) {
                _self._narrowPanelIndex = 0;
              }
            });
          },
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildMobileTabIcon(tab, isActive),
              const SizedBox(height: 3),
              _buildMobileTabLabel(tab, isActive),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMobileTabIcon(_MobileTabSpec tab, bool isActive) {
    return Stack(
      clipBehavior: Clip.none,
      children: [
        Icon(
          isActive ? tab.filledIcon : tab.outlinedIcon,
          size: 24,
          color: isActive ? context.accent : context.textMuted,
        ),
        if (tab.badge > 0)
          Positioned(
            top: -3,
            right: -8,
            child: _UnreadBadge(
              count: tab.badge,
              ringColor: context.sidebarBg,
              bgColor: context.accent,
            ),
          )
        else if (tab.showDot)
          Positioned(
            top: -2,
            right: -2,
            child: _DotBadge(
              ringColor: context.sidebarBg,
              bgColor: context.accent,
            ),
          ),
      ],
    );
  }

  Widget _buildMobileTabLabel(_MobileTabSpec tab, bool isActive) {
    return Text(
      tab.label,
      style: TextStyle(
        fontSize: 10,
        fontWeight: isActive ? FontWeight.w600 : FontWeight.w500,
        color: isActive ? context.accent : context.textMuted,
        letterSpacing: 0.1,
      ),
    );
  }
}

class _MobileTabSpec {
  final String label;
  final IconData outlinedIcon;
  final IconData filledIcon;
  final int badge;

  /// Show a small accent-coloured dot (no count) on top of the icon. Used to
  /// surface low-frequency, non-critical signals — e.g. an available update
  /// (#792). [badge] takes precedence when both are set.
  final bool showDot;

  const _MobileTabSpec({
    required this.label,
    required this.outlinedIcon,
    required this.filledIcon,
    this.badge = 0,
    this.showDot = false,
  });
}

class _UnreadBadge extends StatelessWidget {
  final int count;
  final Color ringColor;
  final Color bgColor;
  const _UnreadBadge({
    required this.count,
    required this.ringColor,
    required this.bgColor,
  });

  @override
  Widget build(BuildContext context) {
    final label = count > 99 ? '99+' : '$count';
    return Container(
      constraints: const BoxConstraints(minWidth: 16, minHeight: 16),
      padding: const EdgeInsets.symmetric(horizontal: EchoSpacing.xs),
      decoration: BoxDecoration(
        color: bgColor,
        borderRadius: BorderRadius.circular(EchoRadii.md),
        border: Border.all(color: ringColor, width: 2),
      ),
      child: Center(
        child: Text(
          label,
          style: const TextStyle(
            color: Colors.white,
            fontSize: 10,
            fontWeight: FontWeight.w700,
            height: 1.0,
          ),
        ),
      ),
    );
  }
}

/// Small dot indicator (no count). Used for low-frequency, non-critical
/// signals like an available update on the Settings icon (#792).
class _DotBadge extends StatelessWidget {
  final Color ringColor;
  final Color bgColor;
  const _DotBadge({required this.ringColor, required this.bgColor});

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'update available',
      child: Container(
        width: 10,
        height: 10,
        decoration: BoxDecoration(
          color: bgColor,
          shape: BoxShape.circle,
          border: Border.all(color: ringColor, width: 1.5),
        ),
      ),
    );
  }
}
