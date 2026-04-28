import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../providers/update_provider.dart';
import '../../providers/websocket_provider.dart';
import '../../services/debug_log_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../../version.dart';

class AboutSection extends ConsumerStatefulWidget {
  const AboutSection({super.key});

  @override
  ConsumerState<AboutSection> createState() => _AboutSectionState();
}

class _AboutSectionState extends ConsumerState<AboutSection> {
  bool _serverOnline = false;
  bool _checkingHealth = true;
  String? _serverVersion;

  Color get _serverHealthColor {
    if (_checkingHealth) return EchoTheme.warning;
    if (_serverOnline) return EchoTheme.online;
    return EchoTheme.danger;
  }

  String get _serverHealthLabel {
    if (_checkingHealth) return 'Checking...';
    if (_serverOnline) return 'Online';
    return 'Offline';
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _checkServerHealth();
    });
  }

  Future<void> _checkServerHealth() async {
    setState(() => _checkingHealth = true);
    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await http
          .get(Uri.parse('$serverUrl/api/health'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode == 200 && mounted) {
        String? version;
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          version = data['version'] as String?;
        } catch (_) {}
        setState(() {
          _serverOnline = true;
          _checkingHealth = false;
          _serverVersion = version;
        });
      } else if (mounted) {
        setState(() {
          _serverOnline = false;
          _checkingHealth = false;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _serverOnline = false;
          _checkingHealth = false;
        });
      }
    }
  }

  Future<void> _showChangeServerDialog() async {
    final currentUrl = ref.read(serverUrlProvider);
    final controller = TextEditingController(text: currentUrl);

    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Change Server',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              'Enter the URL of an Echo server. You will need to log in again after changing servers.',
              style: TextStyle(
                color: context.textSecondary,
                fontSize: 13,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 16),
            TextField(
              controller: controller,
              style: TextStyle(color: context.textPrimary, fontSize: 14),
              decoration: const InputDecoration(
                labelText: 'Server URL',
                hintText: 'https://echo-messenger.us',
              ),
              keyboardType: TextInputType.url,
              autofocus: true,
            ),
            const SizedBox(height: 8),
            TextButton(
              onPressed: () {
                controller.text = defaultServerUrl;
              },
              child: const Text(
                'Reset to default',
                style: TextStyle(fontSize: 12),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () =>
                Navigator.pop(dialogContext, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );

    if (newUrl != null && newUrl.isNotEmpty && newUrl != currentUrl) {
      await ref.read(serverUrlProvider.notifier).setUrl(newUrl);
      await _checkServerHealth();
      if (mounted) {
        ToastService.show(
          context,
          'Server URL updated. Please log out and log in again for changes to take full effect.',
          type: ToastType.info,
        );
      }
    }
  }

  Future<void> _deleteAccount() async {
    final username = ref.read(authProvider).username ?? '';
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) {
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final matches = controller.text == username;
            return AlertDialog(
              backgroundColor: context.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: context.border),
              ),
              title: const Text(
                'Delete Account',
                style: TextStyle(
                  color: EchoTheme.danger,
                  fontSize: 18,
                  fontWeight: FontWeight.w600,
                ),
              ),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'This will permanently delete your account and all data. '
                    'This cannot be undone.',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Type your username to confirm:',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    style: TextStyle(color: context.textPrimary, fontSize: 14),
                    decoration: InputDecoration(hintText: username),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, false),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: matches
                      ? () => Navigator.pop(dialogContext, true)
                      : null,
                  style: FilledButton.styleFrom(
                    backgroundColor: EchoTheme.danger,
                  ),
                  child: const Text('Delete My Account'),
                ),
              ],
            );
          },
        );
      },
    );

    if (confirmed != true) return;

    final serverUrl = ref.read(serverUrlProvider);
    try {
      final response = await ref
          .read(authProvider.notifier)
          .authenticatedRequest(
            (token) => http.delete(
              Uri.parse('$serverUrl/api/users/me'),
              headers: {'Authorization': 'Bearer $token'},
            ),
          );

      if (!mounted) return;

      if (response.statusCode == 200 || response.statusCode == 204) {
        // Clear all local data and navigate to login
        ref.read(websocketProvider.notifier).disconnect();
        ref.read(chatProvider.notifier).clear();
        await ref.read(cryptoProvider.notifier).resetState();
        ref.read(authProvider.notifier).logout();
        if (mounted) {
          ToastService.show(
            context,
            'Account deleted successfully.',
            type: ToastType.success,
          );
          context.go('/login');
        }
      } else {
        String errorMsg = 'Failed to delete account';
        try {
          final data = jsonDecode(response.body) as Map<String, dynamic>;
          errorMsg = data['error'] as String? ?? errorMsg;
        } catch (_) {}
        ToastService.show(context, errorMsg, type: ToastType.error);
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Network error. Please try again.',
          type: ToastType.error,
        );
      }
    }
  }

  Widget _buildCheckForUpdates() {
    final update = ref.watch(updateProvider);
    return Row(
      children: [
        OutlinedButton.icon(
          onPressed: update.checking
              ? null
              : () => ref.read(updateProvider.notifier).check(force: true),
          icon: update.checking
              ? SizedBox(
                  width: 14,
                  height: 14,
                  child: CircularProgressIndicator(
                    strokeWidth: 2,
                    color: context.textMuted,
                  ),
                )
              : const Icon(Icons.refresh, size: 16),
          label: Text(update.checking ? 'Checking...' : 'Check for Updates'),
          style: OutlinedButton.styleFrom(
            foregroundColor: context.textSecondary,
            side: BorderSide(color: context.border),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(8),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            textStyle: const TextStyle(fontSize: 13),
          ),
        ),
        const SizedBox(width: 12),
        if (update.latestVersion != null && !update.checking)
          Text(
            update.updateAvailable
                ? 'v${update.latestVersion} available'
                : 'Up to date',
            style: TextStyle(
              color: update.updateAvailable
                  ? context.accent
                  : context.textMuted,
              fontSize: 13,
            ),
          ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Echo Messenger',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Client v$appVersion',
          style: TextStyle(color: context.textMuted, fontSize: 14),
        ),
        SelectableText(
          'Build $appCommit'
          '${appBuildTime.isEmpty ? '' : ' · $appBuildTime'}',
          style: TextStyle(
            color: context.textMuted,
            fontSize: 12,
            fontFamily: 'monospace',
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Upload limit: 100 MB (Cloudflare cap; larger files need a chunked '
          'upload — not yet implemented).',
          style: TextStyle(color: context.textMuted, fontSize: 11, height: 1.4),
        ),
        const SizedBox(height: 16),
        _buildCheckForUpdates(),
        const SizedBox(height: 24),
        Divider(color: context.border),
        const SizedBox(height: 16),
        // Server info (merged from former Server section)
        Text(
          'Server',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 12),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.dns_outlined,
            color: context.textSecondary,
            size: 22,
          ),
          title: Text(
            'Connected to',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            Uri.tryParse(ref.watch(serverUrlProvider))?.host ??
                ref.watch(serverUrlProvider),
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.circle, color: _serverHealthColor, size: 12),
          title: Text(
            'Status: $_serverHealthLabel',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            'Server v${_serverVersion ?? "unknown"}',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: IconButton(
            icon: Icon(Icons.refresh, color: context.textMuted, size: 20),
            tooltip: 'Refresh',
            onPressed: _checkServerHealth,
          ),
        ),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.swap_horiz_outlined,
            color: context.textSecondary,
            size: 22,
          ),
          title: Text(
            'Change server',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: context.textMuted,
            size: 20,
          ),
          onTap: _showChangeServerDialog,
        ),
        const SizedBox(height: 16),
        Divider(color: context.border),
        const SizedBox(height: 16),
        // Debug logs entry (absorbed from former Debug section).
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.bug_report_outlined,
            color: context.textSecondary,
            size: 22,
          ),
          title: Text(
            'Debug Logs',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            'View recent in-app log entries.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: context.textMuted,
            size: 20,
          ),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const _DebugLogsSubpage(),
              ),
            );
          },
        ),
        const SizedBox(height: 16),
        Divider(color: context.border),
        const SizedBox(height: 16),
        Text(
          'Open source',
          style: TextStyle(
            color: context.accent,
            fontSize: 14,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Echo is a decentralized, end-to-end encrypted messenger. '
          'Contributions and self-hosting are welcome.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 32),
        Divider(color: context.border),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _deleteAccount,
            icon: const Icon(Icons.delete_forever_outlined, size: 18),
            label: const Text('Delete Account'),
            style: OutlinedButton.styleFrom(
              foregroundColor: EchoTheme.danger,
              side: const BorderSide(color: EchoTheme.danger),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Debug Logs subpage (absorbed from former DebugSection).
// Pushed from the About row above. Shows the in-memory log buffer with
// copy-all and clear actions.
// ---------------------------------------------------------------------------

class _DebugLogsSubpage extends StatefulWidget {
  const _DebugLogsSubpage();

  @override
  State<_DebugLogsSubpage> createState() => _DebugLogsSubpageState();
}

class _DebugLogsSubpageState extends State<_DebugLogsSubpage> {
  final _scrollController = ScrollController();
  final _logService = DebugLogService.instance;

  @override
  void initState() {
    super.initState();
    _logService.addListener(_onLogsChanged);
  }

  @override
  void dispose() {
    _logService.removeListener(_onLogsChanged);
    _scrollController.dispose();
    super.dispose();
  }

  void _copyAllLogs(List<DebugLogEntry> entries) {
    final buffer = StringBuffer();
    for (final e in entries) {
      final h = e.timestamp.hour.toString().padLeft(2, '0');
      final m = e.timestamp.minute.toString().padLeft(2, '0');
      final s = e.timestamp.second.toString().padLeft(2, '0');
      final level = switch (e.level) {
        LogLevel.info => 'INF',
        LogLevel.warning => 'WRN',
        LogLevel.error => 'ERR',
      };
      buffer.writeln('$h:$m:$s [$level] ${e.source}: ${e.message}');
    }
    Clipboard.setData(ClipboardData(text: buffer.toString()));
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('${entries.length} log entries copied to clipboard'),
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  void _onLogsChanged() {
    if (!mounted) return;
    setState(() {});
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 150),
          curve: Curves.easeOut,
        );
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final entries = _logService.entries;

    return Scaffold(
      backgroundColor: context.mainBg,
      appBar: AppBar(
        backgroundColor: context.sidebarBg,
        title: Text(
          'Debug Logs',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        leading: IconButton(
          icon: Icon(Icons.arrow_back, color: context.textSecondary),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(24, 16, 24, 0),
            child: Row(
              children: [
                const Spacer(),
                OutlinedButton.icon(
                  onPressed: entries.isEmpty
                      ? null
                      : () => _copyAllLogs(entries),
                  icon: const Icon(Icons.copy_outlined, size: 16),
                  label: const Text('Copy All'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.textSecondary,
                    disabledForegroundColor: context.textMuted,
                    side: BorderSide(color: context.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: entries.isEmpty ? null : _logService.clear,
                  icon: const Icon(Icons.delete_sweep_outlined, size: 16),
                  label: const Text('Clear Logs'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: context.textSecondary,
                    disabledForegroundColor: context.textMuted,
                    side: BorderSide(color: context.border),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    textStyle: const TextStyle(fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 24),
            child: Text(
              '${entries.length} entries (max ${DebugLogService.maxEntries})',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
          ),
          const SizedBox(height: 12),
          Expanded(
            child: entries.isEmpty
                ? Center(
                    child: Text(
                      'No debug logs yet.',
                      style: TextStyle(color: context.textMuted, fontSize: 14),
                    ),
                  )
                : ListView.builder(
                    controller: _scrollController,
                    padding: const EdgeInsets.fromLTRB(24, 0, 24, 24),
                    itemCount: entries.length,
                    itemBuilder: (context, index) =>
                        _DebugLogEntryTile(entry: entries[index]),
                  ),
          ),
        ],
      ),
    );
  }
}

class _DebugLogEntryTile extends StatelessWidget {
  final DebugLogEntry entry;

  const _DebugLogEntryTile({required this.entry});

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 72,
            child: Text(
              _formatTime(entry.timestamp),
              style: GoogleFonts.jetBrainsMono(
                color: context.textMuted,
                fontSize: 11,
              ),
            ),
          ),
          const SizedBox(width: 6),
          _DebugLevelBadge(level: entry.level),
          const SizedBox(width: 8),
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
            decoration: BoxDecoration(
              color: context.surfaceHover,
              borderRadius: BorderRadius.circular(4),
            ),
            child: Text(
              entry.source,
              style: GoogleFonts.jetBrainsMono(
                color: context.textSecondary,
                fontSize: 11,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              entry.message,
              style: GoogleFonts.jetBrainsMono(
                color: context.textPrimary,
                fontSize: 12,
                height: 1.4,
              ),
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime dt) {
    final h = dt.hour.toString().padLeft(2, '0');
    final m = dt.minute.toString().padLeft(2, '0');
    final s = dt.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }
}

class _DebugLevelBadge extends StatelessWidget {
  final LogLevel level;

  const _DebugLevelBadge({required this.level});

  @override
  Widget build(BuildContext context) {
    final (String label, Color color) = switch (level) {
      LogLevel.info => ('INF', EchoTheme.online),
      LogLevel.warning => ('WRN', EchoTheme.warning),
      LogLevel.error => ('ERR', EchoTheme.danger),
    };

    return Container(
      width: 32,
      alignment: Alignment.center,
      padding: const EdgeInsets.symmetric(vertical: 1),
      decoration: BoxDecoration(
        color: color.withValues(alpha: 0.15),
        borderRadius: BorderRadius.circular(4),
      ),
      child: Text(
        label,
        style: GoogleFonts.jetBrainsMono(
          color: color,
          fontSize: 10,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}
