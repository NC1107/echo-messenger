part of '../../home_screen.dart';

/// Tablet (600–899px) layout for [HomeScreen]: fixed 300px sidebar with
/// either the conversation panel or the settings panel, a 1px divider,
/// and the right-hand content area that shows the chat panel, voice
/// lounge, settings, or the empty state. Shares `_autoShowLoungeOnJoin`
/// and `_buildConversationPanel` with the desktop layout.
mixin _HomeScreenWideLayoutMixin
    on
        ConsumerState<HomeScreen>,
        _HomeScreenActionsMixin,
        _HomeScreenListenersMixin,
        _HomeScreenDesktopLayoutMixin {
  // `_self` is provided by `_HomeScreenActionsMixin`.

  /// Tablet layout (600-899px): sidebar + flex chat
  Widget _buildWideLayout() {
    final voiceRtc = ref.watch(voiceRtcProvider);
    final voiceActive = voiceRtc.isActive && voiceRtc.channelId != null;

    _autoShowLoungeOnJoin(voiceActive);

    Widget rightPanel;
    if (_self._showSettings) {
      rightPanel = SettingsContent(
        key: ValueKey(_self._settingsSection),
        section: _self._settingsSection,
      );
    } else if (voiceActive && _self._showingLounge) {
      rightPanel = VoiceLoungeScreen(
        onBackToChat: () {
          setState(() {
            _self._showingLounge = false;
            _self._userDismissedLounge = true;
          });
        },
        membersPanelVisible: _self._showMembers,
        onToggleMembersPanel: _toggleMembers,
      );
    } else if (_self._selectedConversation != null) {
      rightPanel = ChatPanel(
        conversation: _self._selectedConversation,
        onGroupInfo: _showGroupInfo,
        initialMessageId: _self._pendingMessageId,
        onShowLounge: () => setState(() {
          _self._showingLounge = true;
          _self._userDismissedLounge = false;
        }),
      );
    } else {
      rightPanel = _buildEmptyState();
    }

    final myUserId = ref.watch(authProvider).userId ?? '';
    final titleBarText =
        (!_self._showSettings && _self._selectedConversation != null)
        ? _self._selectedConversation!.displayName(myUserId)
        : null;

    final voiceLk = ref.watch(livekitVoiceProvider);
    final loungeFullscreen =
        voiceLk.channelId != null &&
        _self._showingLounge &&
        ref.watch(voiceLoungeFullscreenProvider);

    return Scaffold(
      body: Column(
        children: [
          if (!loungeFullscreen) AppTitleBar(title: titleBarText),
          Expanded(
            child: Stack(
              children: [
                Row(
                  children: [
                    if (!loungeFullscreen) ...[
                      if (_self._showSettings)
                        _buildSettingsSidebar(300)
                      else
                        SizedBox(width: 300, child: _buildConversationPanel()),
                      Container(width: 1, color: context.border),
                    ],
                    // Stable key so toggling fullscreen (removes the leading
                    // sidebar siblings) reorders this slot instead of
                    // re-inflating it — preserves the VoiceLoungeScreen State
                    // (see desktop_layout for the full rationale).
                    Expanded(
                      key: const ValueKey('home-right-panel'),
                      child: rightPanel,
                    ),
                  ],
                ),
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
}
