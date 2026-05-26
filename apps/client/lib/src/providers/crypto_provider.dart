import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:riverpod_annotation/riverpod_annotation.dart';

import '../services/crypto_service.dart';
import '../services/debug_log_service.dart';
import '../services/group_crypto_service.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';
import 'websocket_provider.dart';

part 'crypto_provider.g.dart';

/// Provider for the CryptoService singleton.
///
/// Initialized after login/register, used by the websocket provider
/// to encrypt outgoing and decrypt incoming messages.
final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService(serverUrl: ref.watch(serverUrlProvider));
});

/// Provider for the GroupCryptoService singleton.
///
/// Handles AES-256-GCM group encryption: key generation, encrypt/decrypt,
/// and per-member envelope-based key distribution via the server.
final groupCryptoServiceProvider = Provider<GroupCryptoService>((ref) {
  final service = GroupCryptoService(serverUrl: ref.watch(serverUrlProvider));
  service.setCryptoService(ref.watch(cryptoServiceProvider));
  return service;
});

/// State for tracking crypto initialization.
class CryptoState {
  final bool isInitialized;
  final bool isUploading;
  final bool keysUploadFailed;
  final bool keysWereRegenerated;

  /// True when the platform secure-storage backend is currently unavailable
  /// (libsecret keyring locked, macOS Keychain prompt denied, etc.). Distinct
  /// from `keysWereRegenerated`: the keys are presumed to exist on disk; we
  /// just can't read them right now. UI surfaces a "Echo can't read its
  /// encryption keys. Unlock your system keyring and tap Retry." banner.
  /// Audit P0-1.
  final bool secureStorageUnavailable;

  final String? error;

  const CryptoState({
    this.isInitialized = false,
    this.isUploading = false,
    this.keysUploadFailed = false,
    this.keysWereRegenerated = false,
    this.secureStorageUnavailable = false,
    this.error,
  });

  CryptoState copyWith({
    bool? isInitialized,
    bool? isUploading,
    bool? keysUploadFailed,
    bool? keysWereRegenerated,
    bool? secureStorageUnavailable,
    String? error,
  }) {
    return CryptoState(
      isInitialized: isInitialized ?? this.isInitialized,
      isUploading: isUploading ?? this.isUploading,
      keysUploadFailed: keysUploadFailed ?? this.keysUploadFailed,
      keysWereRegenerated: keysWereRegenerated ?? this.keysWereRegenerated,
      secureStorageUnavailable:
          secureStorageUnavailable ?? this.secureStorageUnavailable,
      error: error,
    );
  }
}

/// Migrated from `StateNotifier` to `@riverpod`-annotated `Notifier`
/// (audit 2026-05-14, Riverpod modernization slice — #770). The exported
/// provider symbol `cryptoProvider` is preserved via the auto-generated
/// `cryptoNotifierProvider` aliased below so the ~30 existing call sites do
/// not change.
@Riverpod(keepAlive: true)
class CryptoNotifier extends _$CryptoNotifier {
  /// Per-conversation single-flight to prevent rotation-storm (audit P2);
  /// concurrent admins/self-heal would fan out to A×(N+2) parallel HTTP POSTs.
  final Set<String> _rotatingGroups = <String>{};

  @override
  CryptoState build() {
    return const CryptoState();
  }

  /// Mark secure storage as unavailable (audit P0-1). Idempotent — only
  /// updates state when the flag flips so widget rebuilds stay minimal.
  void _markSecureStorageUnavailable() {
    if (state.secureStorageUnavailable) return;
    DebugLogService.instance.log(
      LogLevel.warning,
      'Crypto',
      'Secure storage unavailable — surfacing banner',
    );
    state = state.copyWith(secureStorageUnavailable: true);
  }

