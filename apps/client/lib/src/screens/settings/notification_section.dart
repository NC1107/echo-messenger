import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/notification_service.dart';
import '../../services/sound_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

/// SharedPreferences keys for notification settings.
const _kNotificationsEnabled = 'notifications_enabled';
const _kDmNotifications = 'dm_notifications_enabled';
const _kGroupNotifications = 'group_notifications_enabled';

class NotificationSection extends StatefulWidget {
  const NotificationSection({super.key});

  @override
  State<NotificationSection> createState() => _NotificationSectionState();
}

class _NotificationSectionState extends State<NotificationSection> {
  bool _soundEnabled = SoundService().enabled;
  bool _notificationsEnabled = true;
  bool _dmNotifications = true;
  bool _groupNotifications = true;

  @override
  void initState() {
    super.initState();
    _loadPreferences();
  }

  Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    if (!mounted) return;
    setState(() {
      _notificationsEnabled = prefs.getBool(_kNotificationsEnabled) ?? true;
      _dmNotifications = prefs.getBool(_kDmNotifications) ?? true;
      _groupNotifications = prefs.getBool(_kGroupNotifications) ?? true;
    });
  }

  Future<void> _setNotificationsEnabled(bool value) async {
    setState(() => _notificationsEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotificationsEnabled, value);
    NotificationService().refreshPreferences();
  }

  Future<void> _setDmNotifications(bool value) async {
    setState(() => _dmNotifications = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDmNotifications, value);
    NotificationService().refreshPreferences();
  }

  Future<void> _setGroupNotifications(bool value) async {
    setState(() => _groupNotifications = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kGroupNotifications, value);
    NotificationService().refreshPreferences();
  }

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
        conversationId: 'test',
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
            'Enable Notifications',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Show desktop/mobile notifications for new messages.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          value: _notificationsEnabled,
          onChanged: _setNotificationsEnabled,
        ),
        if (_notificationsEnabled) ...[
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.only(left: 16),
            title: Text(
              'Direct Messages',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Notify for incoming DMs.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: _dmNotifications,
            onChanged: _setDmNotifications,
          ),
          SwitchListTile.adaptive(
            contentPadding: const EdgeInsets.only(left: 16),
            title: Text(
              'Group Messages',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Notify for messages in group conversations.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: _groupNotifications,
            onChanged: _setGroupNotifications,
          ),
        ],
        const Divider(height: 32),
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

/// Read notification preferences. Used by the message handler to decide
/// whether to show a notification.
Future<({bool enabled, bool dm, bool group})> loadNotificationPrefs() async {
  final prefs = await SharedPreferences.getInstance();
  return (
    enabled: prefs.getBool(_kNotificationsEnabled) ?? true,
    dm: prefs.getBool(_kDmNotifications) ?? true,
    group: prefs.getBool(_kGroupNotifications) ?? true,
  );
}
