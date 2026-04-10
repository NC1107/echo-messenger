import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_provider.dart';
import '../providers/crypto_provider.dart';
import '../providers/update_provider.dart';
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

    // Try auto-login from stored credentials with a timeout so the splash
    // never hangs on a slow or unreachable network.
    final auth = ref.read(authProvider.notifier);
    var loggedIn = false;
    try {
      loggedIn = await auth.tryAutoLogin().timeout(
        const Duration(seconds: 5),
        onTimeout: () => false,
      );
    } catch (_) {
      // Network error — treat as not logged in, user can retry from login.
    }

    // If auto-login succeeded, init crypto keys
    if (loggedIn) {
      await ref.read(cryptoProvider.notifier).initAndUploadKeys();
    }

    // Support compile-time env vars for CI/testing
    if (!loggedIn && !kIsWeb) {
      const envUser = String.fromEnvironment('ECHO_USERNAME');
      const envPass = String.fromEnvironment('ECHO_PASSWORD');
      if (envUser.isNotEmpty && envPass.isNotEmpty) {
        await auth.login(envUser, envPass);
        if (ref.read(authProvider).isLoggedIn) {
          await ref.read(cryptoProvider.notifier).initAndUploadKeys();
          loggedIn = true;
        }
      }
    }

    // Check for updates on non-web platforms
    if (!kIsWeb) {
      // Fire-and-forget -- don't block splash on network call
      ref.read(updateProvider.notifier).check();
    }

    // Brief splash to let the logo animation complete (reduced from 500ms)
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    if (elapsed < 200) {
      await Future<void>.delayed(Duration(milliseconds: 200 - elapsed));
    }

    if (!mounted) return;

    final isLoggedIn = ref.read(authProvider).isLoggedIn;
    if (isLoggedIn && pendingDeepLink != null) {
      final destination = pendingDeepLink!;
      pendingDeepLink = null;
      context.go(destination);
    } else if (isLoggedIn) {
      // Auto-login from stored token means this is a returning user.
      // Ensure onboarding flag is set so they always skip the wizard.
      // New registrations navigate to /onboarding from RegisterScreen.
      final prefs = await SharedPreferences.getInstance();
      if (prefs.getBool(kOnboardingCompletedKey) != true) {
        await prefs.setBool(kOnboardingCompletedKey, true);
      }
      if (!mounted) return;
      context.go('/home');
    } else {
      context.go('/login');
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
