part of '../../home_screen.dart';

/// Provider listeners and cross-state synchronisation for [HomeScreen]:
/// conversation-error / crypto-error / voice-error toasts, tray-badge
/// upkeep, voice-disconnect-redirect, and the `_syncSelectedConversation`
/// loop that keeps `_selectedConversation` in lock-step with the
/// provider's view of the world. Also hosts the empty-state widget shown
/// when no conversation is open.
mixin _HomeScreenListenersMixin
    on ConsumerState<HomeScreen>, _HomeScreenActionsMixin {
  // `_self` is provided by `_HomeScreenActionsMixin`.

  void _listenForErrors() {
    _listenConversationsErrors();
    _listenCryptoErrors();
    _listenVoiceErrors();
  }

  void _listenConversationsErrors() {
    ref.listen<ConversationsState>(conversationsProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ToastService.show(context, next.error!, type: ToastType.error);
      }
      _updateTrayBadgeIfNeeded(prev, next);
    });
  }

  void _updateTrayBadgeIfNeeded(
    ConversationsState? prev,
    ConversationsState next,
  ) {
    if (!TrayService.isSupported) return;
    final prevTotal =
        prev?.conversations.fold<int>(0, (s, c) => s + c.unreadCount) ?? 0;
    final nextTotal = next.conversations.fold<int>(
      0,
      (s, c) => s + c.unreadCount,
    );
    if (nextTotal != prevTotal) {
      unawaited(TrayService.instance.updateBadge(nextTotal));
    }
  }

  void _listenCryptoErrors() {
    ref.listen<CryptoState>(cryptoProvider, (prev, next) {
      if (next.error != null && next.error != prev?.error) {
        ToastService.show(
          context,
          'Encryption: ${next.error}',
          type: ToastType.error,
        );
      }
      if (next.keysWereRegenerated && !(prev?.keysWereRegenerated ?? false)) {
        ToastService.show(
          context,
          'Your encryption keys were regenerated. '
          'Previous encrypted messages may not be readable.',
          type: ToastType.error,
        );
      }
    });
  }

  void _listenVoiceErrors() {
    ref.listen<LiveKitVoiceState>(voiceRtcProvider, (prev, next) {
      if (next.error == null || next.error == prev?.error) return;
      ToastService.show(context, next.error!, type: ToastType.error);
      _handleVoiceDisconnectRedirect(next);
    });
  }

  void _handleVoiceDisconnectRedirect(LiveKitVoiceState next) {
    if (next.error == 'Voice disconnected. Please sign in again.' &&
        !ref.read(authProvider).isLoggedIn &&
        mounted) {
      context.go('/login');
    }
  }

  /// Keep the selected conversation in sync with provider state so that
  /// changes (e.g. encryption toggle) propagate to ChatPanel immediately.
  /// IMPORTANT: Do NOT clear _selectedConversation when fresh is null
  /// AND the list is currently reloading — the conversation may be
  /// temporarily absent. Once the load settles, clear it so deleting
  /// the last group doesn't leave a stale chat panel rendered (TD-17).
  void _syncSelectedConversation() {
    if (_self._selectedConversation == null) return;
    final convState = ref.watch(conversationsProvider);
    final convs = convState.conversations;
    final fresh = convs
        .where((c) => c.id == _self._selectedConversation!.id)
        .firstOrNull;
    if (fresh != null && fresh != _self._selectedConversation) {
      _self._selectedConversation = fresh;
      return;
    }
    // Clear selection on removal; gate on isLoading so deleting the last conversation still clears.
    if (fresh == null && !convState.isLoading) {
      _self._selectedConversation = null;
      _self._narrowPanelIndex = 0;
    }
  }

  Widget _buildEmptyState() {
    return Container(
      color: context.chatBg,
      child: EmptyState(
        icon: Icons.forum_rounded,
        title: 'No conversation selected',
        body: 'Choose a conversation from the sidebar or start a new chat.',
        ctaLabel: 'Add contact',
        onCta: _openContacts,
        secondaryCtaLabel: 'Browse groups',
        onSecondaryCta: _openDiscoverGroups,
      ),
    );
  }
}
