part of '../ws_message_handler.dart';

extension CryptoHandlersOn on WsMessageHandler {
  void _handleKeyReset(Map<String, dynamic> json) {
    final fromUserId = json['from_user_id'] as String? ?? '';
    final fromUsername = json['from_username'] as String? ?? 'Someone';
    final conversationId = json['conversation_id'] as String? ?? '';

    // (#662) Invalidate session + bundle cache so next message re-X3DHes.
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
    // num+toInt: dart2js may decode the JSON number as double, not int.
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

  /// (#656) Server-elected leader rotation; this client waits its slot in
  /// `[leader, ...fallback_order] * deadline_ms` and aborts if a peer wins.
  /// UNIQUE constraint is the safety net for split-brain / mixed-fleet.
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
      // Not in elected set; group_key_rotated broadcast will pull winning envelope.
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

      // Check if a higher-priority peer already rotated (current >= target).
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
      // Self: local pubkey; peers: force-refresh past TOFU cache.
      fetchIdentityKey: (userId) {
        if (userId == myUserId) {
          return crypto.getIdentityPublicKey();
        }
        return crypto.fetchPeerIdentityKey(userId, forceRefresh: true);
      },
      // TD-4: refuse to wrap under TOFU-changed peer key.
      hasIdentityKeyChanged: (userId) async {
        if (userId == myUserId) return false;
        return crypto.hasPeerIdentityKeyChanged(userId);
      },
    );
  }
}
