import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../services/crypto_service.dart';
import 'auth_provider.dart';
import 'server_url_provider.dart';

/// Provider for the CryptoService singleton.
///
/// Initialized after login/register, used by the websocket provider
/// to encrypt outgoing and decrypt incoming messages.
final cryptoServiceProvider = Provider<CryptoService>((ref) {
  return CryptoService(serverUrl: ref.watch(serverUrlProvider));
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
      }
      state = state.copyWith(isInitialized: true, isUploading: false);
    } catch (e) {
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
    state = const CryptoState();
  }
}

final cryptoProvider = StateNotifierProvider<CryptoNotifier, CryptoState>((
  ref,
) {
  return CryptoNotifier(ref);
});
