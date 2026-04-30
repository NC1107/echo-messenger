import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:go_router/go_router.dart';
import 'package:google_fonts/google_fonts.dart';
import 'package:http/http.dart' as http;
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/auth_provider.dart';
import '../../providers/chat_provider.dart';
import '../../providers/crypto_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../providers/update_provider.dart';
import '../../providers/websocket_provider.dart';
import '../../services/debug_log_service.dart';
import '../../services/message_cache.dart';
import '../../services/secure_key_store.dart';
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
        setState(() {
          _serverOnline = true;
          _checkingHealth = false;
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

  /// "Add server" dialog with a pre-flight `GET /api/server-info` check.
  /// On success, captures `server_id` so future PRs can pin server identity
  /// across hostname changes.
  Future<void> _showAddServerDialog() async {
    final controller = TextEditingController();

    final newUrl = await showDialog<String>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Add server',
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
              'Enter the URL of an Echo server. The URL is checked before '
              "it's added so we can fail fast on typos.",
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
            child: const Text('Check & add'),
          ),
        ],
      ),
    );

    if (newUrl == null || newUrl.isEmpty) return;
    final normalized = newUrl.endsWith('/')
        ? newUrl.substring(0, newUrl.length - 1)
        : newUrl;

    // Pre-flight: GET /api/server-info. 4xx/5xx => surface error and bail.
    String? serverId;
    try {
      final response = await http
          .get(Uri.parse('$normalized/api/server-info'))
          .timeout(const Duration(seconds: 5));
      if (response.statusCode != 200) {
        if (mounted) {
          ToastService.show(
            context,
            'Server returned HTTP ${response.statusCode}. Not added.',
            type: ToastType.error,
          );
        }
        return;
      }
      try {
        final data = jsonDecode(response.body) as Map<String, dynamic>;
        serverId = data['server_id'] as String?;
      } catch (_) {
        // server_info older than this build -- still treat as a valid add.
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Could not reach $normalized. Not added.',
          type: ToastType.error,
        );
      }
      return;
    }

    await ref
        .read(serverUrlProvider.notifier)
        .addKnownServer(url: normalized, serverId: serverId);

    if (mounted) {
      ToastService.show(context, 'Server added.', type: ToastType.success);
    }
  }

  /// Switch to a known server. Funnels through
  /// [ServerUrlNotifier.switchTo] so the logout-on-switch invariant holds.
  Future<void> _confirmAndSwitchTo(KnownServer target) async {
    final oldHost =
        Uri.tryParse(ref.read(serverUrlProvider))?.host ??
        ref.read(serverUrlProvider);

    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Switch server?',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          "You'll be logged out of $oldHost; messages and keys for both "
          'servers stay on this device.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Switch'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    await ref.read(serverUrlProvider.notifier).switchTo(target.url);
    if (!mounted) return;
    // The switch logged out the active session; route back to /login so
    // the user can re-authenticate against the new origin.
    context.go('/login');
  }

  /// Forget a known server: drop it from the list and best-effort wipe its
  /// scoped state on this device. The active server cannot be forgotten.
  Future<void> _confirmAndForget(KnownServer target) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Forget server?',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This deletes locally-stored keys and message cache for '
          '${Uri.tryParse(target.url)?.host ?? target.url}. '
          'The remote account is not affected.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.4,
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            style: FilledButton.styleFrom(backgroundColor: EchoTheme.danger),
            child: const Text('Forget'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;

    // Wipe scoped state. SecureKeyStore.deleteAllForUser only operates on
    // the currently-set scope, so we briefly set it for the user we have
    // stored against this server (if any), then restore the scope of the
    // currently-logged-in session afterwards.
    try {
      final host = Uri.tryParse(target.url)?.host ?? target.url;
      final keystore = SecureKeyStore.instance;
      final activeAuth = ref.read(authProvider);
      final activeUrl = ref.read(serverUrlProvider);
      final activeHost = Uri.tryParse(activeUrl)?.host ?? activeUrl;

      final prefs = await SharedPreferences.getInstance();
      final hostUserId = prefs.getString('echo_auth_user_id@$host');
      if (hostUserId != null && hostUserId.isNotEmpty) {
        keystore.setUserScope(hostUserId, host);
        try {
          await keystore.deleteAllForUser();
        } catch (_) {}
        await prefs.remove('echo_auth_user_id@$host');
        await prefs.remove('echo_auth_username@$host');
        try {
          await MessageCache.dropForServer(hostUserId, host);
        } catch (_) {}
      }

      // Restore the active session's scope so the rest of the running app
      // keeps decrypting / writing to its own keystore namespace.
      if (activeAuth.userId != null && activeAuth.userId!.isNotEmpty) {
        keystore.setUserScope(activeAuth.userId!, activeHost);
      } else {
        keystore.clearUserScope();
      }
    } catch (e) {
      debugPrint('[Settings] forget server cleanup error: $e');
    }

    await ref.read(serverUrlProvider.notifier).forget(target.url);
    if (mounted) {
      ToastService.show(context, 'Server forgotten.', type: ToastType.info);
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

  Widget _buildServersList() {
    final activeUrl = ref.watch(serverUrlProvider);
    final servers = ref.watch(knownServersProvider);
    if (servers.isEmpty) {
      // Should be rare post-migration, but covers a fresh install where the
      // user hasn't logged in yet.
      return ListTile(
        contentPadding: EdgeInsets.zero,
        leading: Icon(
          Icons.dns_outlined,
          color: context.textSecondary,
          size: 22,
        ),
        title: Text(
          Uri.tryParse(activeUrl)?.host ?? activeUrl,
          style: TextStyle(color: context.textPrimary, fontSize: 15),
        ),
        subtitle: Text(
          'Active (no other servers added yet)',
          style: TextStyle(color: context.textMuted, fontSize: 12),
        ),
        trailing: Icon(Icons.circle, color: _serverHealthColor, size: 10),
      );
    }

    // Active first, then by lastSeen desc.
    final sorted = [...servers]
      ..sort((a, b) {
        if (a.url == activeUrl) return -1;
        if (b.url == activeUrl) return 1;
        return b.lastSeen.compareTo(a.lastSeen);
      });

    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        for (final s in sorted) _serverRow(s, isActive: s.url == activeUrl),
      ],
    );
  }

  Widget _serverRow(KnownServer s, {required bool isActive}) {
    final host = Uri.tryParse(s.url)?.host ?? s.url;
    final subtitleParts = <String>[];
    if (s.lastUsername != null && s.lastUsername!.isNotEmpty) {
      subtitleParts.add(s.lastUsername!);
    }
    if (isActive) {
      subtitleParts.add(_serverHealthLabel.toLowerCase());
    }
    return ListTile(
      contentPadding: EdgeInsets.zero,
      leading: Icon(
        isActive ? Icons.dns : Icons.dns_outlined,
        color: context.textSecondary,
        size: 22,
      ),
      title: Row(
        children: [
          Flexible(
            child: Text(
              host,
              style: TextStyle(color: context.textPrimary, fontSize: 15),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          if (isActive) ...[
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: context.accent.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(4),
              ),
              child: Text(
                'CURRENT',
                style: TextStyle(
                  color: context.accent,
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
            const SizedBox(width: 6),
            Icon(Icons.circle, color: _serverHealthColor, size: 10),
          ],
        ],
      ),
      subtitle: subtitleParts.isEmpty
          ? null
          : Text(
              subtitleParts.join(' · '),
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
      trailing: PopupMenuButton<String>(
        icon: Icon(Icons.more_vert, color: context.textMuted, size: 20),
        onSelected: (value) async {
          if (value == 'switch') {
            await _confirmAndSwitchTo(s);
          } else if (value == 'forget') {
            await _confirmAndForget(s);
          }
        },
        itemBuilder: (_) => [
          if (!isActive)
            const PopupMenuItem(value: 'switch', child: Text('Switch')),
          if (!isActive)
            const PopupMenuItem(value: 'forget', child: Text('Forget')),
        ],
      ),
    );
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
        _buildServersList(),
        const SizedBox(height: 8),
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(
            Icons.add_circle_outline,
            color: context.textSecondary,
            size: 22,
          ),
          title: Text(
            'Add server',
            style: TextStyle(color: context.textPrimary, fontSize: 15),
          ),
          subtitle: Text(
            'Verifies the URL before adding it to your list.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: context.textMuted,
            size: 20,
          ),
          onTap: _showAddServerDialog,
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
