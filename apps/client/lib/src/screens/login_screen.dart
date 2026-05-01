import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/version_utils.dart';
import '../widgets/auth/auth_scaffold_chrome.dart';
import '../widgets/echo_logo_icon.dart';

/// Pre-fill the username from the [knownServersProvider] entry that
/// matches the active server URL, if any. Returns null when there is no
/// match so the caller can leave the controller untouched.
String? _knownUsernameFor(WidgetRef ref) {
  final url = ref.read(serverUrlProvider);
  final servers = ref.read(knownServersProvider);
  for (final s in servers) {
    if (s.url == url) return s.lastUsername;
  }
  return null;
}

/// Larger bottom padding in debug builds leaves room for the multi-line
/// version footer (server reachability + web bundle), which would otherwise
/// overlap the form when the keyboard is open on small screens.
const double _bottomPad = kDebugMode ? 96.0 : 56.0;

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen>
    with AutomaticKeepAliveClientMixin {
  @override
  bool get wantKeepAlive => true;

  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  bool _obscurePassword = true;

  Future<Map<String, String?>>? _versionFuture;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  /// Fill the username field from the matching [knownServersProvider]
  /// entry on first build. Re-runs whenever the active server URL changes
  /// so a server switch back to a known origin still pre-fills.
  ///
  /// Never overwrites text the user has already typed (PR #659 reviewer
  /// catch): we only pre-fill when the field is empty.
  void _maybePrefillUsername() {
    if (_usernameController.text.isNotEmpty) return;
    final cached = _knownUsernameFor(ref);
    if (cached != null && cached.isNotEmpty) {
      _usernameController.text = cached;
    }
  }

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = ref.read(authProvider.notifier);
    final enteredUsername = _usernameController.text.trim();
    await auth.login(enteredUsername, _passwordController.text);
    if (!mounted) return;
    if (ref.read(authProvider).error != null) {
      _passwordController.clear();
      return;
    }
    // Successful login -- record the username against the active URL so
    // the next visit pre-fills it (#PR-2).
    final serverUrl = ref.read(serverUrlProvider);
    await ref
        .read(serverUrlProvider.notifier)
        .recordLastUsername(url: serverUrl, username: enteredUsername);
    // Crypto init happens in contacts_screen._initData() after navigation
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final authState = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    // Re-prefill if the active URL changes (e.g. server switch lands here).
    // Clear the field first so the guard (text.isNotEmpty) lets the new
    // server's cached username repopulate. Without the clear we'd keep the
    // OLD server's username after a switch.
    ref.listen<String>(serverUrlProvider, (prev, next) {
      if (prev != next) {
        _usernameController.clear();
        _maybePrefillUsername();
      }
    });
    _maybePrefillUsername();

    _versionFuture ??= fetchVersionInfo(serverUrl);

    return Scaffold(
      body: Stack(
        children: [
          const AuthBackground(),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, _bottomPad),
                  child: Form(
                    key: _formKey,
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          _buildHeader(),
                          const SizedBox(height: 32),
                          _buildUsernameField(),
                          const SizedBox(height: 16),
                          _buildPasswordField(),
                          _buildErrorMessage(authState),
                          const SizedBox(height: 24),
                          _buildLoginButton(authState),
                          const SizedBox(height: 4),
                          SizedBox(
                            height: 44,
                            child: Semantics(
                              button: true,
                              label: 'forgot-password',
                              child: TextButton(
                                onPressed: () => context.go('/forgot-password'),
                                style: TextButton.styleFrom(
                                  foregroundColor: context.textSecondary,
                                ),
                                child: const Text('Forgot password?'),
                              ),
                            ),
                          ),
                          SizedBox(
                            height: 44,
                            child: Semantics(
                              button: true,
                              label: 'create-account',
                              child: TextButton(
                                onPressed: () => context.go('/register'),
                                style: TextButton.styleFrom(
                                  foregroundColor: context.textSecondary,
                                ),
                                child: const Text('Create an account'),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            bottom: 16,
            child: SafeArea(
              top: false,
              child: AuthVersionFooter(versionFuture: _versionFuture),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Column(
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            const EchoLogoIcon(size: 30),
            const SizedBox(width: 10),
            Text(
              'Echo',
              style: GoogleFonts.inter(
                fontSize: 30,
                fontWeight: FontWeight.w700,
                letterSpacing: -0.5,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'End-to-end encrypted. Zero telemetry.',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 16),
        ),
      ],
    );
  }

  Widget _buildUsernameField() {
    return TextFormField(
      controller: _usernameController,
      autofillHints: const [AutofillHints.username],
      decoration: const InputDecoration(
        labelText: 'Username',
        border: OutlineInputBorder(),
      ),
      textInputAction: TextInputAction.next,
      validator: (value) {
        if (value == null || value.trim().isEmpty) {
          return 'Username is required';
        }
        return null;
      },
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      autofillHints: const [AutofillHints.password],
      decoration: InputDecoration(
        labelText: 'Password',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(
            _obscurePassword ? Icons.visibility_off : Icons.visibility,
          ),
          onPressed: () => setState(() => _obscurePassword = !_obscurePassword),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
      ),
      onFieldSubmitted: (_) => _login(),
      validator: (value) {
        if (value == null || value.isEmpty) {
          return 'Password is required';
        }
        return null;
      },
    );
  }

  Widget _buildErrorMessage(AuthState authState) {
    if (authState.error == null) return const SizedBox.shrink();
    return Column(
      children: [
        const SizedBox(height: 12),
        Text(
          authState.error!,
          style: TextStyle(color: Theme.of(context).colorScheme.error),
        ),
      ],
    );
  }

  Widget _buildLoginButton(AuthState authState) {
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        button: true,
        label: 'login',
        child: FilledButton(
          onPressed: authState.isLoading ? null : _login,
          child: authState.isLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Log in'),
        ),
      ),
    );
  }
}
