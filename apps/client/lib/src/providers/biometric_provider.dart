import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:local_auth/local_auth.dart';
import 'package:shared_preferences/shared_preferences.dart';

const _kBiometricLockKey = 'biometric_lock_enabled';

class BiometricState {
  final bool enabled;
  final bool isAvailable;
  final bool isLoading;

  const BiometricState({
    this.enabled = false,
    this.isAvailable = false,
    this.isLoading = true,
  });

  BiometricState copyWith({bool? enabled, bool? isAvailable, bool? isLoading}) {
    return BiometricState(
      enabled: enabled ?? this.enabled,
      isAvailable: isAvailable ?? this.isAvailable,
      isLoading: isLoading ?? this.isLoading,
    );
  }
}

class BiometricNotifier extends StateNotifier<BiometricState> {
  BiometricNotifier() : super(const BiometricState()) {
    _init();
  }

  /// Named constructor for tests: sets initial state without running [_init].
  @visibleForTesting
  BiometricNotifier.forTest(super.initial);

  final _auth = LocalAuthentication();

  Future<void> _init() async {
    try {
      final available = await _auth.isDeviceSupported();
      final canCheck = await _auth.canCheckBiometrics;
      final isAvailable = available && canCheck;

      final prefs = await SharedPreferences.getInstance();
      final enabled = prefs.getBool(_kBiometricLockKey) ?? false;

      state = state.copyWith(
        enabled: enabled && isAvailable,
        isAvailable: isAvailable,
        isLoading: false,
      );
    } catch (e) {
      debugPrint('[Biometric] init failed: $e');
      state = state.copyWith(isAvailable: false, isLoading: false);
    }
  }

  Future<void> setEnabled(bool value) async {
    if (value && !state.isAvailable) return;

    if (value) {
      // Confirm biometrics work before enabling
      final authenticated = await authenticate();
      if (!authenticated) return;
    }

    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kBiometricLockKey, value);
    state = state.copyWith(enabled: value);
  }

  /// Prompts the user to authenticate. Returns true on success.
  Future<bool> authenticate() async {
    if (!state.isAvailable) return true;
    try {
      return await _auth.authenticate(
        localizedReason: 'Unlock Echo',
        options: const AuthenticationOptions(
          stickyAuth: true,
          biometricOnly: false,
        ),
      );
    } catch (e) {
      debugPrint('[Biometric] authenticate failed: $e');
      return false;
    }
  }
}

final biometricProvider =
    StateNotifierProvider<BiometricNotifier, BiometricState>(
      (_) => BiometricNotifier(),
    );
