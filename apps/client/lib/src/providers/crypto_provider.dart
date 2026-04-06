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
/// and key distribution via the server.
final groupCryptoServiceProvider = Provider<GroupCryptoService>((ref) {
  return GroupCryptoService(serverUrl: ref.watch(serverUrlProvider));
});

/// State for tracking crypto initialization.
class CryptoState {
  final bool isInitialized;
  final bool isUploading;
  final String? error;

  const CryptoState({
    this.isInitialized = false,
    this.isUploading = false,
    this.error,
  });

  CryptoState copyWith({
    bool? isInitialized,
    bool? isUploading,
    String? error,
  }) {
    return CryptoState(
      isInitialized: isInitialized ?? this.isInitialized,
      isUploading: isUploading ?? this.isUploading,
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
        await crypto.uploadKeys();
        DebugLogService.instance.log(
          LogLevel.info,
          'Crypto',
          'Keys uploaded to server',
        );
      }
      DebugLogService.instance.log(
        LogLevel.info,
        'Crypto',
        'Initialized successfully',
      );
      state = state.copyWith(isInitialized: true, isUploading: false);
    } on PlatformException catch (e) {
      // Linux libsecret / keyring failures -- degrade gracefully so the
      // user can still use the app without end-to-end encryption.
      debugPrint('[Crypto] PlatformException during init (degraded mode): $e');
      DebugLogService.instance.log(
        LogLevel.warning,
        'Crypto',
        'PlatformException during init (degraded mode): $e',
      );
      state = state.copyWith(isUploading: false);
    } catch (e) {
      DebugLogService.instance.log(LogLevel.error, 'Crypto', 'Init failed: $e');
      state = state.copyWith(
        isUploading: false,
        error: 'Crypto init failed: $e',
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

  // -----------------------------------------------------------------------
  // Group encryption key management
  // -----------------------------------------------------------------------

  /// Generate a new group key, upload it to the server, and cache it.
  ///
  /// Returns the new key version, or null on failure.
  Future<int?> rotateGroupKey(String conversationId) async {
    final groupCrypto = ref.read(groupCryptoServiceProvider);
    final token = ref.read(authProvider).token ?? '';
    groupCrypto.setToken(token);
    return groupCrypto.rotateGroupKey(conversationId);
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
