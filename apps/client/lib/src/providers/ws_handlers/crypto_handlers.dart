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

  /// #656 — server signaled that a member was removed and we (or any other
  /// remaining member) should regenerate the group AES key for the new
  /// version. We race other clients; the server enforces single-writer via a
  /// UNIQUE constraint, so a 409 just means we lost the race.
  void _handleGroupKeyRotationRequested(Map<String, dynamic> json) {
    final conversationId = json['conversation_id'] as String? ?? '';
    final keyVersion = (json['key_version'] as num?)?.toInt();
    if (conversationId.isEmpty || keyVersion == null) return;

    final auth = ref.read(authProvider);
    final token = auth.token;
    if (token == null) return;

    final serverUrl = ref.read(serverUrlProvider);
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final crypto = ref.read(cryptoServiceProvider);
    groupCrypto.setToken(token);

    unawaited(
      groupCrypto.performRotation(
        conversationId,
        keyVersion,
        fetchMembers: () async {
          try {
            final resp = await http.get(
              Uri.parse('$serverUrl/api/groups/$conversationId'),
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
              'Failed to load members for $conversationId: $e',
            );
            return [];
          }
        },
        fetchIdentityKey: (userId) => crypto.fetchPeerIdentityKey(userId),
      ),
    );
  }
}
