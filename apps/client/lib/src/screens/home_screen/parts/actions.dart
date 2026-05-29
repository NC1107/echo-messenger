part of '../../home_screen.dart';

/// User-driven actions and dialog openers wired up from the sidebar,
/// command palette, notifications, and the conversation panel:
/// conversation selection, the New Message / Create Group / Discover /
/// Contacts / Saved Messages dialogs, the global search and quick
/// switcher overlays, settings entry, members-panel toggle, group info
/// sheet, notification-tap routing, and logout. The desktop-vs-mobile
/// routing for these actions also lives here.
mixin _HomeScreenActionsMixin on ConsumerState<HomeScreen> {
  _HomeScreenState get _self => this as _HomeScreenState;

  void _selectConversation(Conversation conv, {String? messageId}) {
    // Push to history only for user-initiated navigation, not back/forward jumps.
    if (!_self._navJumping) {
      _pushNavHistory(conv.id);
    }
    setState(() {
      _self._selectedConversation = conv;
      _self._pendingMessageId = messageId;
      _self._narrowPanelIndex = 1;
      _self._showSettings = false;
      // Collapse lounge; only lock auto-show when voice is active (i.e., navigating away from a call).
      _self._showingLounge = false;
      if (ref.read(voiceRtcProvider).isActive) {
        _self._userDismissedLounge = true;
      }
    });
    // Clear notifications for this conversation now that the user is viewing it.
    NotificationService().cancelConversationNotifications(conv.id);
  }

  /// Pushes [conversationId] onto the navigation history, truncating any
  /// forward entries (browser model). Caps the list at [_navHistoryLimit].
  void _pushNavHistory(String conversationId) {
    final history = _self._navHistory;
    final currentIndex = _self._navHistoryIndex;

    // Skip duplicate: re-selecting the current conversation is a no-op.
    if (currentIndex >= 0 && history[currentIndex] == conversationId) return;

    // Truncate forward history: entries after current index are discarded.
    if (currentIndex < history.length - 1) {
      history.removeRange(currentIndex + 1, history.length);
    }

    history.add(conversationId);

    // Enforce cap — drop the oldest entry.
    if (history.length > _HomeScreenState._navHistoryLimit) {
      history.removeAt(0);
    }

    _self._navHistoryIndex = history.length - 1;
  }

  /// Navigates back one step in the conversation history, skipping any
  /// entries whose conversations have since been removed.
  void _goBackConversation() {
    _jumpHistory(forward: false);
  }

  /// Navigates forward one step in the conversation history, skipping any
  /// entries whose conversations have since been removed.
  void _goForwardConversation() {
    _jumpHistory(forward: true);
  }

  /// Shared back/forward navigator. Moves [_navHistoryIndex] by ±1, finds
  /// the matching live [Conversation], and selects it without re-pushing.
  void _jumpHistory({required bool forward}) {
    final history = _self._navHistory;
    var idx = _self._navHistoryIndex;
    final conversations = ref.read(conversationsProvider).conversations;

    // Walk in the requested direction, skipping deleted conversations.
    while (true) {
      idx = forward ? idx + 1 : idx - 1;
      if (idx < 0 || idx >= history.length) return;

      final targetId = history[idx];
      final conv = conversations.where((c) => c.id == targetId).firstOrNull;

      if (conv != null) {
        _self._navHistoryIndex = idx;
        _self._navJumping = true;
        _selectConversation(conv);
        _self._navJumping = false;
        return;
      }
      // Entry no longer exists — continue walking past it.
    }
  }

  void _showQuickSwitcher() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      barrierLabel: 'Dismiss quick switcher',
      builder: (ctx) =>
          QuickSwitcherOverlay(onSelect: (conv) => _selectConversation(conv)),
    );
  }

  void _showGlobalSearch() {
    showDialog(
      context: context,
      barrierColor: Colors.black54,
      barrierLabel: 'Dismiss global search',
      builder: (ctx) => GlobalSearchOverlay(
        onResultTap: (conversationId, messageId) {
          final conversations = ref.read(conversationsProvider).conversations;
          final conv = conversations
              .where((c) => c.id == conversationId)
              .firstOrNull;
          if (conv != null) _selectConversation(conv);
        },
        onContactTap: (userId, username) => _messageContact(userId, username),
      ),
    );
  }

  void _showKeyboardShortcuts() {
    showDialog<void>(
      context: context,
      barrierColor: Colors.black54,
      barrierLabel: 'Dismiss keyboard shortcuts',
      builder: (_) => const KeyboardShortcutsOverlay(),
    );
  }

  /// Called when the user taps a notification — find the conversation and select it.
  void _onNotificationTap(String conversationId) {
    if (!mounted || conversationId.isEmpty) return;
    final conversations = ref.read(conversationsProvider).conversations;
    final conv = conversations.where((c) => c.id == conversationId).firstOrNull;
    if (conv != null) {
      _selectConversation(conv);
    }
  }

  void _openContacts() {
    if (_self._isDesktop) {
      _showContactsDialog();
    } else {
      context.push('/contacts');
    }
  }

  /// Opens the dedicated "New message" composer. Tapping a contact starts
  /// a DM and selects the resulting conversation. On desktop the composer
  /// is shown as a centered dialog; on mobile it pushes as a full screen.
  ///
  /// Zero-contacts short-circuit: with no contacts the picker would only
  /// show "No contacts available", so we route the user to the contacts
  /// screen instead (where Add-contact actually works) and surface a
  /// toast explaining why.
  Future<void> _openNewMessage() async {
    final contactsState = ref.read(contactsProvider);
    if (contactsState.contacts.isEmpty) {
      ToastService.show(
        context,
        'Add a contact first — there\'s no-one to message yet.',
        type: ToastType.info,
      );
      _openContacts();
      return;
    }
    if (_self._isDesktop) {
      await showDialog<void>(
        context: context,
        builder: (dialogContext) {
          final size = MediaQuery.of(dialogContext).size;
          return Dialog(
            backgroundColor: context.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(EchoRadii.lg),
              side: BorderSide(color: context.border),
            ),
            child: SizedBox(
              width: (size.width * 0.4).clamp(360, 520).toDouble(),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(EchoRadii.lg),
                child: SingleChildScrollView(
                  child: NewMessageScreen(
                    onStartConversation: (conv) {
                      Navigator.pop(dialogContext);
                      _selectConversation(conv);
                    },
                  ),
                ),
              ),
            ),
          );
        },
      );
    } else {
      final result = await Navigator.of(context).push<Conversation>(
        MaterialPageRoute(
          builder: (_) => NewMessageScreen(
            onStartConversation: (conv) => Navigator.of(context).pop(conv),
          ),
          fullscreenDialog: true,
        ),
      );
      if (result != null && mounted) {
        _selectConversation(result);
      }
    }
  }

  void _openCreateGroup() {
    if (_self._isDesktop) {
      _showCreateGroupDialog();
    } else {
      context.push('/create-group');
    }
  }

  void _openDiscoverGroups() {
    if (_self._isDesktop) {
      _showDiscoverGroupsDialog();
    } else {
      context.push('/discover-groups');
    }
  }

  void _showDiscoverGroupsDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EchoRadii.lg),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.4).clamp(320, 560).toDouble(),
            height: (size.height * 0.7).clamp(400, 720).toDouble(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(EchoRadii.lg),
              child: DiscoverGroupsScreen(onCreateGroup: _openCreateGroup),
            ),
          ),
        );
      },
    );
  }

  /// Called from the Contacts tab in the sidebar when "Message" is tapped.
  Future<void> _messageContact(String userId, String username) async {
    try {
      final conv = await ref
          .read(conversationsProvider.notifier)
          .getOrCreateDm(userId, username);
      if (!mounted) return;
      _selectConversation(conv);
    } on DmException catch (e) {
      if (!mounted) return;
      ToastService.show(context, e.message, type: ToastType.error);
    } catch (e) {
      if (!mounted) return;
      ToastService.show(
        context,
        'Could not start conversation',
        type: ToastType.error,
      );
    }
  }

  void _showContactsDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EchoRadii.lg),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.4).clamp(320, 560).toDouble(),
            height: (size.height * 0.65).clamp(400, 680).toDouble(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(EchoRadii.lg),
              child: ContactsScreen(
                onStartConversation: (conv) {
                  Navigator.pop(dialogContext);
                  _selectConversation(conv);
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _showCreateGroupDialog() {
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EchoRadii.lg),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.4).clamp(320, 560).toDouble(),
            height: (size.height * 0.65).clamp(400, 680).toDouble(),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(EchoRadii.lg),
              child: const CreateGroupScreen(),
            ),
          ),
        );
      },
    );
  }

  void _showGroupInfo() {
    final conv = _self._selectedConversation;
    if (conv == null || !conv.isGroup) return;
    showGroupProfileSheet(context, ref, conv.id);
  }

  void _toggleMembers() {
    setState(() {
      _self._showMembers = !_self._showMembers;
    });
  }

  void _openSavedMessages() {
    final isMobile = MediaQuery.sizeOf(context).width < 600;
    if (isMobile) {
      context.push('/saved');
      return;
    }
    showDialog(
      context: context,
      builder: (dialogContext) {
        final size = MediaQuery.of(dialogContext).size;
        return Dialog(
          backgroundColor: context.surface,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(EchoRadii.lg),
            side: BorderSide(color: context.border),
          ),
          child: SizedBox(
            width: (size.width * 0.45).clamp(340.0, 600.0),
            height: (size.height * 0.7).clamp(400.0, 720.0),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(EchoRadii.lg),
              child: SavedMessagesScreen(
                onNavigateToConversation: (convId, messageId) {
                  Navigator.pop(dialogContext);
                  final conversations = ref
                      .read(conversationsProvider)
                      .conversations;
                  final conv = conversations
                      .where((c) => c.id == convId)
                      .firstOrNull;
                  if (conv != null) {
                    _selectConversation(conv, messageId: messageId);
                  }
                },
              ),
            ),
          ),
        );
      },
    );
  }

  void _openSettings() {
    if (_self._isDesktop || !Responsive.isMobile(context)) {
      setState(() {
        _self._showSettings = true;
        _self._settingsSection = SettingsSection.profile;
      });
    } else {
      context.push('/settings');
    }
  }

  Future<void> _logout() async {
    final confirmed = await showEchoConfirmDialog(
      context,
      title: 'Log Out',
      content: 'Are you sure you want to log out?',
      confirmLabel: 'Log Out',
      destructive: true,
    );

    if (!confirmed) return;

    ref.read(websocketProvider.notifier).disconnect();
    ref.read(chatProvider.notifier).clear();
    unawaited(ref.read(cryptoProvider.notifier).resetState());

    final auth = ref.read(authProvider.notifier);
    // Account switching is surfaced here (not as a Settings row): if other
    // accounts are still stored on this device, route to the picker; else
    // go to login.
    final nextAccount = await auth.logoutAndPickNextAccount();

    if (!mounted) return;
    context.go(nextAccount != null ? '/auth/pick-account' : '/login');
  }
}
