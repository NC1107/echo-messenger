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
  // `_self` is provided by `_HomeScreenActionsMixin` (the `on` clause
  // guarantees it's in scope); used throughout to reach private fields
  // declared on `_HomeScreenState`.

  Future<void> _initData() async {
    // 1. Initialize crypto (awaited -- must complete before anything else).
    // SplashScreen calls initAndUploadKeys() during auto-login, so this is
    // typically a no-op (CryptoNotifier guards against double-init internally).
    // The guard below avoids the async round-trip in the common case.
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

    // 6. Check for app updates.  Awaited so step 6b can read the
    // resulting release-notes body and decide whether to show the
    // What's New modal — without await the body isn't populated yet
    // and the modal silently skips.  Cached path is sync (≤ 1ms);
    // network path is a single 10s-timeout GET so worst-case impact
    // on home-screen first paint is bounded.
    await ref.read(updateProvider.notifier).check();

    // 6b. Show the What's New modal once per upgrade.  No-op on fresh
    // install (releaseNotesProvider bootstraps last_shown = appVersion
    // so first launch never surfaces a changelog).
    await _showWhatsNewIfNeeded();

    // 7b. Init system tray (desktop only; no-op on web/mobile). The
    // "Check for updates" menu item routes through _handleTrayCheckForUpdates
    // so the tray service stays UI-agnostic and the toast surfaces here
    // where we have a BuildContext.
    unawaited(
      TrayService.instance.init(onCheckForUpdates: _handleTrayCheckForUpdates),
    );

    // 7. Show first-login server notice
    await _showServerNoticeIfNeeded();
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
        // User previously dismissed the banner for this version; the
        // explicit re-check is their signal that they actually want to
        // see it again, so surface a toast that points back at the
        // version (the banner stays hidden until the cache rolls).
        ToastService.show(
          context,
          'Update available: v${update.latestVersion}',
          type: ToastType.info,
        );
      }
      // Otherwise the persistent update banner already shows "vX is
      // available" with Update/Download/Later actions — a transient
      // toast on top of it would be redundant noise.
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
    // Force AsyncNotifier.build() to run before reading .value — the
    // first read of an AsyncNotifierProvider returns AsyncLoading; we
    // need the resolved snapshot.
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
