// Shared "Server: host ›" affordance + the switch-server dialog used on the
// login and register screens. Tapping the subtitle opens the dialog which
// lists known servers + accepts a custom URL. The custom URL is pre-flighted
// against GET /api/server-info before the switch transaction runs so a typo
// can't log the user out of the active server (#1063).
import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:http/http.dart' as http;

import '../../providers/server_url_provider.dart';
import '../../theme/echo_theme.dart';

/// Small subtitle row shown under the tagline: "Server: echo-messenger.us ›"
///
/// Tapping it opens an inline dialog to switch to a known server or enter a
/// custom URL. Public so the login + register screens can share one component
/// — a self-host user must be able to point at their server BEFORE creating an
/// account on the default one.
class ServerSubtitle extends ConsumerStatefulWidget {
  final String serverUrl;

  const ServerSubtitle({super.key, required this.serverUrl});

  @override
  ConsumerState<ServerSubtitle> createState() => _ServerSubtitleState();
}

class _ServerSubtitleState extends ConsumerState<ServerSubtitle> {
  String _host(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.host.isNotEmpty) return parsed.host;
    return url;
  }

  Future<void> _showSwitchDialog() async {
    final urlController = TextEditingController();
    final servers = ref.read(knownServersProvider);

    await showDialog<void>(
      context: context,
      builder: (ctx) => _ServerSwitchDialog(
        currentUrl: widget.serverUrl,
        knownServers: servers,
        urlController: urlController,
        onSwitch: (url) async {
          Navigator.of(ctx).pop();
          await ref.read(serverUrlProvider.notifier).switchTo(url);
        },
      ),
    );
    urlController.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final host = _host(widget.serverUrl);
    return Semantics(
      button: true,
      label: 'switch server',
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: _showSwitchDialog,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                'Server: $host',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              const SizedBox(width: 2),
              Icon(Icons.chevron_right, size: 14, color: context.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

/// Dialog shown when the user taps [ServerSubtitle].
///
/// Lists [knownServers] as quick-switch tiles and provides a text field for a
/// custom URL. The custom URL is pre-flighted against `/api/server-info` so a
/// typo cannot log the user out of their currently-active server.
class _ServerSwitchDialog extends ConsumerStatefulWidget {
  final String currentUrl;
  final List<KnownServer> knownServers;
  final TextEditingController urlController;
  final Future<void> Function(String url) onSwitch;

  const _ServerSwitchDialog({
    required this.currentUrl,
    required this.knownServers,
    required this.urlController,
    required this.onSwitch,
  });

  @override
  ConsumerState<_ServerSwitchDialog> createState() =>
      _ServerSwitchDialogState();
}

class _ServerSwitchDialogState extends ConsumerState<_ServerSwitchDialog> {
  bool _switching = false;
  String? _error;

  String _host(String url) {
    final parsed = Uri.tryParse(url);
    if (parsed != null && parsed.host.isNotEmpty) return parsed.host;
    return url;
  }

  /// Pre-flight a custom URL against `/api/server-info` before the switch
  /// transaction runs. Returns true if the URL is reachable and serves a
  /// 2xx response; false otherwise (an inline error is stored in `_error`).
  /// Known-server taps skip this — they were reachable when added.
  Future<bool> _preflight(String normalized) async {
    try {
      final response = await http
          .get(Uri.parse('$normalized/api/server-info'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200) return true;
      setState(() => _error = 'Server returned HTTP ${response.statusCode}.');
      return false;
    } catch (e) {
      setState(() => _error = 'Could not reach $normalized.');
      return false;
    }
  }

  Future<void> _switchKnown(String url) async {
    setState(() {
      _switching = true;
      _error = null;
    });
    try {
      await widget.onSwitch(url);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  Future<void> _switchCustom(String raw) async {
    final trimmed = raw.trim();
    if (trimmed.isEmpty) return;
    final normalized = trimmed.endsWith('/')
        ? trimmed.substring(0, trimmed.length - 1)
        : trimmed;

    setState(() {
      _switching = true;
      _error = null;
    });
    final ok = await _preflight(normalized);
    if (!ok) {
      if (mounted) setState(() => _switching = false);
      return;
    }
    try {
      await widget.onSwitch(normalized);
    } finally {
      if (mounted) setState(() => _switching = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: context.surface,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: context.border),
      ),
      title: Text(
        'Switch server',
        style: TextStyle(
          color: context.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w600,
        ),
      ),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (widget.knownServers.isNotEmpty) ...[
              Text(
                'Known servers',
                style: TextStyle(
                  color: context.textSecondary,
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
              const SizedBox(height: 8),
              for (final s in widget.knownServers)
                _ServerTile(
                  host: _host(s.url),
                  isActive: s.url == widget.currentUrl,
                  onTap: _switching || s.url == widget.currentUrl
                      ? null
                      : () => _switchKnown(s.url),
                ),
              const SizedBox(height: 16),
            ],
            Text(
              'Custom URL',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 12,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            TextField(
              controller: widget.urlController,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: InputDecoration(
                hintText: 'https://your-server.example.com',
                hintStyle: TextStyle(color: context.textMuted, fontSize: 13),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
              ),
              onSubmitted: _switchCustom,
            ),
            if (_error != null) ...[
              const SizedBox(height: 8),
              Text(
                _error!,
                style: const TextStyle(color: EchoTheme.danger, fontSize: 12),
              ),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: _switching ? null : () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
        FilledButton(
          onPressed: _switching
              ? null
              : () => _switchCustom(widget.urlController.text),
          child: _switching
              ? const SizedBox(
                  width: 16,
                  height: 16,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Connect'),
        ),
      ],
    );
  }
}

class _ServerTile extends StatelessWidget {
  final String host;
  final bool isActive;
  final VoidCallback? onTap;

  const _ServerTile({
    required this.host,
    required this.isActive,
    required this.onTap,
  });

  @override
  Widget build(BuildContext context) {
    return ListTile(
      dense: true,
      contentPadding: const EdgeInsets.symmetric(horizontal: 4),
      leading: Icon(
        isActive ? Icons.radio_button_checked : Icons.radio_button_off,
        size: 18,
        color: isActive ? context.accent : context.textMuted,
      ),
      title: Text(
        host,
        style: TextStyle(
          color: context.textPrimary,
          fontSize: 14,
          fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
        ),
      ),
      onTap: onTap,
    );
  }
}
