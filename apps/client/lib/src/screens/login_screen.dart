import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/remembered_accounts_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/version_utils.dart';
import '../widgets/auth/auth_layout.dart';
import '../widgets/auth/auth_scaffold_chrome.dart';
import '../widgets/auth/beta_banner.dart';
import '../widgets/auth/server_subtitle.dart';
import '../widgets/echo_logo_icon.dart';
import '../widgets/window_chrome.dart';

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
      body: Column(
        children: [
          const AppTitleBar(),
          Expanded(
            child: Stack(
              children: [
                const AuthBackground(),
                AuthLayout(
                  // Brand-panel tagline stays as the welcoming line; form
                  // card title is the action verb so the wide layout doesn't
                  // print "Welcome back." twice side-by-side.
                  tagline: 'Welcome back.',
                  formTitle: 'Log in to Echo',
                  compactHeader: _buildHeader(serverUrl),
                  narrowPadding: const EdgeInsets.fromLTRB(
                    EchoSpacing.xl,
                    EchoSpacing.xl,
                    EchoSpacing.xl,
                    _bottomPad,
                  ),
                  formColumn: Form(
                    key: _formKey,
                    child: AutofillGroup(
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          // Beta callout (moved here from onboarding) so a
                          // brand-new user sees it before signing up and a
                          // returning tester sees it on every login.
                          BetaBanner.standard(),
                          _buildRememberedAccountsRow(),
                          _buildUsernameField(),
                          const SizedBox(height: EchoSpacing.lg),
                          _buildPasswordField(),
                          _buildErrorMessage(authState),
                          const SizedBox(height: EchoSpacing.xl),
                          _buildLoginButton(authState),
                          const SizedBox(height: EchoSpacing.xs),
                          Semantics(
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
                          // TextButton + Text already produce a
                          // button-role accessibility node named "Create an
                          // account" — wrapping in another Semantics
                          // duplicates the node and trips strict-mode
                          // selectors (`getByRole('button', { name: /create
                          // an account/i })` resolves to 2).
                          TextButton(
                            onPressed: () => context.go('/register'),
                            style: TextButton.styleFrom(
                              foregroundColor: context.textSecondary,
                            ),
                            child: const Text('Create an account'),
                          ),
                        ],
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
          ),
        ],
      ),
    );
  }

  Widget _buildHeader(String serverUrl) {
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
        const SizedBox(height: 6),
        ServerSubtitle(serverUrl: serverUrl),
      ],
    );
  }

  /// Chrome-style quick-switch row. Renders one tile per account that
  /// has signed in on this device (provider hydrates from prefs).
  /// Tapping a tile pre-fills the username + focuses the password
  /// field; long-press shows a "Forget" sheet so the tile can be
  /// removed without affecting the cached account data.
  Widget _buildRememberedAccountsRow() {
    final accounts = ref.watch(rememberedAccountsProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    // Scope to the active server — switching servers (#1063) hides
    // tiles for accounts that lived on the other origin.
    final visible = accounts.where((a) => a.serverUrl == serverUrl).toList();
    if (visible.isEmpty) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.only(bottom: EchoSpacing.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            'Continue as',
            style: TextStyle(
              color: context.textMuted,
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
            ),
          ),
          const SizedBox(height: 8),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: [
                for (final acc in visible)
                  Padding(
                    padding: const EdgeInsets.only(right: 10),
                    child: _RememberedAccountTile(
                      account: acc,
                      onTap: () => _usePreviousAccount(acc),
                      onForget: () => ref
                          .read(rememberedAccountsProvider.notifier)
                          .forget(userId: acc.userId, serverUrl: acc.serverUrl),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: EchoSpacing.lg),
          Divider(color: context.border, height: 1),
          const SizedBox(height: EchoSpacing.lg),
        ],
      ),
    );
  }

  void _usePreviousAccount(RememberedAccount acc) {
    _usernameController.text = acc.username;
    _passwordController.clear();
    // No FocusNode plumbed to the password field today, so we can't
    // imperatively move focus. The username is pre-filled and the
    // user taps Password — fine for the first iteration.
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

/// Tile for the "Continue as" row on the login screen. Renders the
/// account's avatar (or initial-circle fallback) and username; tap to
/// pre-fill, long-press to forget.
class _RememberedAccountTile extends StatelessWidget {
  const _RememberedAccountTile({
    required this.account,
    required this.onTap,
    required this.onForget,
  });

  final RememberedAccount account;
  final VoidCallback onTap;
  final VoidCallback onForget;

  @override
  Widget build(BuildContext context) {
    final initial = account.username.isNotEmpty
        ? account.username[0].toUpperCase()
        : '?';
    final hue = (account.username.hashCode % 360).abs().toDouble();
    final bg = HSLColor.fromAHSL(1.0, hue, 0.55, 0.45).toColor();
    final hasAvatar =
        account.avatarUrl != null && account.avatarUrl!.isNotEmpty;
    final resolvedAvatar = hasAvatar
        ? (account.avatarUrl!.startsWith('http')
              ? account.avatarUrl!
              : '${account.serverUrl}${account.avatarUrl!}')
        : null;

    return Semantics(
      label: 'Continue as ${account.username}',
      button: true,
      child: GestureDetector(
        onLongPress: () => _showForgetMenu(context),
        child: Material(
          color: Colors.transparent,
          borderRadius: BorderRadius.circular(12),
          child: InkWell(
            onTap: onTap,
            borderRadius: BorderRadius.circular(12),
            hoverColor: context.surfaceHover,
            child: Container(
              width: 88,
              padding: const EdgeInsets.symmetric(vertical: 10, horizontal: 6),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: context.border),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircleAvatar(
                    radius: 24,
                    backgroundColor: bg,
                    foregroundImage: resolvedAvatar != null
                        ? NetworkImage(resolvedAvatar)
                        : null,
                    child: resolvedAvatar == null
                        ? Text(
                            initial,
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 18,
                              fontWeight: FontWeight.w700,
                            ),
                          )
                        : null,
                  ),
                  const SizedBox(height: 6),
                  Text(
                    account.username,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: context.textPrimary,
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showForgetMenu(BuildContext context) async {
    await showModalBottomSheet<void>(
      context: context,
      builder: (sheetContext) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            ListTile(
              leading: const Icon(
                Icons.person_remove_outlined,
                color: EchoTheme.danger,
              ),
              title: const Text('Forget this account'),
              subtitle: const Text(
                'Hide this sign-in suggestion. Your messages and keys '
                'stay on this device.',
              ),
              onTap: () {
                Navigator.of(sheetContext).pop();
                onForget();
              },
            ),
          ],
        ),
      ),
    );
  }
}
