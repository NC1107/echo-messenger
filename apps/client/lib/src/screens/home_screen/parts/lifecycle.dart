part of '../../home_screen.dart';

/// Startup flows and one-shot initialisation helpers for [HomeScreen]:
/// the awaited `_initData` boot sequence, the tray "Check for updates"
/// handler, the What's New modal trigger, the pending-contacts refresh
/// loop, and the first-login server notice. The actual `initState`,
/// `dispose`, and `didChangeAppLifecycleState` overrides remain in the
/// parent file so the lifecycle scaffolding sits next to the field
/// declarations it touches.
///
/// Lives as a `part of 'home_screen.dart'` and is mixed into
/// `_HomeScreenState`. Mirrors the `apps/client/lib/src/providers/auth/`
/// pattern: the state class is declared in the parent file and parts
/// extend behaviour via mixins that share the same library scope.
mixin _HomeScreenLifecycleMixin
    on ConsumerState<HomeScreen>, _HomeScreenActionsMixin {
  // `_self` is provided by `_HomeScreenActionsMixin` for reaching private parent fields.

  Future<void> _initData() async {
    // 1. Init crypto — usually a no-op (Splash already called it); guard avoids the async round-trip.
    final cryptoState = ref.read(cryptoProvider);
    if (!cryptoState.isInitialized) {
      final cryptoNotifier = ref.read(cryptoProvider.notifier);
      await cryptoNotifier.initAndUploadKeys();
    }

    // 2. Connect WebSocket
    final wsState = ref.read(websocketProvider);
    if (!wsState.isConnected) {
      ref.read(websocketProvider.notifier).connect();
    }

    // Clean up any stale voice session from a previous run.
    _self._voiceRtcNotifier.leaveChannel();

    // 3. Load conversations AFTER crypto and WS are set up
    await ref.read(conversationsProvider.notifier).loadConversations();

    // 3b. Auto-select conversation if passed via query parameter
    if (widget.initialConversationId != null &&
        _self._selectedConversation == null) {
      final conversations = ref.read(conversationsProvider).conversations;
      final conv = conversations
          .where((c) => c.id == widget.initialConversationId)
          .firstOrNull;
      if (conv != null) {
        _selectConversation(conv, messageId: widget.initialMessageId);
      }
    }

    // 4. Load contacts for pending badge
    ref.read(contactsProvider.notifier).loadContacts();
    ref.read(contactsProvider.notifier).loadPending(force: true);
    _startPendingRefreshLoop();

    // 5. Load privacy preferences used for read-receipt/plaintext behavior.
    await ref.read(privacyProvider.notifier).load();

    // 6. Check updates — awaited so 6b sees the release-notes body. Network path bounded 10s.
    await ref.read(updateProvider.notifier).check();

    // 6b. Show What's New once per upgrade; no-op on fresh install.
    await _showWhatsNewIfNeeded();

    // 7b. Init system tray (desktop only); tray-triggered toasts need a BuildContext here.
    unawaited(
      TrayService.instance.init(onCheckForUpdates: _handleTrayCheckForUpdates),
    );

    // 7. Show first-login server notice
    await _showServerNoticeIfNeeded();

    // 8. Offer the server's welcome group on first arrival (once per device).
    await _showWelcomeGroupIfNeeded();
  }

  /// One-shot offer to join the server's configured welcome group, shown the
  /// first time a user reaches the home screen. Gated by a SharedPreferences
  /// flag so it never reappears — whether they joined or dismissed. No-ops
  /// silently when the server has no welcome group configured, when the user
  /// is already a member, or when the fetch fails (it's a nicety, not a gate).
  Future<void> _showWelcomeGroupIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool('welcome_group_offered') ?? false) return;
    if (!mounted) return;

    final group = await ref.read(featuredGroupProvider.future);
    if (group == null || group.isMember || !mounted) {
      // Still mark as offered when there's nothing to show, so we don't
      // re-hit the endpoint on every launch. (If the server adds a welcome
      // group later, existing users won't be re-prompted — acceptable: the
      // offer targets genuinely new users.)
      await prefs.setBool('welcome_group_offered', true);
      return;
    }

    await showWelcomeGroupSheet(context, group);
    await prefs.setBool('welcome_group_offered', true);
  }

  /// Handler wired into the desktop system-tray "Check for updates" menu
  /// item. Forces a re-check of the GitHub releases API (bypasses the 1h
  /// cache) and surfaces the result via toast. The pre-existing
  /// update-available banner still fires for the "new version" path; this
  /// just adds the explicit "you are on the latest version" confirmation
  /// that's otherwise invisible when a check returns nothing new.
  Future<void> _handleTrayCheckForUpdates() async {
    if (!mounted) return;
    // Dev builds short-circuit inside Update.check(); be explicit so the
    // user isn't left wondering whether the click did anything.
    if (appVersion == 'dev') {
      ToastService.show(
        context,
        'Update check skipped on dev build',
        type: ToastType.info,
      );
      return;
    }
    ToastService.show(context, 'Checking for updates...', type: ToastType.info);
    await ref.read(updateProvider.notifier).check(force: true);
    if (!mounted) return;
    final update = ref.read(updateProvider);
    if (update.updateAvailable) {
      if (update.dismissed) {
        // User dismissed the banner — explicit re-check signals they want to see it again, so toast.
        ToastService.show(
          context,
          'Update available: v${update.latestVersion}',
          type: ToastType.info,
        );
      }
      // Otherwise the persistent banner already shows the version; a toast would be redundant.
      return;
    }
    ToastService.show(
      context,
      'You are on the latest version',
      type: ToastType.success,
    );
  }

  Future<void> _showWhatsNewIfNeeded() async {
    if (!mounted) return;
    // Force AsyncNotifier.build() before reading .value (first read is AsyncLoading).
    await ref.read(releaseNotesProvider.future);
    if (!mounted) return;
    await maybeShowWhatsNew(
      context,
      ref,
      onShow: (notes) {
        if (!mounted) return;
        setState(() => _self._whatsNewNotes = notes);
      },
    );
  }

  void _startPendingRefreshLoop() {
    _self._pendingRefreshTimer?.cancel();
    _self._pendingRefreshTimer = Timer.periodic(const Duration(seconds: 30), (
      _,
    ) {
      if (!mounted) return;
      ref.read(contactsProvider.notifier).loadPending();
    });
  }

  Future<void> _showServerNoticeIfNeeded() async {
    final prefs = await SharedPreferences.getInstance();
    final seen = prefs.getBool('seen_server_notice') ?? false;
    if (seen || !mounted) return;

    final serverUrl = ref.read(serverUrlProvider);
    final displayHost = Uri.tryParse(serverUrl)?.host ?? serverUrl;

    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Welcome to Echo',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'You\'re connected to the official Echo server at $displayHost\n\n'
          'Your messages are end-to-end encrypted. The server cannot read your messages.\n\n'
          'In the future, you\'ll be able to self-host your own Echo server.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
          ),
        ),
        actions: [
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            style: FilledButton.styleFrom(
              minimumSize: const Size.fromHeight(48),
            ),
            child: const Text('Got it'),
          ),
        ],
      ),
    );

    await prefs.setBool('seen_server_notice', true);
  }
}
