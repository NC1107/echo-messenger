import 'dart:convert';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:http/http.dart' as http;

import '../providers/auth_provider.dart';
import '../providers/server_url_provider.dart';
import '../version.dart';
import '../theme/echo_theme.dart';

class LoginScreen extends ConsumerStatefulWidget {
  const LoginScreen({super.key});

  @override
  ConsumerState<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends ConsumerState<LoginScreen> {
  final _usernameController = TextEditingController();
  final _passwordController = TextEditingController();

  Future<Map<String, String?>>? _versionFuture;

  @override
  void dispose() {
    _usernameController.dispose();
    _passwordController.dispose();
    super.dispose();
  }

  Future<void> _login() async {
    final auth = ref.read(authProvider.notifier);
    await auth.login(_usernameController.text.trim(), _passwordController.text);
    // Crypto init happens in contacts_screen._initData() after navigation
  }

  Future<Map<String, String?>> _fetchVersionInfo(String serverUrl) async {
    String? serverVersion;
    String? serverHost;
    String? webVersion;

    // Fetch server version from /api/health
    try {
      final uri = Uri.parse('$serverUrl/api/health');
      serverHost = uri.host;
      final resp = await http.get(uri).timeout(const Duration(seconds: 5));
      if (resp.statusCode == 200) {
        final body = jsonDecode(resp.body) as Map<String, dynamic>;
        serverVersion = body['version'] as String?;
      }
    } catch (_) {
      // serverVersion stays null
    }

    // Fetch web container version (web only)
    if (kIsWeb) {
      try {
        final resp = await http
            .get(Uri.parse('/version.txt'))
            .timeout(const Duration(seconds: 3));
        if (resp.statusCode == 200) {
          final text = resp.body.trim();
          if (text.isNotEmpty && text.length < 30) {
            webVersion = text;
          }
        }
      } catch (_) {
        // webVersion stays null
      }
    }

    return {
      'serverVersion': serverVersion,
      'serverHost': serverHost,
      'webVersion': webVersion,
    };
  }

  @override
  Widget build(BuildContext context) {
    final authState = ref.watch(authProvider);
    final serverUrl = ref.watch(serverUrlProvider);

    _versionFuture ??= _fetchVersionInfo(serverUrl);

    return Scaffold(
      body: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 400),
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                Text('Echo', style: Theme.of(context).textTheme.headlineLarge),
                const SizedBox(height: 8),
                Text(
                  'Encrypted messaging',
                  style: Theme.of(context).textTheme.bodyMedium,
                ),
                const SizedBox(height: 32),
                TextField(
                  controller: _usernameController,
                  decoration: const InputDecoration(
                    labelText: 'Username',
                    border: OutlineInputBorder(),
                  ),
                  textInputAction: TextInputAction.next,
                ),
                const SizedBox(height: 16),
                TextField(
                  controller: _passwordController,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Password',
                    border: OutlineInputBorder(),
                  ),
                  onSubmitted: (_) => _login(),
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
                    onPressed: authState.isLoading ? null : _login,
                    child: authState.isLoading
                        ? const SizedBox(
                            height: 20,
                            width: 20,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Text('Login'),
                  ),
                ),
                const SizedBox(height: 12),
                TextButton(
                  onPressed: () => context.go('/register'),
                  child: const Text('Create an account'),
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
    );
  }
}
