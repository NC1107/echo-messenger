part of '../ws_message_handler.dart';

extension CryptoHandlersOn on WsMessageHandler {
  void _handleKeyReset(Map<String, dynamic> json) {
    final fromUserId = json['from_user_id'] as String? ?? '';
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';

    // Invalidate the local session so the next message re-establishes X3DH.
    // Also drop any cached prekey bundles so the next outgoing message
    // re-fetches against the freshly-rotated keys (#662).
    final crypto = ref.read(cryptoServiceProvider);
    crypto.invalidateSessionKey(fromUserId);
    if (fromUserId.isNotEmpty) {
      crypto.invalidateBundleCache(fromUserId);
    }

    ref
        .read(chatProvider.notifier)
        .addSystemEvent(
          conversationId,
          '$fromUsername reset their encryption keys',
        );
  }

  /// Server emits `identity_reset` after a /api/keys/reset or
  /// /api/keys/reset_device. Drop the bundle cache for the affected user so
  /// the next encrypt-for-peer round fetches the new identity keys (#664).
  void _handleIdentityReset(Map<String, dynamic> json) {
    final fromUserId =
        json['user_id'] as String? ?? json['from_user_id'] as String? ?? '';
    if (fromUserId.isEmpty) return;
    ref.read(cryptoServiceProvider).invalidateBundleCache(fromUserId);
  }

  void _handleSessionReplaced(Map<String, dynamic> json) {
    final reason = json['reason'] as String? ?? 'Signed in on another device';
    DebugLogService.instance.log(
      LogLevel.warning,
      'WebSocket',
      'Session replaced by another connection: $reason',
    );
    // Clear pending messages to prevent leaking other-user ciphertext
    clearPendingDecryptQueue();
    _state = _state.copyWith(wasReplaced: true, isConnected: false);
  }

  void _handleDeviceRevoked(Map<String, dynamic> json) {
    // Use `num?` + toInt() so dart2js (web) doesn't blow up when the JSON
    // number is decoded as a double rather than an int.
    final revokedDeviceId = (json['device_id'] as num?)?.toInt();
    final myDeviceId = ref.read(cryptoServiceProvider).isInitialized
        ? ref.read(cryptoServiceProvider).deviceId
        : null;

    // Always broadcast so interested UIs (Devices settings) can refresh.
    deviceRevokedController.add(json);

    if (revokedDeviceId != null &&
        myDeviceId != null &&
        revokedDeviceId == myDeviceId) {
      // This device was revoked -- force logout.
      DebugLogService.instance.log(
        LogLevel.warning,
        'WebSocket',
        'Current device ($revokedDeviceId) was revoked; logging out.',
      );
      // Clear pending messages before logout
      clearPendingDecryptQueue();
      _state = _state.copyWith(isConnected: false);
      ref.read(authProvider.notifier).logout();
    }
  }

  /// Handle group key rotation event -- invalidate cached key so the next
  /// encrypt/decrypt fetches the fresh version from the server.
  void _handleGroupKeyRotated(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String? ?? '';
    if (conversationId.isEmpty) return;

    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    groupCrypto.setToken(token);
    groupCrypto.invalidateCache(conversationId);

    // Pre-fetch the new key so subsequent messages decrypt immediately.
    groupCrypto.fetchGroupKey(conversationId);
  }

