import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/crypto_provider.dart';
import '../../providers/privacy_provider.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

class PrivacySection extends ConsumerStatefulWidget {
  const PrivacySection({super.key});

  @override
  ConsumerState<PrivacySection> createState() => _PrivacySectionState();
}

class _PrivacySectionState extends ConsumerState<PrivacySection> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      ref.read(privacyProvider.notifier).load();
    });
  }

  Future<void> _resetEncryptionKeys() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        backgroundColor: context.surface,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: context.border),
        ),
        title: Text(
          'Reset Encryption Keys',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 18,
            fontWeight: FontWeight.w600,
          ),
        ),
        content: Text(
          'This will regenerate your encryption keys. You won\'t be able '
          'to read old encrypted messages. Both you and your contacts will '
          'need to exchange new messages.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 14,
            height: 1.5,
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
            child: const Text('Reset Keys'),
          ),
        ],
      ),
    );

    if (confirmed != true) return;

    try {
      await ref.read(cryptoProvider.notifier).resetKeys();
      if (mounted) {
        ToastService.show(
          context,
          'Encryption keys have been reset successfully.',
          type: ToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to reset keys: $e',
          type: ToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyProvider);

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        if (privacy.error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(
              privacy.error!,
              style: const TextStyle(color: EchoTheme.danger, fontSize: 12),
            ),
          ),
        Text(
          'Messaging Privacy',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Control read receipts for your direct messages.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Send Read Receipts',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'When off, others will not see when you read messages.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.readReceiptsEnabled,
          onChanged: privacy.isLoading
              ? null
              : (value) => ref
                    .read(privacyProvider.notifier)
                    .setReadReceiptsEnabled(value),
        ),
        const SizedBox(height: 24),
        Text(
          'Encryption',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Echo uses end-to-end encryption for encrypted direct messages. '
          'Your encryption keys are stored locally on this device.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: OutlinedButton.icon(
            onPressed: _resetEncryptionKeys,
            icon: const Icon(Icons.warning_amber_outlined, size: 18),
            label: const Text('Reset Encryption Keys'),
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
