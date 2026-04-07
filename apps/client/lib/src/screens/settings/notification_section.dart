import 'package:flutter/material.dart';

import '../../services/notification_service.dart';
import '../../services/sound_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

class NotificationSection extends StatefulWidget {
  const NotificationSection({super.key});

  @override
  State<NotificationSection> createState() => _NotificationSectionState();
}

class _NotificationSectionState extends State<NotificationSection> {
  bool _soundEnabled = SoundService().enabled;

  void _toggleSound(bool value) {
    SoundService().enabled = value;
    setState(() => _soundEnabled = value);
  }

  Future<void> _sendTestNotification() async {
    try {
      await SoundService().playMessageReceived();
      NotificationService().showMessageNotification(
        senderUsername: 'Echo',
        body: 'This is a test notification!',
        forceShow: true,
      );
      if (mounted) {
        ToastService.show(
          context,
          'Test notification sent.',
          type: ToastType.success,
        );
      }
    } catch (e) {
      if (mounted) {
        ToastService.show(
          context,
          'Failed to send test notification: $e',
          type: ToastType.error,
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        Text(
          'Notifications',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Configure how you receive notifications and alerts.',
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
            'Message Sounds',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Play a sound when you receive a message.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: _soundEnabled,
          onChanged: _toggleSound,
        ),
        const SizedBox(height: 24),
        Text(
          'Test',
          style: TextStyle(
            color: context.textPrimary,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
        const SizedBox(height: 8),
        Text(
          'Send a test notification to verify your settings.',
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
            onPressed: _sendTestNotification,
            icon: const Icon(Icons.notifications_active_outlined, size: 18),
            label: const Text('Send Test Notification'),
            style: OutlinedButton.styleFrom(
              foregroundColor: context.accent,
              side: BorderSide(color: context.accent),
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
