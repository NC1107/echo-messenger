import 'dart:async' show unawaited;

import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;
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
import '../services/window_state_service.dart';
import '../router/app_router.dart' show pendingDeepLinkProvider;
import '../screens/onboarding_wizard.dart' show kOnboardingCompletedKey;
import '../theme/echo_theme.dart';
import '../widgets/echo_logo_icon.dart';
import '../version.dart';

/// SharedPreferences flag flipped once the splash has been shown end-to-end
/// at least once. Used to drop the splash minimum hold from 1.5s to 0.4s
/// on every subsequent launch — first-time users still get the brand
/// moment, veterans don't pay the tax every cold start.
const String _kFirstLaunchCompletedKey = 'splash.first_launch_completed';

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

    // Slice 10: shrink the desktop window to a 320×440 splash before doing
    // any async work, Discord-style. The window expands back to the user's
    // last-known size after navigation lands on home/login.
    await WindowStateService.enterSplash();

    // The iOS/macOS local-network permission explainer used to fire here
    // before auto-login. Removed per direct user feedback — the bare OS
    // dialog is enough, and the in-app overlay added friction on the
    // splash that users didn't want. The service file is kept in case
    // we want to restore a friendlier variant later.

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

    // Keep the splash visible long enough to read the wordmark + tagline
    // and let the indigo sweep complete one cycle on FIRST install. After
    // that the user has seen the brand moment — veterans don't need to
    // pay the 1500 ms on every cold launch. Drop to a small 400 ms floor
    // so the cross-fade still feels intentional but doesn't actively
    // hold up the app.
    stopwatch.stop();
    final elapsed = stopwatch.elapsedMilliseconds;
    final prefs = await SharedPreferences.getInstance();
    final firstLaunchCompleted =
        prefs.getBool(_kFirstLaunchCompletedKey) ?? false;
    final minSplashMs = firstLaunchCompleted ? 400 : 1500;
    if (elapsed < minSplashMs) {
      await Future<void>.delayed(Duration(milliseconds: minSplashMs - elapsed));
    }
    if (!firstLaunchCompleted) {
      // Fire-and-forget: the flag flip doesn't gate navigation.
      unawaited(prefs.setBool(_kFirstLaunchCompletedKey, true));
    }

    if (!mounted) return;

    // On desktop, if an update is available, show the update prompt
    // instead of navigating immediately.
    final updateState = ref.read(updateProvider);
    if (!kIsWeb && update_svc.canAutoUpdate && updateState.updateAvailable) {
      // Grow the chromeless splash window to a size that comfortably fits
      // the actionable update prompt — the 320×440 splash dimensions
      // crowded the Download/Restart/Skip stack.
      await WindowStateService.enterUpdatePrompt();
      if (!mounted) return;
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
    final deepLink = ref.read(pendingDeepLinkProvider.notifier).takeAndClear();

    // Slice 10: restore the user's last-known window geometry as soon as we
    // know we're leaving the splash. Fire-and-forget — navigation must not
    // wait for the OS window resize.
    unawaited(WindowStateService.restore());

    if (isLoggedIn && deepLink != null) {
      context.go(deepLink);
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
    // Desktop renders inside the 320×440 chromeless splash window, so the
    // update prompt has to reuse the splash shell — same `mainBg`, same
    // ambient halo, same brand block — and just swap the bottom action
    // slot. Mobile/web fall through to full-screen with the same
    // composition, mirroring [_SplashBody.compact].
    final isCompact =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS);

    final body = _UpdatePromptBody(
      compact: isCompact,
      fade: _fadeAnimation,
      onSkip: () => _navigateAfterInit(_loggedIn),
    );

    if (isCompact) {
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.mainBg,
              border: Border.all(color: context.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: body,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.mainBg,
      body: SafeArea(child: body),
    );
  }

  static const String _tagline = 'End-to-end encrypted. Zero telemetry.';

  @override
  Widget build(BuildContext context) {
    if (_showUpdatePrompt) {
      return _buildUpdatePrompt(context);
    }

    // Desktop splash is a 320×440 chromeless window (see WindowStateService.
    // enterSplash). Mobile/web render full-screen with the same composition.
    final isCompact =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.linux ||
            defaultTargetPlatform == TargetPlatform.windows ||
            defaultTargetPlatform == TargetPlatform.macOS);

    final body = _SplashBody(
      compact: isCompact,
      fade: _fadeAnimation,
      statusText: _statusText,
      tagline: _tagline,
    );

    if (isCompact) {
      // Desktop: transparent Scaffold + rounded-clipped surface so the splash
      // reads as a floating card on compositors that honour window
      // transparency, and degrades gracefully to a squared-off card on those
      // that don't.
      return Scaffold(
        backgroundColor: Colors.transparent,
        body: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: context.mainBg,
              border: Border.all(color: context.border),
              borderRadius: BorderRadius.circular(12),
            ),
            child: body,
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: context.mainBg,
      body: SafeArea(child: body),
    );
  }
}

