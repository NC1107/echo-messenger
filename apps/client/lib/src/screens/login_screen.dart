import 'package:flutter/foundation.dart' show kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';

import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../utils/version_utils.dart';
import '../version.dart';
import '../theme/echo_theme.dart';
import '../widgets/echo_logo_icon.dart';

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

  Future<void> _login() async {
    if (!_formKey.currentState!.validate()) return;
    final auth = ref.read(authProvider.notifier);
    await auth.login(_usernameController.text.trim(), _passwordController.text);
    if (!mounted) return;
    if (ref.read(authProvider).error != null) {
      _passwordController.clear();
    }
    // Crypto init happens in contacts_screen._initData() after navigation
  }

  @override
  Widget build(BuildContext context) {
    super.build(context);
    final authState = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);

    _versionFuture ??= fetchVersionInfo(serverUrl);

    return Scaffold(
      body: Stack(
        children: [
          // Subtle radial gradient fills the otherwise-empty scaffold so the
          // login form does not float in a flat black void.
          Positioned.fill(
            child: Container(
              decoration: BoxDecoration(
                gradient: RadialGradient(
                  center: Alignment.topCenter,
                  radius: 1.4,
                  colors: [
                    context.accent.withValues(alpha: 0.06),
                    context.mainBg,
                  ],
                  stops: const [0.0, 0.6],
                ),
              ),
            ),
          ),
          SafeArea(
            child: Center(
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 400),
                child: SingleChildScrollView(
                  padding: const EdgeInsets.fromLTRB(24, 24, 24, 56),
                  child: Form(
                    key: _formKey,
                    child: AutofillGroup(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
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
                          const SizedBox(height: 12),
                          SizedBox(
                            height: 44,
                            child: TextButton(
                              onPressed: () => context.go('/register'),
                              child: const Text('Create an account'),
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
            child: SafeArea(top: false, child: _buildVersionInfo()),
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
            Text('Echo', style: Theme.of(context).textTheme.headlineLarge),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          'Encrypted messaging',
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
      child: FilledButton(
        onPressed: authState.isLoading ? null : _login,
        child: authState.isLoading
            ? const SizedBox(
                height: 20,
                width: 20,
                child: CircularProgressIndicator(strokeWidth: 2),
              )
            : const Text('Login'),
      ),
    );
  }

  Widget _buildVersionInfo() {
    final appLine = Text(
      'Echo v$appVersion',
      textAlign: TextAlign.center,
      style: TextStyle(color: context.textMuted, fontSize: 11),
    );
    if (!kDebugMode) return appLine;
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        appLine,
        FutureBuilder<Map<String, String?>>(
          future: _versionFuture,
          builder: (context, snapshot) {
            if (!snapshot.hasData) return const SizedBox.shrink();
            return _buildServerVersionDetails(snapshot.data!);
          },
        ),
      ],
    );
  }

  Widget _buildServerVersionDetails(Map<String, String?> info) {
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
            style: TextStyle(color: context.textMuted, fontSize: 11),
          ),
        ],
      ],
    );
  }
}
