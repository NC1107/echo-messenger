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
      builder: (dialogContext) {
        final controller = TextEditingController();
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final matches = controller.text.trim().toUpperCase() == 'RESET';
            return AlertDialog(
              backgroundColor: context.surface,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(12),
                side: BorderSide(color: context.border),
              ),
              title: const Text(
                'Reset Encryption Keys',
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
                    'This will regenerate your encryption keys. You won\'t be able '
                    'to read old encrypted messages. Both you and your contacts will '
                    'need to exchange new messages.',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 14,
                      height: 1.5,
                    ),
                  ),
                  const SizedBox(height: 16),
                  Text(
                    'Type RESET to confirm:',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: controller,
                    style: TextStyle(color: context.textPrimary, fontSize: 14),
                    decoration: const InputDecoration(hintText: 'RESET'),
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
                  child: const Text('Reset Keys'),
                ),
              ],
            );
          },
        );
      },
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

  Future<void> _retryKeyUpload() async {
    try {
      await ref.read(cryptoProvider.notifier).retryKeyUpload();
      if (mounted) {
        final succeeded = !ref.read(cryptoProvider).keysUploadFailed;
        ToastService.show(
          context,
          succeeded
              ? 'Encryption keys uploaded successfully.'
              : 'Key upload failed. Please try again later.',
          type: succeeded ? ToastType.success : ToastType.error,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to upload keys: $e',
          type: ToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final privacy = ref.watch(privacyProvider);
    final crypto = ref.watch(cryptoProvider);

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
            fontSize: 18,
            fontWeight: FontWeight.w700,
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
        if (crypto.keysUploadFailed) ...[
          const SizedBox(height: 12),
          const Text(
            'Encryption key upload failed. New conversations will not be '
            'encrypted until keys are uploaded.',
            style: TextStyle(
              color: EchoTheme.danger,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 8),
          SizedBox(
            width: double.infinity,
            child: OutlinedButton.icon(
              onPressed: crypto.isUploading ? null : _retryKeyUpload,
              icon: crypto.isUploading
                  ? const SizedBox(
                      width: 16,
                      height: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.upload_outlined, size: 18),
              label: Text(
                crypto.isUploading
                    ? 'Uploading...'
                    : 'Re-upload Encryption Keys',
              ),
              style: OutlinedButton.styleFrom(
                foregroundColor: context.textPrimary,
                side: BorderSide(color: context.border),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(vertical: 12),
              ),
            ),
          ),
        ],
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
