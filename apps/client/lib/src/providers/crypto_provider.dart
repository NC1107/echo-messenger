import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/crypto_service.dart';
import '../services/debug_log_service.dart';
import '../services/group_crypto_service.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';

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
  final String? error;

  const CryptoState({
    this.isInitialized = false,
    this.isUploading = false,
    this.keysUploadFailed = false,
    this.keysWereRegenerated = false,
    this.error,
  });

  CryptoState copyWith({
    bool? isInitialized,
    bool? isUploading,
    bool? keysUploadFailed,
    bool? keysWereRegenerated,
    String? error,
  }) {
    return CryptoState(
      isInitialized: isInitialized ?? this.isInitialized,
      isUploading: isUploading ?? this.isUploading,
      keysUploadFailed: keysUploadFailed ?? this.keysUploadFailed,
      keysWereRegenerated: keysWereRegenerated ?? this.keysWereRegenerated,
      error: error,
    );
  }
}

class CryptoNotifier extends StateNotifier<CryptoState> {
  final Ref ref;

  CryptoNotifier(this.ref) : super(const CryptoState());

  /// Initialize crypto and upload keys to the server.
  ///
  /// On Linux, libsecret may fail to unlock the keyring (PlatformException).
  /// In that case crypto degrades gracefully -- the user can still chat
  /// without encryption rather than seeing a red error toast.
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
      await crypto.init();
      if (crypto.keysAreFresh) {
        try {
          await crypto.uploadKeys();
          DebugLogService.instance.log(
            LogLevel.info,
            'Crypto',
            'Keys uploaded to server',
          );
        } catch (uploadError) {
          // Key upload failed -- mark the failure but do not block the app.
          // The user can still chat (without encryption for new conversations)
          // and retry from Settings > Privacy.
          DebugLogService.instance.log(
            LogLevel.error,
            'Crypto',
            'Key upload failed (app continues without upload): $uploadError',
          );
          state = state.copyWith(
            isInitialized: true,
            isUploading: false,
            keysUploadFailed: true,
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
    } on PlatformException catch (e) {
      // Linux libsecret / keyring failures -- degrade gracefully so the
      // user can still use the app without end-to-end encryption.
      debugPrint('[Crypto] PlatformException during init (degraded mode): $e');
      DebugLogService.instance.log(
        LogLevel.warning,
        'Crypto',
        'PlatformException during init (degraded mode): $e',
      );
      state = state.copyWith(
        isUploading: false,
        error: 'Secure storage unavailable: $e',
      );
    } catch (e) {
      DebugLogService.instance.log(LogLevel.error, 'Crypto', 'Init failed: $e');
      state = state.copyWith(
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
  Future<void> resetKeys() async {
    final crypto = ref.read(cryptoServiceProvider);
    await crypto.resetAllKeys();
    state = state.copyWith(isInitialized: true);
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
  ) async {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    groupCrypto.setToken(token);
    return groupCrypto.rotateGroupKey(conversationId, members);
  }

  /// Fetch the latest group key from the server and cache it locally.
  Future<(int, String)?> fetchGroupKey(String conversationId) async {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    groupCrypto.setToken(token);
    return groupCrypto.fetchGroupKey(conversationId);
  }

  /// Invalidate cached group key so the next access re-fetches from server.
  Future<void> invalidateGroupKey(String conversationId) async {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    await groupCrypto.invalidateCache(conversationId);
  }
}

final cryptoProvider = StateNotifierProvider<CryptoNotifier, CryptoState>((
  ref,
) {
  return CryptoNotifier(ref);
});