/// Echo "Classic" startup composition: ambient halo, centred logo + wordmark,
/// single boot-status caption with cycling-dot indicator, indigo sweep, and a
/// monospace version footer. Layout adapts between the 320×440 desktop popup
/// and a full-screen mobile/web splash via [compact].
class _SplashBody extends StatelessWidget {
  const _SplashBody({
    required this.compact,
    required this.fade,
    required this.statusText,
    required this.tagline,
  });

  final bool compact;
  final Animation<double> fade;
  final String statusText;
  final String tagline;

  @override
  Widget build(BuildContext context) {
    final accent = context.accent;
    final logoSize = compact ? 64.0 : 84.0;
    final wordmarkSize = compact ? 22.0 : 28.0;
    final taglineSize = compact ? 12.0 : 13.0;
    final outerPadding = compact
        ? const EdgeInsets.fromLTRB(28, 44, 28, 22)
        : const EdgeInsets.fromLTRB(36, 24, 36, 38);

    return FadeTransition(
      opacity: fade,
      child: Stack(
        children: [
          // Ambient indigo halo behind the logo. Painted with a low-opacity
          // accent so it picks up the current theme without overpowering it.
          Positioned(
            top: compact ? -120 : -40,
            left: 0,
            right: 0,
            child: IgnorePointer(
              child: Center(
                child: Container(
                  width: compact ? 360 : 420,
                  height: compact ? 360 : 420,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    gradient: RadialGradient(
                      colors: [
                        accent.withValues(alpha: 0.13),
                        accent.withValues(alpha: 0.0),
                      ],
                      stops: const [0.0, 0.6],
                    ),
                  ),
                ),
              ),
            ),
          ),
          Padding(
            padding: outerPadding,
            child: Column(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Brand block (logo + wordmark + tagline)
                Padding(
                  padding: EdgeInsets.only(top: compact ? 12 : 60),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      EchoLogoIcon(size: logoSize),
                      SizedBox(height: compact ? 18 : 24),
                      Text(
                        'Echo',
                        style: TextStyle(
                          fontSize: wordmarkSize,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.5,
                          height: 1.0,
                          color: context.textPrimary,
                        ),
                      ),
                      SizedBox(height: compact ? 8 : 10),
                      Text(
                        tagline,
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          fontSize: taglineSize,
                          color: context.textSecondary,
                        ),
                      ),
                    ],
                  ),
                ),
                // Status caption + progress sweep
                Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _StatusCaption(text: statusText),
                    const SizedBox(height: 14),
                    const _ProgressSweep(),
                    if (!compact) ...[
                      const SizedBox(height: 18),
                      Text(
                        'v$appVersion',
                        style: EchoTheme.mono(
                          fontSize: 10,
                          color: context.textMuted,
                          letterSpacing: 0.3,
                        ),
                      ),
                    ],
                  ],
                ),
                if (compact)
                  Text(
                    'v$appVersion',
                    style: EchoTheme.mono(
                      fontSize: 10,
                      color: context.textMuted,
                      letterSpacing: 0.3,
                    ),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

/// Update-available composition. Mirrors [_SplashBody]'s shell so the
/// "we're about to boot you into the app" splash and the "we have an
/// update first" prompt read as the same screen — same halo, same brand
/// block, same outer padding — with only the bottom slot swapping from
/// the boot-status caption to the version-cycle caption + action
/// buttons.
class _UpdatePromptBody extends ConsumerWidget {
  const _UpdatePromptBody({
    required this.compact,
    required this.fade,
    required this.onSkip,
  });

  final bool compact;
  final Animation<double> fade;
  final VoidCallback onSkip;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final update = ref.watch(updateProvider);
    final accent = context.accent;
    final outerPadding = compact
        ? const EdgeInsets.fromLTRB(28, 44, 28, 22)
        : const EdgeInsets.fromLTRB(36, 24, 36, 38);

    // The previous layout used MainAxisAlignment.spaceBetween across the
    // full viewport, which on anything larger than the 320×440 desktop
    // splash window left huge empty gaps above and below the action block.
    // Centring the brand + action as one tight stack and pinning the
    // version label to the bottom keeps the prompt feeling like a focused
    // card at every window size.
    return FadeTransition(
      opacity: fade,
      // StackFit.expand forces the rounded card chain to fill the whole
      // chromeless window. Without it the non-positioned Center wraps
      // tightly around its content, the ClipRRect shrinks to that size,
      // and the transparent window corners show through as black on
      // compositors that don't paint window translucency.
      child: Stack(
        fit: StackFit.expand,
        children: [
          _buildHaloBackdrop(accent),
          Center(
            child: Padding(
              padding: outerPadding,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.center,
                children: [
                  _buildBrandBlock(context),
                  const SizedBox(height: 28),
                  _buildActionBlock(context, ref, update, accent),
                ],
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: Center(child: _buildVersionLabel(context)),
          ),
        ],
      ),
    );
  }

  Widget _buildHaloBackdrop(Color accent) {
    return Positioned(
      top: compact ? -120 : -40,
      left: 0,
      right: 0,
      child: IgnorePointer(
        child: Center(
          child: Container(
            width: compact ? 360 : 420,
            height: compact ? 360 : 420,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              gradient: RadialGradient(
                colors: [
                  accent.withValues(alpha: 0.13),
                  accent.withValues(alpha: 0.0),
                ],
                stops: const [0.0, 0.6],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildBrandBlock(BuildContext context) {
    final logoSize = compact ? 64.0 : 84.0;
    final wordmarkSize = compact ? 22.0 : 28.0;
    final taglineSize = compact ? 12.0 : 13.0;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        EchoLogoIcon(size: logoSize),
        SizedBox(height: compact ? 18 : 24),
        Text(
          'Echo',
          style: TextStyle(
            fontSize: wordmarkSize,
            fontWeight: FontWeight.w700,
            letterSpacing: -0.5,
            height: 1.0,
            color: context.textPrimary,
          ),
        ),
        SizedBox(height: compact ? 8 : 10),
        Text(
          'Update available',
          textAlign: TextAlign.center,
          style: TextStyle(fontSize: taglineSize, color: context.textSecondary),
        ),
      ],
    );
  }

  Widget _buildActionBlock(
    BuildContext context,
    WidgetRef ref,
    dynamic update,
    Color accent,
  ) {
    final isDownloading = update.status == UpdateStatus.downloading;
    final isInstalling = update.status == UpdateStatus.installing;
    final isReady = update.status == UpdateStatus.readyToInstall;
    final isError = update.status == UpdateStatus.error;
    final isBusy = isDownloading || isInstalling;

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          'v$appVersion  →  v${update.latestVersion}',
          style: EchoTheme.mono(
            fontSize: 12,
            color: context.textMuted,
            letterSpacing: 0.4,
          ),
        ),
        const SizedBox(height: 16),
        _buildPrimaryAction(
          context,
          ref,
          update,
          accent,
          isDownloading: isDownloading,
          isInstalling: isInstalling,
          isReady: isReady,
        ),
        if (isError) _buildErrorMessage(update),
        if (!isReady && !isInstalling) _buildSkipButton(context, isBusy),
      ],
    );
  }

  Widget _buildPrimaryAction(
    BuildContext context,
    WidgetRef ref,
    dynamic update,
    Color accent, {
    required bool isDownloading,
    required bool isInstalling,
    required bool isReady,
  }) {
    if (isDownloading) {
      return Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          SizedBox(
            width: compact ? 220 : 280,
            child: LinearProgressIndicator(
              value: update.downloadProgress,
              color: accent,
              backgroundColor: context.border,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Downloading… ${(update.downloadProgress * 100).toInt()}%',
            style: TextStyle(fontSize: 12, color: context.textMuted),
          ),
        ],
      );
    }
    if (isInstalling) {
      return Text(
        'Installing…',
        style: TextStyle(fontSize: 12, color: context.textMuted),
      );
    }
    if (isReady) {
      return SizedBox(
        width: compact ? 220 : 280,
        child: FilledButton.icon(
          onPressed: () => ref.read(updateProvider.notifier).applyUpdate(),
          icon: const Icon(Icons.restart_alt, size: 16),
          label: const Text('Restart to Update'),
          style: FilledButton.styleFrom(
            backgroundColor: accent,
            minimumSize: const Size(double.infinity, 40),
            shape: const StadiumBorder(),
          ),
        ),
      );
    }
    return SizedBox(
      width: compact ? 220 : 280,
      child: FilledButton(
        onPressed: () => ref.read(updateProvider.notifier).downloadUpdate(),
        style: FilledButton.styleFrom(
          backgroundColor: accent,
          minimumSize: const Size(double.infinity, 40),
          shape: const StadiumBorder(),
        ),
        child: const Text('Download Update'),
      ),
    );
  }

  Widget _buildErrorMessage(dynamic update) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Text(
        update.errorMessage ?? 'Download failed',
        textAlign: TextAlign.center,
        style: const TextStyle(fontSize: 12, color: EchoTheme.danger),
      ),
    );
  }

