import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_provider.dart';
import '../providers/conversations_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/server_url_provider.dart';
import '../providers/update_provider.dart';
import '../providers/websocket_provider.dart';
import '../services/push_token_service.dart';
import '../router/app_router.dart' show pendingDeepLink;
import '../screens/onboarding_wizard.dart' show kOnboardingCompletedKey;
import '../theme/echo_theme.dart';
import '../widgets/echo_logo_icon.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;

  @override
  void initState() {
    super.initState();

    _fadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 600),
    );
    _fadeAnimation = CurvedAnimation(
      parent: _fadeController,
      curve: Curves.easeIn,
    );
    _fadeController.forward();

    WidgetsBinding.instance.addPostFrameCallback((_) => _init());
  }

  @override
  void dispose() {
    _fadeController.dispose();
    super.dispose();
  }

  Future<void> _init() async {
    final stopwatch = Stopwatch()..start();

    final loggedIn = await _attemptAutoLogin();

    // Pre-load conversations so home screen doesn't flash empty state
    if (loggedIn) {
      try {
        await ref
            .read(conversationsProvider.notifier)
            .loadConversations()
            .timeout(const Duration(seconds: 3), onTimeout: () {});
      } catch (_) {
        // Non-fatal; home screen will retry.
      }
    }

    // Brief splash to let the logo animation complete
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    if (elapsed < 800) {
      await Future<void>.delayed(Duration(milliseconds: 800 - elapsed));
    }

    if (!mounted) return;
    _navigateAfterInit(loggedIn);
  }

  /// Try auto-login from stored credentials (with timeout), then attempt
  /// CI env var login as fallback. Triggers crypto init and push token
  /// registration on success. Returns whether the user is logged in.
  Future<bool> _attemptAutoLogin() async {
    final auth = ref.read(authProvider.notifier);
    var loggedIn = false;
    try {
      loggedIn = await auth.tryAutoLogin().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      // Network error -- treat as not logged in.
    }

    if (loggedIn) {
      await _initCryptoAndPush();
    }

    // Support compile-time env vars for CI/testing
    if (!loggedIn && !kIsWeb) {
      loggedIn = await _attemptEnvLogin(auth);
    }

    // Check for updates on non-web platforms
    if (!kIsWeb) {
      ref.read(updateProvider.notifier).check();
    }

    return loggedIn;
  }

  /// Initialize crypto keys and register push token after login.
  Future<void> _initCryptoAndPush() async {
    await ref.read(cryptoProvider.notifier).initAndUploadKeys();

    final authState = ref.read(authProvider);
    PushTokenService.instance.init(
      serverUrl: ref.read(serverUrlProvider),
      authToken: authState.token ?? '',
      onWake: () => ref.read(websocketProvider.notifier).connect(),
    );
  }

  /// Attempt login using compile-time environment variables (CI/testing).
  Future<bool> _attemptEnvLogin(AuthNotifier auth) async {
    const envUser = String.fromEnvironment('ECHO_USERNAME');
    const envPass = String.fromEnvironment('ECHO_PASSWORD');
    if (envUser.isEmpty || envPass.isEmpty) return false;

    await auth.login(envUser, envPass);
    if (ref.read(authProvider).isLoggedIn) {
      await ref.read(cryptoProvider.notifier).initAndUploadKeys();
      return true;
    }
    return false;
  }

  /// Navigate to the appropriate screen after init completes.
  void _navigateAfterInit(bool loggedIn) {
    final isLoggedIn = ref.read(authProvider).isLoggedIn;

    if (isLoggedIn && pendingDeepLink != null) {
      final destination = pendingDeepLink!;
      pendingDeepLink = null;
      context.go(destination);
      return;
    }

    if (isLoggedIn) {
      _navigateHome();
      return;
    }

    context.go('/login');
  }

  /// Navigate home, setting onboarding flag and showing crypto notice.
  Future<void> _navigateHome() async {
    final prefs = await SharedPreferences.getInstance();
    if (prefs.getBool(kOnboardingCompletedKey) != true) {
      await prefs.setBool(kOnboardingCompletedKey, true);
    }
    if (!mounted) return;
    context.go('/home');

    final cryptoState = ref.read(cryptoProvider);
    if (cryptoState.keysWereRegenerated && mounted) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'New encryption keys generated. Messages from before '
              'this login may not be decryptable on this device.',
            ),
            duration: Duration(seconds: 6),
          ),
        );
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: context.mainBg,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const EchoLogoIcon(size: 72),
              const SizedBox(height: 16),
              Text(
                'Echo',
                style: TextStyle(
                  fontSize: 28,
                  fontWeight: FontWeight.w700,
                  letterSpacing: -0.5,
                  color: context.accent,
                ),
              ),
              const SizedBox(height: 32),
              SizedBox(
                width: 24,
                height: 24,
                child: CircularProgressIndicator(
                  strokeWidth: 2.5,
                  color: context.accent.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