  /// Mark the OTP-heal upload as having exhausted its retries (audit P0-2).
  /// Idempotent.
  void _markKeyUploadTerminalFailure() {
    if (state.keysUploadFailed) return;
    DebugLogService.instance.log(
      LogLevel.error,
      'Crypto',
      'OTP-heal upload exhausted retries — surfacing settings banner',
    );
    state = state.copyWith(keysUploadFailed: true);
  }

  /// Clear the secureStorageUnavailable flag and force a session-storage
  /// retry. Called by the "Retry" button in the keyring-locked banner.
  /// Audit P0-1.
  Future<void> retryStorageUnlock() async {
    if (!state.secureStorageUnavailable) return;
    state = state.copyWith(secureStorageUnavailable: false);
    // Drain pending so retry either succeeds or re-flips the flag immediately.
    final myUserId = ref.read(authProvider).userId ?? '';
    if (myUserId.isNotEmpty) {
      ref.read(websocketProvider.notifier).drainPendingDecryptQueue(myUserId);
    }
  }

  /// Attempt key upload with one automatic retry.
  /// Returns the error string on final failure, or null on success.
  Future<String?> _uploadKeysWithRetry(CryptoService crypto) async {
    for (var attempt = 1; attempt <= 2; attempt++) {
      try {
        await crypto.uploadKeys();
        DebugLogService.instance.log(
          LogLevel.info,
          'Crypto',
          'Keys uploaded to server (attempt $attempt)',
        );
        return null;
      } catch (uploadError) {
        final errorStr = uploadError.toString();
        DebugLogService.instance.log(
          LogLevel.error,
          'Crypto',
          'Key upload attempt $attempt failed: $uploadError',
        );
        // (#664) Skip retry on rate limit / identity conflict — same error repeats.
        if (uploadError is IdentityKeyConflictException ||
            errorStr.contains('429') ||
            errorStr.contains('409')) {
          return errorStr;
        }
        if (attempt == 2) return errorStr;
        await Future<void>.delayed(Duration(seconds: attempt * 2));
      }
    }
    return null; // unreachable
  }

  /// Initialize crypto and upload keys to the server.
  ///
  /// On Linux, libsecret may fail to unlock the keyring (PlatformException).
  /// When this happens DM sending is blocked (the send button is disabled)
  /// and a degradation banner is shown so the user can retry.
  Future<void> initAndUploadKeys() async {
    if (state.isInitialized) return;

    state = state.copyWith(isUploading: true, error: null);
    try {
      final token = ref.read(authProvider).token;
      if (token == null || token.isEmpty) {
        state = state.copyWith(
          isUploading: false,
          error: 'No auth token available',
        );
        return;
      }

      final crypto = ref.read(cryptoServiceProvider);
      crypto.setToken(token);
      // Audit P0-1/P0-2: surface keyring + upload-heal failures as UI banners.
      crypto.setObservers(
        onSecureStorageUnavailable: _markSecureStorageUnavailable,
        onKeyUploadTerminalFailure: _markKeyUploadTerminalFailure,
      );
      await crypto.init();
      if (crypto.keysAreFresh) {
        final uploadError = await _uploadKeysWithRetry(crypto);
        if (uploadError != null) {
          // Local keys OK but upload failed: mark initialized so inbound still
          // decrypts; keysUploadFailed blocks outbound + shows banner.
          state = state.copyWith(
            isInitialized: true,
            isUploading: false,
            keysUploadFailed: true,
            error: 'Key upload failed: $uploadError',
          );
          return;
        }
      }
      final regenerated = crypto.keysWereRegenerated;
      if (regenerated) {
        DebugLogService.instance.log(
          LogLevel.warning,
          'Crypto',
          'Encryption keys were regenerated. Previous encrypted messages '
              'cannot be decrypted.',
        );
      } else {
        DebugLogService.instance.log(
          LogLevel.info,
          'Crypto',
          'Initialized successfully',
        );
      }
      state = state.copyWith(
        isInitialized: true,
        isUploading: false,
        keysUploadFailed: false,
        keysWereRegenerated: regenerated,
      );

      // Decrypt any messages that arrived before crypto was ready
      final myUserId = ref.read(authProvider).userId ?? '';
      ref.read(websocketProvider.notifier).drainPendingDecryptQueue(myUserId);
    } on PlatformException catch (e) {
      // Keyring failure: mark NOT initialized so callers don't send plaintext.
      debugPrint('[Crypto] PlatformException during init: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Crypto',
        'Secure storage unavailable — encryption disabled: $e',
      );
      state = state.copyWith(
        isInitialized: false,
        isUploading: false,
        error:
            'Encryption unavailable: secure storage failed. '
            'Messages cannot be sent until this is resolved.',
      );
    } catch (e) {
      DebugLogService.instance.log(LogLevel.error, 'Crypto', 'Init failed: $e');
      state = state.copyWith(
        isInitialized: false,
        isUploading: false,
        error: 'Crypto init failed: $e',
      );
    }
  }