  Widget _buildSkipButton(BuildContext context, bool isBusy) {
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: TextButton(
        onPressed: isBusy ? null : onSkip,
        child: Text(
          'Skip',
          style: TextStyle(
            fontSize: 12,
            color: isBusy
                ? context.textMuted.withValues(alpha: 0.4)
                : context.textMuted,
          ),
        ),
      ),
    );
  }

  Widget _buildVersionLabel(BuildContext context) {
    return Text(
      'v$appVersion',
      style: EchoTheme.mono(
        fontSize: 10,
        color: context.textMuted,
        letterSpacing: 0.3,
      ),
    );
  }
}

/// Boot-status caption with a three-dot pulse indicator. The caption text is
/// driven by [_SplashScreenState._statusText] so it reflects the actual
/// init phase ("Checking session…", "Loading messages…") instead of a
/// canned animation that lies about progress.
class _StatusCaption extends StatelessWidget {
  const _StatusCaption({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return AnimatedSwitcher(
      duration: const Duration(milliseconds: 350),
      transitionBuilder: (child, anim) {
        final slide = Tween<Offset>(
          begin: const Offset(0, 0.15),
          end: Offset.zero,
        ).animate(anim);
        return FadeTransition(
          opacity: anim,
          child: SlideTransition(position: slide, child: child),
        );
      },
      child: Row(
        key: ValueKey<String>(text),
        mainAxisSize: MainAxisSize.min,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(
            text,
            style: TextStyle(fontSize: 12, color: context.textSecondary),
          ),
          const SizedBox(width: 6),
          _DotPulse(color: context.textMuted),
        ],
      ),
    );
  }
}

