import 'package:flutter/material.dart';

import '../../services/message_cache.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

class DataStorageSection extends StatefulWidget {
  const DataStorageSection({super.key});

  @override
  State<DataStorageSection> createState() => _DataStorageSectionState();
}

class _DataStorageSectionState extends State<DataStorageSection> {
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
        // Export (coming soon)
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.download, color: context.textMuted),
          title: Text(
            'Export My Data',
            style: TextStyle(color: context.textMuted, fontSize: 14),
          ),
          subtitle: Text(
            'Download all your messages and account data.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: Container(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: context.surfaceHover,
              borderRadius: BorderRadius.circular(6),
            ),
            child: Text(
              'Coming soon',
              style: TextStyle(color: context.textMuted, fontSize: 11),
            ),
          ),
        ),
      ],
    );
  }
}