  /// Retry uploading encryption keys to the server.
  ///
  /// Called from the privacy settings screen when a previous upload failed.
  Future<void> retryKeyUpload() async {
    if (!state.isInitialized) return;

    state = state.copyWith(isUploading: true);
    try {
      final token = ref.read(authProvider).token;
      if (token == null || token.isEmpty) {
        state = state.copyWith(
          isUploading: false,
          error: 'No auth token available',
        );
        return;
      }

      final crypto = ref.read(cryptoServiceProvider);
      crypto.setToken(token);
      await crypto.uploadKeys();
      DebugLogService.instance.log(
        LogLevel.info,
        'Crypto',
        'Keys re-uploaded successfully',
      );
      state = state.copyWith(
        isUploading: false,
        keysUploadFailed: false,
        error: null,
      );
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        'Crypto',
        'Key re-upload failed: $e',
      );
      state = state.copyWith(
        isUploading: false,
        keysUploadFailed: true,
        error: 'Key upload failed: $e',
      );
    }
  }

  /// Reset all encryption keys (regenerate identity + session keys).
  /// Requires [password] for server-side re-authentication.
  Future<void> resetKeys(String password) async {
    try {
      final crypto = ref.read(cryptoServiceProvider);
      await crypto.resetAllKeys(password);
      state = state.copyWith(
        isInitialized: true,
        keysUploadFailed: false,
        error: null,
      );
    } catch (e) {
      DebugLogService.instance.log(
        LogLevel.error,
        'Crypto',
        'Key reset failed: $e',
      );
      state = state.copyWith(
        keysUploadFailed: true,
        error: 'Key reset failed: $e',
      );
    }
  }

  /// Clear crypto state on logout.
  Future<void> clear() async {
    final crypto = ref.read(cryptoServiceProvider);
    await crypto.clearKeys();
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    await groupCrypto.clearAll();
    state = const CryptoState();
  }

  /// Reset in-memory crypto state on logout without deleting stored keys.
  ///
  /// Resets [CryptoState] to its initial state (including setting
  /// [CryptoState.isInitialized] to false) and clears all in-memory key
  /// material (key pairs, sessions).  Stored identity and session keys are
  /// intentionally preserved so that [initAndUploadKeys()] can reload them on
  /// the next login — avoiding the key-loss bug where deletion of stored keys
  /// caused [init()] to regenerate a new identity and make all prior encrypted
  /// messages permanently unreadable.
  ///
  /// The Riverpod state is reset synchronously before any async work so that
  /// callers that do not await this future (e.g. fire-and-forget logout paths)
  /// still see [CryptoState.isInitialized] == false immediately.
  ///
  /// Group key caches are cleared asynchronously (they are short-lived and
  /// will be re-fetched from the server on the next login).
  Future<void> resetState() async {
    // Reset synchronously first so the guard in initAndUploadKeys() sees the
    // correct state immediately, even before the async cleanup below finishes.
    final crypto = ref.read(cryptoServiceProvider);
    crypto.clearInMemoryState();
    state = const CryptoState();
    // Async cleanup: remove cached group keys from secure storage.
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    await groupCrypto.clearAll();
  }

  // -----------------------------------------------------------------------
  // Group encryption key management
  // -----------------------------------------------------------------------

  /// Generate a new group key, encrypt it for each member, and upload
  /// per-member envelopes to the server.
  ///
  /// [members] is a list of `{'user_id': String, 'identity_key': String?}`
  /// maps. Members without an identity key are skipped.
  ///
  /// Returns the new key version, or null on failure.
  Future<int?> rotateGroupKey(
    String conversationId,
    List<Map<String, dynamic>> members,
  ) {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    groupCrypto.setToken(token);
    return groupCrypto.rotateGroupKey(conversationId, members);
  }

  /// Fetch the latest group key from the server and cache it locally.
  Future<(int, String)?> fetchGroupKey(String conversationId) {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    groupCrypto.setToken(token);
    return groupCrypto.fetchGroupKey(conversationId);
  }

  /// Seed the first group key for a freshly-created encrypted group.
  ///
  /// Phase 5 (audit OQ-3) made `is_encrypted = true` the server-side
  /// default for new groups. Without an explicit "first key" upload
  /// the group lands in a wedged state — the server reports 400 on
  /// `GET /api/groups/:id/keys/latest` because no envelope exists,
  /// and clients can't encrypt outbound messages. This helper closes
  /// the gap: pull the live member roster + identity keys and POST a
  /// version-1 envelope set tagged `first_key` so the audit log
  /// records the reason.
  ///
  /// Idempotent against the server's UNIQUE constraint on
  /// `(conversation_id, key_version)` — a parallel client racing on
  /// the same group will get 409 and short-circuit.
  Future<int?> seedInitialGroupKey(
    String conversationId, {
    int? currentVersion,
  }) async {
    // Single-flight per conversation (rotation-storm guard). Losers return
    // null and rely on group_key_rotated WS to populate the cache.
    if (_rotatingGroups.contains(conversationId)) {
      DebugLogService.instance.log(
        LogLevel.info,
        'GroupRotation',
        'seedInitialGroupKey: rotation already in flight for '
            '$conversationId — skipping',
      );
      return null;
    }
    _rotatingGroups.add(conversationId);
    try {
      return await _seedInitialGroupKeyInner(
        conversationId,
        currentVersion: currentVersion,
      );
    } finally {
      _rotatingGroups.remove(conversationId);
    }
  }

  Future<int?> _seedInitialGroupKeyInner(
    String conversationId, {
    int? currentVersion,
  }) async {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final crypto = ref.read(cryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    final myUserId = ref.read(authProvider).userId ?? '';
    if (token.isEmpty) return null;
    groupCrypto.setToken(token);

    final serverUrl = ref.read(serverUrlProvider);

    // TD-6: probe /keys/latest so we rotate to version+1 instead of 409ing on
    // hardcoded v=1 — leaves the group wedged forever otherwise.
    var nextVersion = 1;
    if (currentVersion != null) {
      nextVersion = currentVersion + 1;
    } else {
      try {
        final probe = await http.get(
          Uri.parse('$serverUrl/api/groups/$conversationId/keys/latest'),
          headers: {'Authorization': 'Bearer $token'},
        );
        if (probe.statusCode == 200) {
          final body = jsonDecode(probe.body) as Map<String, dynamic>;
          final existing = body['key_version'] as int?;
          if (existing != null) nextVersion = existing + 1;
        } else if (probe.statusCode == 401 || probe.statusCode == 403) {
          // TD-18: rotation would also be rejected — let WS event retry on auth.
          DebugLogService.instance.log(
            LogLevel.warning,
            'GroupRotation',
            'seedInitialGroupKey: /keys/latest probe returned '
                '${probe.statusCode} for $conversationId — aborting '
                'rotation (auth path will retry).',
          );
          return null;
        }
        // 404 (no key yet) falls through with nextVersion == 1.
      } catch (e) {
        // TD-18: fall through to v=1 for brand-new-group; log for post-mortem.
        DebugLogService.instance.log(
          LogLevel.warning,
          'GroupRotation',
          'seedInitialGroupKey: /keys/latest probe failed for '
              '$conversationId — falling through to v=1: $e',
        );
      }
    }

    return groupCrypto.performRotation(
      conversationId,
      nextVersion,
      selfUserId: myUserId,
      triggeredByEvent: nextVersion == 1 ? 'first_key' : 'recover_wedged',
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
            'seedInitialGroupKey: member fetch failed for '
                '$conversationId: $e',
          );
          return [];
        }
      },
      // Self: use local pubkey (only one guaranteed to unwrap via our private).
      // Peers: force-refresh so we wrap under their current server-uploaded key.
      fetchIdentityKey: (userId) {
        if (userId == myUserId) {
          return crypto.getIdentityPublicKey();
        }
        return crypto.fetchPeerIdentityKey(userId, forceRefresh: true);
      },
      // TD-4: refuse to wrap under an unconfirmed TOFU-changed peer key.
      hasIdentityKeyChanged: (userId) async {
        if (userId == myUserId) return false;
        return crypto.hasPeerIdentityKeyChanged(userId);
      },
    );
  }

  /// Invalidate cached group key so the next access re-fetches from server.
  Future<void> invalidateGroupKey(String conversationId) async {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    await groupCrypto.invalidateCache(conversationId);
  }

  // -----------------------------------------------------------------------
  // TOFU identity key change detection
  // -----------------------------------------------------------------------

  /// Check whether a peer's identity key has changed since first contact.
  Future<bool> hasPeerIdentityKeyChanged(String peerUserId) {
    final crypto = ref.read(cryptoServiceProvider);
    return crypto.hasPeerIdentityKeyChanged(peerUserId);
  }

  /// Acknowledge a peer identity key change (clears the persisted flag).
  Future<void> acknowledgePeerIdentityKeyChange(String peerUserId) async {
    final crypto = ref.read(cryptoServiceProvider);
    await crypto.acknowledgePeerIdentityKeyChange(peerUserId);
  }

  /// Explicitly trust the peer's new identity key, drop the old session,
  /// and clear the change flag. The next outbound message will trigger a
  /// fresh X3DH against the trusted key.
  Future<void> acceptIdentityKeyChange(
    String peerUserId, {
    String? newIdentityKeyB64,
  }) async {
    final crypto = ref.read(cryptoServiceProvider);
    await crypto.acceptIdentityKeyChange(
      peerUserId,
      newIdentityKeyB64: newIdentityKeyB64,
    );
  }

  /// Compute the safety-number fingerprint for [peerUserId], or `null`
  /// if either identity key is unavailable.
  Future<String?> safetyNumberFor(String peerUserId) {
    final crypto = ref.read(cryptoServiceProvider);
    return crypto.safetyNumberFor(peerUserId);
  }

  // -----------------------------------------------------------------------
  // Quarantined session recovery
  // -----------------------------------------------------------------------

  /// Whether [peerUserId]'s session was quarantined due to repeated decrypt
  /// failures. When true the caller should surface a recovery banner.
  bool hasCorruptedSession(String peerUserId) {
    final crypto = ref.read(cryptoServiceProvider);
    return crypto.hasCorruptedSession(peerUserId);
  }

  /// Force-clear the quarantined session for [peerUserId] so that the next
  /// outbound message triggers a fresh X3DH exchange.
  Future<void> forceResetSession(String peerUserId) async {
    final crypto = ref.read(cryptoServiceProvider);
    await crypto.forceResetSession(peerUserId);
  }
}

/// Back-compat alias preserving the legacy `cryptoProvider` symbol used by
/// ~30 call sites. Riverpod codegen names the provider after the notifier
/// class (`cryptoNotifierProvider`); we re-export the short name here.
final cryptoProvider = cryptoNotifierProvider;
