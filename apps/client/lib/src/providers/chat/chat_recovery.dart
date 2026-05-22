part of 'chat_provider.dart';

/// Banner-driven recovery actions for the chat notifier — the user-visible
/// surface behind the "encryption out of sync" and "[Could not verify
/// sender]" prompts plus the system-event injector used when a
/// conversation transitions (member joined, voice call started, ...).
///
/// Mixed into [Chat]. The recovery helpers reach the crypto + group-crypto
/// services through `ref`; `addSystemEvent` mutates the message list via
/// the standard `state.withMessage` codepath so dedup + decrypt-failure
/// tracking stay consistent.
mixin ChatRecoveryMixin on Notifier<ChatState> {
  /// Force-reset the 1:1 Signal session backing [conversationId] and clear
  /// the consecutive-decrypt-failure counter. Called by the "Reset Session"
  /// button on the wedged-session banner. Audit P0-3.
  ///
  /// The peer's next initial message after this call will re-establish the
  /// session via X3DH. Messages from before the reset whose keys were in
  /// the discarded skipped-key window remain undecryptable — the banner
  /// copy warns the user of this.
  Future<void> resetWedgedSession(
    String conversationId,
    String peerUserId,
  ) async {
    final crypto = ref.read(cryptoServiceProvider);
    await crypto.forceResetSession(peerUserId);
    state = state.withSyncRestored(conversationId);
  }

  /// Phase 4 recovery action for group conversations: drop the cached
  /// group key + envelope and refetch whatever the server currently
  /// advertises. Use when a wave of "[Could not decrypt - waiting for
  /// group key]" placeholders has crossed the [outOfSyncThreshold]
  /// banner threshold. No-op when the conversation isn't a group or
  /// no GroupCryptoService is wired.
  ///
  /// Self-heal path (Phase 5 follow-up): when the refetch yields
  /// nothing — typically a group that was created `is_encrypted=true`
  /// but never had a first-key upload — and the caller is an admin,
  /// the rotation endpoint accepts a first-key upload to unwedge the
  /// group. Non-admins get a 401 from the upload and the banner
  /// stays visible.
  Future<void> refreshGroupKey(String conversationId) async {
    // Clear the needs-rotation + out-of-sync flags BEFORE the fetch so
    // that if the fetch's 410 callback fires again it can re-set the
    // flag and keep the banner visible. Order matters: clear → fetch.
    state = state
        .withSyncRestored(conversationId)
        .withGroupRotationCleared(conversationId);

    final groupCrypto = ref.read(groupCryptoServiceProvider);
    await groupCrypto.dropCachedKey(conversationId);
    final fetched = await groupCrypto.getGroupKey(conversationId);
    if (fetched == null) {
      try {
        await ref
            .read(cryptoProvider.notifier)
            .seedInitialGroupKey(conversationId);
        // Pull the freshly-uploaded envelope into the cache so the
        // next outbound / inbound message succeeds without another
        // round trip.
        await groupCrypto.getGroupKey(conversationId);
      } catch (e) {
        debugPrint('[Chat] refreshGroupKey self-heal failed: $e');
      }
    }
  }

  /// Phase 4 dismissal for the GRP2 signature-failure banner. We do
  /// NOT auto-resolve sig failures (they're a security signal, not a
  /// transient) — the user explicitly acknowledges the warning.
  void dismissSignatureFailure(String conversationId) {
    state = state.withSignatureFailureCleared(conversationId);
  }

  void addSystemEvent(String conversationId, String event) {
    final existing = state.messagesForConversation(conversationId);
    if (existing.isNotEmpty) {
      final last = existing.last;
      // Avoid duplicate timeline rows when local state and WS echo race.
      if (last.fromUserId == '__system__' && last.content == event) {
        return;
      }
    }

    final msg = ChatMessage(
      id: 'system_${DateTime.now().millisecondsSinceEpoch}',
      fromUserId: '__system__',
      fromUsername: 'System',
      conversationId: conversationId,
      content: event,
      timestamp: DateTime.now().toIso8601String(),
      isMine: false,
      status: MessageStatus.sent,
    );
    state = state.withMessage(msg);
  }
}