/// Three small dots that fade up and down in sequence (staggered 0.18s) for a
/// subtle "working…" affordance next to the boot caption.
class _DotPulse extends StatefulWidget {
  const _DotPulse({required this.color});

  final Color color;

  @override
  State<_DotPulse> createState() => _DotPulseState();
}

class _DotPulseState extends State<_DotPulse>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1200),
    )..repeat();
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  double _dotOpacity(double t, double offset) {
    // 0..1 sawtooth driving the keyframe shape from the design CSS:
    // 0%/80%/100% -> .25, 40% -> 1. Smoothed with a triangle wave so the
    // peak rises and falls instead of snapping.
    final shifted = (t - offset) % 1.0;
    final clamped = shifted < 0 ? shifted + 1.0 : shifted;
    if (clamped < 0.4) {
      return 0.25 + (clamped / 0.4) * 0.75;
    }
    if (clamped < 0.8) {
      return 1.0 - ((clamped - 0.4) / 0.4) * 0.75;
    }
    return 0.25;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final t = _controller.value;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(3, (i) {
            final opacity = _dotOpacity(t, i * 0.15);
            return Padding(
              padding: EdgeInsets.only(left: i == 0 ? 0 : 4),
              child: Container(
                width: 4,
                height: 4,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: widget.color.withValues(alpha: opacity),
                ),
              ),
            );
          }),
        );
      },
    );
  }
}

/// Indeterminate accent sweep: 40%-wide bar that slides from left to right
/// inside a 3px-tall track. Mirrors the design's `echo-sweep` keyframes
/// (translateX -100% → 350%, 1.6s cubic-bezier).
class _ProgressSweep extends StatefulWidget {
  const _ProgressSweep();

  @override
  State<_ProgressSweep> createState() => _ProgressSweepState();
}

class _ProgressSweepState extends State<_ProgressSweep>
    with SingleTickerProviderStateMixin {
  late final AnimationController _controller;
  late final Animation<double> _slide;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1600),
    )..repeat();
    _slide = CurvedAnimation(
      parent: _controller,
      curve: Curves.easeInOutCubicEmphasized,
    );
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final accent = context.accent;
    final track = context.surface;
    return SizedBox(
      height: 3,
      child: LayoutBuilder(
        builder: (context, constraints) {
          final width = constraints.maxWidth;
          const barFraction = 0.4;
          final barWidth = width * barFraction;
          return ClipRRect(
            borderRadius: BorderRadius.circular(999),
            child: Container(
              color: track,
              child: AnimatedBuilder(
                animation: _slide,
                builder: (context, _) {
                  // Slide from -barWidth to width (full traversal).
                  final dx = -barWidth + (_slide.value * (width + barWidth));
                  return Stack(
                    children: [
                      Positioned(
                        left: dx,
                        top: 0,
                        bottom: 0,
                        width: barWidth,
                        child: Container(
                          decoration: BoxDecoration(
                            color: accent,
                            borderRadius: BorderRadius.circular(999),
                          ),
                        ),
                      ),
                    ],
                  );
                },
              ),
            ),
          );
        },
      ),
    );
  }
}