  /// #656 — server signalled that a member was removed and the surviving
  /// members need to regenerate the group AES key for the bumped version.
  ///
  /// Phase 3b adds a server-elected leader on top of the underlying
  /// UNIQUE-constraint race. The event carries `leader_user_id` plus an
  /// ordered `fallback_order` and a `deadline_ms` hint; the local client
  /// uses its own position in `[leader, ...fallback_order]` to delay its
  /// attempt. The leader fires immediately; each fallback waits one
  /// `deadline_ms` per slot, re-checks whether the new version has
  /// already arrived (via the cache populated by `group_key_rotated`),
  /// and only then attempts to upload. The UNIQUE constraint remains the
  /// safety net for any split-brain / pre-Phase-3b mixed-fleet case.
  void _handleGroupKeyRotationRequested(Map<String, dynamic> json) {
    final request = parseRotationRequested(json);
    if (request == null) return;

    final auth = ref.read(authProvider);
    final token = auth.token;
    final myUserId = auth.userId ?? '';
    if (token == null) return;

    final delay = rotationAttemptDelay(
      leaderUserId: request.leaderUserId,
      fallbackOrder: request.fallbackOrder,
      deadlineMs: request.deadlineMs,
      myUserId: myUserId,
    );

    if (delay == null) {
      // Server did not see us as online when it elected the leader.
      // Stay out of the fallback queue; the broadcast `group_key_rotated`
      // event (or our next getGroupKey) will pull the winning envelope
      // once any elected member completes the rotation.
      DebugLogService.instance.log(
        LogLevel.info,
        'GroupRotation',
        '${request.conversationId} v${request.keyVersion}: not in elected '
            'leader/fallback set; deferring to server broadcast.',
      );
      return;
    }

    unawaited(_runLeaderAwareRotation(request, delay, token, myUserId));
  }

  Future<void> _runLeaderAwareRotation(
    RotationRequest request,
    Duration delay,
    String token,
    String myUserId,
  ) async {
    final serverUrl = ref.read(serverUrlProvider);
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final crypto = ref.read(cryptoServiceProvider);
    groupCrypto.setToken(token);

    if (delay > Duration.zero) {
      DebugLogService.instance.log(
        LogLevel.info,
        'GroupRotation',
        '${request.conversationId} v${request.keyVersion}: waiting '
            '${delay.inMilliseconds}ms before rotation attempt '
            '(leader=${request.leaderUserId}, my position in fallback='
            '${request.fallbackOrder.indexOf(myUserId)}).',
      );
      await Future<void>.delayed(delay);

      // After the wait, check whether someone earlier in the priority
      // list already completed the rotation. The `group_key_rotated`
      // broadcast invalidates our cache and pre-fetches the new
      // envelope, so a successful peer rotation surfaces here as a
      // current version >= the requested version.
      final current = await groupCrypto.getGroupKey(request.conversationId);
      final currentVersion = current?.$1;
      if (shouldAbortRotation(
        currentVersion: currentVersion,
        targetVersion: request.keyVersion,
      )) {
        DebugLogService.instance.log(
          LogLevel.info,
          'GroupRotation',
          '${request.conversationId} v${request.keyVersion}: aborting — '
              'peer already completed rotation (current=v$currentVersion).',
        );
        return;
      }
    }

    await groupCrypto.performRotation(
      request.conversationId,
      request.keyVersion,
      selfUserId: myUserId,
      fetchMembers: () async {
        try {
          final resp = await http.get(
            Uri.parse('$serverUrl/api/groups/${request.conversationId}'),
            headers: {'Authorization': 'Bearer $token'},
          );
          if (resp.statusCode != 200) return [];
          final body = jsonDecode(resp.body) as Map<String, dynamic>;
          final members = body['members'] as List<dynamic>? ?? [];
          return members
              .whereType<Map<String, dynamic>>()
              .map((m) => {'user_id': m['user_id'] as String? ?? ''})
              .toList();
        } catch (e) {
          DebugLogService.instance.log(
            LogLevel.warning,
            'GroupRotation',
            'Failed to load members for ${request.conversationId}: $e',
          );
          return [];
        }
      },
      // Self-wrap uses the local pubkey so we can always unwrap our
      // own envelope; peer wraps bypass the TOFU cache so we use the
      // recipient's current server-known identity rather than a
      // stale entry from a previous account session. See
      // seedInitialGroupKey for the longer rationale.
      fetchIdentityKey: (userId) {
        if (userId == myUserId) {
          return crypto.getIdentityPublicKey();
        }
        return crypto.fetchPeerIdentityKey(userId, forceRefresh: true);
      },
      // TD-4: same TOFU-bypass guard as seedInitialGroupKey. If any
      // peer's identity key changed on the most recent refresh,
      // refuse to wrap the new group key under it.
      hasIdentityKeyChanged: (userId) async {
        if (userId == myUserId) return false;
        return crypto.hasPeerIdentityKeyChanged(userId);
      },
    );
  }
}
