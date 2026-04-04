import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../utils/version_utils.dart';
import '../version.dart';
import '../theme/echo_theme.dart';
import '../widgets/echo_logo_icon.dart';

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
    return (value: 1.0, label: 'Strong', color: Colors.green);
  }

  // Fair: 10+ chars or mixed case
  if (length >= 10 || hasMixedCase) {
    return (value: 0.6, label: 'Fair', color: Colors.orange);
  }

  // Weak
  return (value: 0.3, label: 'Weak', color: Colors.red);
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

  @override
  void initState() {
    super.initState();
    _passwordController.addListener(_onPasswordChanged);
  }

  @override
  void dispose() {
    _passwordController.removeListener(_onPasswordChanged);
    _usernameController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    super.dispose();
  }

  void _onPasswordChanged() {
    setState(() {
      _passwordText = _passwordController.text;
    });
  }

  Future<void> _register() async {
    if (!_formKey.currentState!.validate()) return;

    final auth = ref.read(authProvider.notifier);
    await auth.register(
      _usernameController.text.trim(),
      _passwordController.text,
    );
    // Crypto init happens in contacts_screen._initData() after navigation
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);
    final strength = _passwordStrength(_passwordText);

    _versionFuture ??= fetchVersionInfo(serverUrl);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Form(
              key: _formKey,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const EchoLogoIcon(size: 30),
                  const SizedBox(height: 10),
                  Text(
                    'Create Account',
                    style: Theme.of(context).textTheme.headlineLarge,
                  ),
                  const SizedBox(height: 32),
                  TextFormField(
                    controller: _usernameController,
                    decoration: const InputDecoration(
                      labelText: 'Username',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (value) {
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
                    },
                  ),
                  const SizedBox(height: 16),
                  TextFormField(
                    controller: _passwordController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Password',
                      border: OutlineInputBorder(),
                    ),
                    textInputAction: TextInputAction.next,
                    validator: (value) {
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
                    },
                  ),
                  // Password strength indicator
                  if (_passwordText.isNotEmpty) ...[
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
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: Text(
                      '8-128 characters required',
                      style: TextStyle(color: context.textMuted, fontSize: 12),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextFormField(
                    controller: _confirmController,
                    obscureText: true,
                    decoration: const InputDecoration(
                      labelText: 'Confirm password',
                      border: OutlineInputBorder(),
                    ),
                    onFieldSubmitted: (_) => _register(),
                    validator: (value) {
                      if (value == null || value.isEmpty) {
                        return 'Please confirm your password';
                      }
                      if (value != _passwordController.text) {
                        return 'Passwords do not match';
                      }
                      return null;
                    },
                  ),
                  if (authState.error != null) ...[
                    const SizedBox(height: 12),
                    Text(
                      authState.error!,
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                  const SizedBox(height: 24),
                  SizedBox(
                    width: double.infinity,
                    child: FilledButton(
                      onPressed: authState.isLoading ? null : _register,
                      child: authState.isLoading
                          ? const SizedBox(
                              height: 20,
                              width: 20,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Register'),
                    ),
                  ),
                  const SizedBox(height: 12),
                  TextButton(
                    onPressed: () => context.go('/login'),
                    child: const Text('Already have an account? Login'),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Echo v$appVersion',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: context.textMuted, fontSize: 11),
                  ),
                  FutureBuilder<Map<String, String?>>(
                    future: _versionFuture,
                    builder: (context, snapshot) {
                      if (!snapshot.hasData) {
                        return const SizedBox.shrink();
                      }
                      final info = snapshot.data!;
                      final serverVersion = info['serverVersion'];
                      final serverHost = info['serverHost'];
                      final webVersion = info['webVersion'];

                      final serverText = serverVersion != null
                          ? 'Server: $serverHost v$serverVersion'
                          : 'Server: unreachable';
                      final serverColor = serverVersion != null
                          ? context.textMuted
                          : EchoTheme.warning;

                      return Column(
                        children: [
                          const SizedBox(height: 2),
                          Text(
                            serverText,
                            textAlign: TextAlign.center,
                            style: TextStyle(color: serverColor, fontSize: 11),
                          ),
                          if (kIsWeb && webVersion != null) ...[
                            const SizedBox(height: 2),
                            Text(
                              'Web: v$webVersion',
                              textAlign: TextAlign.center,
                              style: TextStyle(
                                color: context.textMuted,
                                fontSize: 11,
                              ),
                            ),
                          ],
                        ],
                      );
                    },
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
