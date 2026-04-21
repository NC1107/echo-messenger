import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';

import '../../providers/biometric_provider.dart';
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

  Future<void> _toggleBiometric(bool value) async {
    await ref.read(biometricProvider.notifier).setEnabled(value);
    if (!mounted) return;
    final enabled = ref.read(biometricProvider).enabled;
    if (value && !enabled) {
      // Authentication failed — inform the user.
      ToastService.show(
        context,
        'Biometric authentication failed. Lock not enabled.',
        type: ToastType.error,
      );
    }
  }

  Future<void> _resetEncryptionKeys() async {
    final confirmController = TextEditingController();
    final passwordController = TextEditingController();
    final result = await showDialog<String>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) {
            final matches =
                confirmController.text.trim().toUpperCase() == 'RESET';
            final hasPassword = passwordController.text.isNotEmpty;
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
                    'Enter your password:',
                    style: TextStyle(
                      color: context.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 8),
                  TextField(
                    controller: passwordController,
                    obscureText: true,
                    style: TextStyle(color: context.textPrimary, fontSize: 14),
                    decoration: const InputDecoration(hintText: 'Password'),
                    onChanged: (_) => setDialogState(() {}),
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
                    controller: confirmController,
                    style: TextStyle(color: context.textPrimary, fontSize: 14),
                    decoration: const InputDecoration(hintText: 'RESET'),
                    onChanged: (_) => setDialogState(() {}),
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(dialogContext, null),
                  child: const Text('Cancel'),
                ),
                FilledButton(
                  onPressed: matches && hasPassword
                      ? () => Navigator.pop(
                          dialogContext,
                          passwordController.text,
                        )
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
    confirmController.dispose();
    passwordController.dispose();

    if (result == null) return;

    try {
      await ref.read(cryptoProvider.notifier).resetKeys(result);
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
    final biometric = ref.watch(biometricProvider);

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
          'App Lock',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Require biometric authentication when opening Echo.',
          style: TextStyle(
            color: context.textSecondary,
            fontSize: 13,
            height: 1.5,
          ),
        ),
        const SizedBox(height: 12),
        if (biometric.isLoading)
          const Padding(
            padding: EdgeInsets.symmetric(vertical: 8),
            child: LinearProgressIndicator(),
          )
        else if (!biometric.isAvailable)
          Padding(
            padding: const EdgeInsets.only(bottom: 8),
            child: Text(
              'Biometric authentication is not available on this device.',
              style: TextStyle(color: context.textMuted, fontSize: 13),
            ),
          )
        else
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Require Biometric to Open App',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Lock Echo when it goes to the background. '
              'Use Face ID, fingerprint, or device PIN to unlock.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: biometric.enabled,
            onChanged: _toggleBiometric,
          ),
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
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
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Show Online Status',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'When off, you will appear offline to other users.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.showOnlineStatus,
          onChanged: privacy.isLoading
              ? null
              : (value) => ref
                    .read(privacyProvider.notifier)
                    .setShowOnlineStatus(value),
        ),
        const SizedBox(height: 24),
        Text(
          'Contact Info Visibility',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Control who can see your email and phone on your profile.',
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
            'Show Email on Profile',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Allow other users to see your email address.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.emailVisible,
          onChanged: privacy.isLoading
              ? null
              : (value) =>
                    ref.read(privacyProvider.notifier).setEmailVisible(value),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Show Phone on Profile',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Allow other users to see your phone number.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.phoneVisible,
          onChanged: privacy.isLoading
              ? null
              : (value) =>
                    ref.read(privacyProvider.notifier).setPhoneVisible(value),
        ),
        const SizedBox(height: 16),
        Text(
          'Discoverability',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Control whether others can find you using your contact details.',
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
            'Discoverable by Email',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Allow others to find you by searching your email.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.emailDiscoverable,
          onChanged: privacy.isLoading
              ? null
              : (value) => ref
                    .read(privacyProvider.notifier)
                    .setEmailDiscoverable(value),
        ),
        SwitchListTile.adaptive(
          contentPadding: EdgeInsets.zero,
          title: Text(
            'Discoverable by Phone',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Allow others to find you by searching your phone number.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.phoneDiscoverable,
          onChanged: privacy.isLoading
              ? null
              : (value) => ref
                    .read(privacyProvider.notifier)
                    .setPhoneDiscoverable(value),
        ),
        const SizedBox(height: 24),
        Text(
          'Search Visibility',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Control whether other users can find your profile via search.',
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
            'Allow others to find me',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'When off, your username won\'t appear in search results.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: privacy.searchable,
          onChanged: privacy.isLoading
              ? null
              : (value) =>
                    ref.read(privacyProvider.notifier).setSearchable(value),
        ),
        const SizedBox(height: 24),
        Text(
          'Encryption',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 18,
            fontWeight: FontWeight.w700,
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
        const SizedBox(height: 24),
        const Divider(),
        const SizedBox(height: 8),
        Text(
          'Danger Zone',
          style: TextStyle(
            color: EchoTheme.danger,
            fontSize: 13,
            fontWeight: FontWeight.w700,
            letterSpacing: 0.5,
          ),
        ),
        const SizedBox(height: 12),
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
