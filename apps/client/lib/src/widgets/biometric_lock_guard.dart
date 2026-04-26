import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../providers/auth_provider.dart';
import '../providers/biometric_provider.dart';
import '../theme/echo_theme.dart';

/// Wraps its [child] and, when biometric lock is enabled, shows a lock screen
/// after the app returns from background. On cold start the lock is shown
/// immediately if the user is already logged in.
class BiometricLockGuard extends ConsumerStatefulWidget {
  final Widget child;

  const BiometricLockGuard({super.key, required this.child});

  @override
  ConsumerState<BiometricLockGuard> createState() => _BiometricLockGuardState();
}

class _BiometricLockGuardState extends ConsumerState<BiometricLockGuard>
    with WidgetsBindingObserver {
  bool _locked = false;
  bool _promptInFlight = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    // Cold-start lock: show immediately if biometric is enabled and logged in.
    WidgetsBinding.instance.addPostFrameCallback((_) => _maybeShowLock());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState lifecycleState) {
    if (lifecycleState == AppLifecycleState.resumed) {
      _maybeShowLock();
    }
  }

  void _maybeShowLock() {
    final biometric = ref.read(biometricProvider);
    final auth = ref.read(authProvider);
    if (!biometric.enabled || !auth.isLoggedIn || biometric.isLoading) return;
    if (_locked || _promptInFlight) return;
    if (ref.read(biometricProvider.notifier).isSessionValid) return;

    setState(() => _locked = true);
    _promptUnlock();
  }

  Future<void> _promptUnlock() async {
    if (_promptInFlight) return;
    _promptInFlight = true;
    try {
      final ok = await ref.read(biometricProvider.notifier).authenticate();
      if (!mounted) return;
      if (ok) {
        setState(() => _locked = false);
      }
      // If not ok, stay locked — user can retry via the button.
    } finally {
      if (mounted) _promptInFlight = false;
    }
  }

  @override
  Widget build(BuildContext context) {
    // Watch biometric so we react if it gets disabled from settings.
    final biometric = ref.watch(biometricProvider);
    if (!biometric.enabled) {
      _locked = false;
    }

    if (!_locked) return widget.child;

    return Scaffold(
      backgroundColor: context.mainBg,
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.lock_rounded, size: 64, color: context.accent),
            const SizedBox(height: 24),
            Text(
              'Echo is locked',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 22,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Authenticate to continue',
              style: TextStyle(color: context.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 32),
            FilledButton.icon(
              onPressed: _promptInFlight ? null : _promptUnlock,
              icon: const Icon(Icons.fingerprint, size: 20),
              label: const Text('Unlock'),
              style: FilledButton.styleFrom(
                backgroundColor: context.accent,
                padding: const EdgeInsets.symmetric(
                  horizontal: 32,
                  vertical: 14,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
