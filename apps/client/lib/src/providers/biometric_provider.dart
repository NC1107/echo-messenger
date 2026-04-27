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

  bool _authenticatedThisSession = false;
  DateTime? _lastAuthTime;
  static const _lockTimeout = Duration(minutes: 5);

  /// True when the user authenticated recently and the lock timeout has not expired.
  bool get isSessionValid {
    if (!_authenticatedThisSession || _lastAuthTime == null) return false;
    return DateTime.now().difference(_lastAuthTime!) < _lockTimeout;
  }

  Future<void> _init() async {
    // local_auth has no web implementation -- skip entirely on web.
    if (kIsWeb) {
      state = state.copyWith(isAvailable: false, isLoading: false);
      return;
    }
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
  /// Skips the prompt when called within [_lockTimeout] of the last successful auth.
  Future<bool> authenticate() async {
    if (!state.isAvailable) return true;
    if (isSessionValid) return true;
    try {
      final ok = await _auth.authenticate(localizedReason: 'Unlock Echo');
      if (ok) {
        _authenticatedThisSession = true;
        _lastAuthTime = DateTime.now();
      }
      return ok;
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
