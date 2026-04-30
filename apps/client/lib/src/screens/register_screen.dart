import 'package:flutter/foundation.dart' show kDebugMode;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../theme/echo_theme.dart';
import '../utils/version_utils.dart';
import '../widgets/auth/auth_scaffold_chrome.dart';
import '../widgets/echo_logo_icon.dart';

/// Larger bottom padding in debug builds leaves room for the multi-line
/// version footer (server reachability + web bundle), which would otherwise
/// overlap the form when the keyboard is open on small screens.
const double _bottomPad = kDebugMode ? 96.0 : 56.0;

/// Computes password strength as a value from 0.0 to 1.0.
/// Returns a record of (double value, String label, Color color).
({double value, String label, Color color}) _passwordStrength(String password) {
  if (password.isEmpty) {
    return (value: 0.0, label: '', color: Colors.transparent);
  }

  final hasLower = password.contains(RegExp(r'[a-z]'));
  final hasUpper = password.contains(RegExp(r'[A-Z]'));
  final hasDigit = password.contains(RegExp(r'[0-9]'));
  final hasMixedCase = hasLower && hasUpper;
  final length = password.length;

  // Strong: 12+ chars, mixed case, and numbers
  if (length >= 12 && hasMixedCase && hasDigit) {
    return (value: 1.0, label: 'Strong', color: EchoTheme.online);
  }

  // Fair: 10+ chars or mixed case
  if (length >= 10 || hasMixedCase) {
    return (value: 0.6, label: 'Fair', color: EchoTheme.warning);
  }

  // Weak
  return (value: 0.3, label: 'Weak', color: EchoTheme.danger);
}

class RegisterScreen extends ConsumerStatefulWidget {
  const RegisterScreen({super.key});

  @override
  ConsumerState<RegisterScreen> createState() => _RegisterScreenState();
}

class _RegisterScreenState extends ConsumerState<RegisterScreen> {
  final _formKey = GlobalKey<FormState>();
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();

  Future<Map<String, String?>>? _versionFuture;

  /// Tracks password text for the strength indicator (rebuilt via setState).
  String _passwordText = '';

  bool _obscurePassword = true;
  bool _obscureConfirm = true;
  bool _passwordFocused = false;
  bool _hasAttemptedSubmit = false;

