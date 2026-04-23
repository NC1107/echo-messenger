import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/auth_provider.dart';
import '../../providers/server_url_provider.dart';
import '../../services/message_cache.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

class DataStorageSection extends ConsumerStatefulWidget {
  const DataStorageSection({super.key});

  @override
  ConsumerState<DataStorageSection> createState() => _DataStorageSectionState();
}

class _DataStorageSectionState extends ConsumerState<DataStorageSection> {
  String _cacheSize = 'Calculating...';

  @override
  void initState() {
    super.initState();
    _calculateCacheSize();
  }

  Future<void> _calculateCacheSize() async {
    try {
      final count = MessageCache.entryCount();
      // Rough estimate: ~512 bytes per cached message entry
      final totalBytes = count * 512;
      if (mounted) {
        setState(
          () => _cacheSize = '$count entries (~${_formatBytes(totalBytes)})',
        );
      }
    } catch (_) {
      if (mounted) setState(() => _cacheSize = 'Unknown');
    }
  }

  String _formatBytes(int bytes) {
    if (bytes < 1024) return '$bytes B';
    if (bytes < 1024 * 1024) return '${(bytes / 1024).toStringAsFixed(1)} KB';
    return '${(bytes / (1024 * 1024)).toStringAsFixed(1)} MB';
  }

  Future<void> _clearMessageCache() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Clear Message Cache',
          style: TextStyle(color: context.textPrimary, fontSize: 18),
        ),
        content: Text(
          'Cached messages will be reloaded from the server. '
          'No data will be lost.',
          style: TextStyle(color: context.textSecondary, fontSize: 14),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Clear'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;

    await MessageCache.clearAll();
    await _calculateCacheSize();
    if (mounted) {
      ToastService.show(
        context,
        'Message cache cleared',
        type: ToastType.success,
      );
    }
  }

  Future<void> _copyAccountInfo() async {
    final auth = ref.read(authProvider);
    final serverUrl = ref.read(serverUrlProvider);

    final lines = [
      'User ID: ${auth.userId ?? 'unknown'}',
      'Username: ${auth.username ?? 'unknown'}',
      'Server: $serverUrl',
    ];

    await Clipboard.setData(ClipboardData(text: lines.join('\n')));

    if (mounted) {
      ToastService.show(context, 'Account info copied to clipboard');
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Data & Storage',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          'Manage cached data and storage usage.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const Divider(height: 24),
        // Cache size
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.storage, color: context.textSecondary),
          title: Text(
            'Message Cache',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Estimated size: $_cacheSize',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: OutlinedButton(
            onPressed: _clearMessageCache,
            child: const Text('Clear'),
          ),
        ),
        const SizedBox(height: 24),
        // Export section
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.download_outlined, color: context.textSecondary),
          title: Text(
            'Export My Data',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Your messages are stored encrypted on the server and synced to '
            'this device. Full export is in development.',
            style: TextStyle(color: context.textSecondary, fontSize: 12, height: 1.4),
          ),
        ),
        const SizedBox(height: 8),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: _copyAccountInfo,
            icon: const Icon(Icons.copy, size: 16),
            label: const Text('Copy Account Info'),
          ),
        ),
      ],
    );
  }
}
