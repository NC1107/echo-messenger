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
import '../services/message_cache.dart';
import '../services/push_token_service.dart';
import '../services/update_service.dart' as update_svc;
import '../router/app_router.dart' show pendingDeepLink;
import '../screens/onboarding_wizard.dart' show kOnboardingCompletedKey;
import '../theme/echo_theme.dart';
import '../widgets/auth/animated_gradient_background.dart';
import '../widgets/echo_logo_icon.dart';
import '../version.dart';

class SplashScreen extends ConsumerStatefulWidget {
  const SplashScreen({super.key});

  @override
  ConsumerState<SplashScreen> createState() => _SplashScreenState();
}

class _SplashScreenState extends ConsumerState<SplashScreen>
    with SingleTickerProviderStateMixin {
  late final AnimationController _fadeController;
  late final Animation<double> _fadeAnimation;
  bool _showUpdatePrompt = false;
  bool _loggedIn = false;
  String _statusText = 'Connecting…';

  void _setStatus(String text) {
    if (!mounted) return;
    setState(() => _statusText = text);
  }

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

    _setStatus('Checking session…');
    final loggedIn = await _attemptAutoLogin();

    // Pre-load conversations so home screen doesn't flash empty state
    if (loggedIn) {
      _setStatus('Loading messages…');
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

    // On desktop, if an update is available, show the update prompt
    // instead of navigating immediately.
    final updateState = ref.read(updateProvider);
    if (!kIsWeb && update_svc.canAutoUpdate && updateState.updateAvailable) {
      setState(() {
        _showUpdatePrompt = true;
        _loggedIn = loggedIn;
      });
      return;
    }

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
      await ref.read(updateProvider.notifier).check();
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
    // Only warn about regenerated keys when the user had prior messages on
    // this device. Fresh logins on a new device would otherwise see a
    // scary "history unavailable" banner that doesn't apply to them.
    final hadPriorMessages = MessageCache.entryCount() > 0;
    if (cryptoState.keysWereRegenerated && hadPriorMessages && mounted) {
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

  Widget _buildUpdatePrompt(BuildContext context) {
    final update = ref.watch(updateProvider);
    final isDownloading = update.status == UpdateStatus.downloading;
    final isInstalling = update.status == UpdateStatus.installing;
    final isReady = update.status == UpdateStatus.readyToInstall;
    final isError = update.status == UpdateStatus.error;
    final isBusy = isDownloading || isInstalling;

    return Scaffold(
      backgroundColor: context.mainBg,
      body: Center(
        child: FadeTransition(
          opacity: _fadeAnimation,
          child: Container(
            width: 360,
            padding: const EdgeInsets.all(32),
            decoration: BoxDecoration(
              color: context.surface,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: context.border),
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const EchoLogoIcon(size: 48),
                const SizedBox(height: 16),
                Text(
                  'Update Available',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w700,
                    color: context.textPrimary,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  'v$appVersion  ->  v${update.latestVersion}',
                  style: TextStyle(
                    fontSize: 14,
                    color: context.textMuted,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(height: 24),
                if (isDownloading) ...[
                  LinearProgressIndicator(
                    value: update.downloadProgress,
                    color: context.accent,
                    backgroundColor: context.border,
                    minHeight: 4,
                    borderRadius: BorderRadius.circular(2),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Downloading... ${(update.downloadProgress * 100).toInt()}%',
                    style: TextStyle(fontSize: 12, color: context.textMuted),
                  ),
                ],
                if (isInstalling)
                  Text(
                    'Installing...',
                    style: TextStyle(fontSize: 12, color: context.textMuted),
                  ),
                if (isError) ...[
                  Text(
                    update.errorMessage ?? 'Download failed',
                    style: const TextStyle(
                      fontSize: 12,
                      color: Colors.redAccent,
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
                if (isReady) ...[
                  FilledButton.icon(
                    onPressed: () =>
                        ref.read(updateProvider.notifier).applyUpdate(),
                    icon: const Icon(Icons.restart_alt, size: 16),
                    label: const Text('Restart to Update'),
                    style: FilledButton.styleFrom(
                      backgroundColor: context.accent,
                      minimumSize: const Size(double.infinity, 40),
                    ),
                  ),
                  const SizedBox(height: 8),
                ],
                if (!isReady && !isInstalling) ...[
                  if (!isDownloading)
                    FilledButton(
                      onPressed: () =>
                          ref.read(updateProvider.notifier).downloadUpdate(),
                      style: FilledButton.styleFrom(
                        backgroundColor: context.accent,
                        minimumSize: const Size(double.infinity, 40),
                      ),
                      child: const Text('Download Update'),
                    ),
                  const SizedBox(height: 8),
                  TextButton(
                    onPressed: isBusy
                        ? null
                        : () => _navigateAfterInit(_loggedIn),
                    style: TextButton.styleFrom(
                      minimumSize: const Size(double.infinity, 40),
                    ),
                    child: Text(
                      'Skip',
                      style: TextStyle(
                        color: isBusy
                            ? context.textMuted.withValues(alpha: 0.4)
                            : context.textMuted,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_showUpdatePrompt) {
      return _buildUpdatePrompt(context);
    }

    return Scaffold(
      backgroundColor: context.mainBg,
      body: Stack(
        children: [
          const AnimatedGradientBackground(),
          Center(
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
                  const SizedBox(height: 16),
                  Text(
                    _statusText,
                    style: TextStyle(fontSize: 13, color: context.textMuted),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}