  final FocusNode _passwordFocusNode = FocusNode();

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_onPasswordChanged);
    _passwordFocusNode.addListener(() {
      setState(() {
        _passwordFocused = _passwordFocusNode.hasFocus;
      });
    });
  }

  @override
  void dispose() {
    _passwordController.removeListener(_onPasswordChanged);
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _passwordFocusNode.dispose();
    super.dispose();
  }

  void _onPasswordChanged() {
    setState(() {
      _passwordText = _passwordController.text;
    });
  }

  Future<void> _register() async {
    setState(() {
      _hasAttemptedSubmit = true;
    });
    if (!_formKey.currentState!.validate()) return;

    final auth = ref.read(authProvider.notifier);
    await auth.register(
      _usernameController.text.trim(),
      _passwordController.text,
    );

    // After successful registration, redirect to onboarding wizard
    if (mounted && ref.read(authProvider).isLoggedIn) {
      context.go('/onboarding');
    }
  }

  String? _validateUsername(String? value) {
    if (value == null || value.trim().isEmpty) {
      return 'Username is required';
    }
    final trimmed = value.trim();
    if (trimmed.length < 3 || trimmed.length > 32) {
      return 'Must be 3-32 characters';
    }
    if (!RegExp(r'^[a-zA-Z0-9_]+$').hasMatch(trimmed)) {
      return 'Only letters, numbers, and underscores';
    }
    return null;
  }

  String? _validatePassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Password is required';
    }
    if (value.length < 8) {
      return 'Must be at least 8 characters';
    }
    if (value.length > 128) {
      return 'Must be 128 characters or fewer';
    }
    return null;
  }

  String? _validateConfirmPassword(String? value) {
    if (value == null || value.isEmpty) {
      return 'Please confirm your password';
    }
    if (value != _passwordController.text) {
      return 'Passwords do not match';
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    final strength = _passwordStrength(_passwordText);

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
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        _buildHeader(context),
                        const SizedBox(height: 32),
                        _buildUsernameField(),
                        const SizedBox(height: 16),
                        _buildPasswordField(),
                        if (_passwordText.isNotEmpty ||
                            _passwordFocused ||
                            _hasAttemptedSubmit)
                          _buildPasswordHint(context)
                        else
                          const SizedBox.shrink(),
                        _buildStrengthIndicator(context, strength),
                        const SizedBox(height: 12),
                        _buildConfirmPasswordField(),
                        _buildErrorMessage(context, authState),
                        const SizedBox(height: 24),
                        _buildSubmitButton(authState),
                        const SizedBox(height: 12),
                        TextButton(
                          onPressed: () => context.go('/login'),
                          style: TextButton.styleFrom(
                            foregroundColor: context.textSecondary,
                          ),
                          child: const Text('Already have an account? Log in'),
                        ),
                      ],
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

  Widget _buildHeader(BuildContext context) {
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
          'Create your account',
          style: Theme.of(context).textTheme.bodyMedium?.copyWith(fontSize: 16),
        ),
      ],
    );
  }

  Widget _buildUsernameField() {
    return TextFormField(
      controller: _usernameController,
      autofillHints: const [AutofillHints.newUsername],
      decoration: const InputDecoration(
        labelText: 'Username',
        border: OutlineInputBorder(),
      ),
      textInputAction: TextInputAction.next,
      validator: _validateUsername,
    );
  }

  Widget _buildPasswordField() {
    return TextFormField(
      controller: _passwordController,
      obscureText: _obscurePassword,
      autofillHints: const [AutofillHints.newPassword],
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
      focusNode: _passwordFocusNode,
      textInputAction: TextInputAction.next,
      validator: _validatePassword,
    );
  }

  Widget _buildStrengthIndicator(
    BuildContext context,
    ({double value, String label, Color color}) strength,
  ) {
    if (_passwordText.isEmpty) return const SizedBox.shrink();
    return Column(
      children: [
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: ClipRRect(
                borderRadius: BorderRadius.circular(2),
                child: LinearProgressIndicator(
                  value: strength.value,
                  backgroundColor: Theme.of(
                    context,
                  ).colorScheme.surfaceContainerHighest,
                  color: strength.color,
                  minHeight: 4,
                ),
              ),
            ),
            const SizedBox(width: 8),
            Text(
              strength.label,
              style: TextStyle(color: strength.color, fontSize: 12),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildPasswordHint(BuildContext context) {
    return Align(
      alignment: Alignment.centerLeft,
      child: Text(
        '8-128 characters required',
        style: TextStyle(color: context.textMuted, fontSize: 12),
      ),
    );
  }

  Widget _buildConfirmPasswordField() {
    return TextFormField(
      controller: _confirmController,
      obscureText: _obscureConfirm,
      // No autofill hint here: when both password fields advertise
      // newPassword, password managers fill both with the same generated
      // value and silently mask mismatches.
      autofillHints: const [],
      decoration: InputDecoration(
        labelText: 'Confirm password',
        border: const OutlineInputBorder(),
        suffixIcon: IconButton(
          icon: Icon(_obscureConfirm ? Icons.visibility_off : Icons.visibility),
          onPressed: () => setState(() => _obscureConfirm = !_obscureConfirm),
          constraints: const BoxConstraints(minWidth: 44, minHeight: 44),
          padding: EdgeInsets.zero,
          visualDensity: VisualDensity.compact,
        ),
      ),
      onFieldSubmitted: (_) => _register(),
      validator: _validateConfirmPassword,
    );
  }

  Widget _buildErrorMessage(BuildContext context, AuthState authState) {
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

  Widget _buildSubmitButton(AuthState authState) {
    return SizedBox(
      width: double.infinity,
      child: Semantics(
        button: true,
        label: 'register',
        child: FilledButton(
          onPressed: authState.isLoading ? null : _register,
          child: authState.isLoading
              ? const SizedBox(
                  height: 20,
                  width: 20,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create account'),
        ),
      ),
    );
  }
}
