import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../../services/notification_service.dart';
import '../../services/sound_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';

part 'notification_section/parts/time_tile.dart';
part 'notification_section/parts/sound_picker.dart';
part 'notification_section/parts/prefs_helpers.dart';

/// SharedPreferences keys for notification settings.
const _kNotificationsEnabled = 'notifications_enabled';
const _kDmNotifications = 'dm_notifications_enabled';
const _kGroupNotifications = 'group_notifications_enabled';
const _kDndEnabled = 'dnd_enabled';
const _kQuietHoursEnabled = 'quiet_hours_enabled';
const _kQuietHoursStart = 'quiet_hours_start';
const _kQuietHoursEnd = 'quiet_hours_end';

/// Default quiet hours: 22:00 – 07:00.
const _kDefaultQuietStart = '22:00';
const _kDefaultQuietEnd = '07:00';

class NotificationSection extends StatefulWidget {
  const NotificationSection({super.key});

  @override
  State<NotificationSection> createState() => _NotificationSectionState();
}

class _NotificationSectionState extends State<NotificationSection> {
  NotificationSound _notificationSound = SoundService().notificationSound;
  bool _soundEnabled = SoundService().enabled;
  bool _notificationsEnabled = true;
  bool _dmNotifications = true;
  bool _groupNotifications = true;
  bool _dndEnabled = false;
  bool _quietHoursEnabled = false;
  TimeOfDay _quietStart = const TimeOfDay(hour: 22, minute: 0);
  TimeOfDay _quietEnd = const TimeOfDay(hour: 7, minute: 0);

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
      _dndEnabled = prefs.getBool(_kDndEnabled) ?? false;
      _quietHoursEnabled = prefs.getBool(_kQuietHoursEnabled) ?? false;
      _quietStart = _parseTime(
        prefs.getString(_kQuietHoursStart) ?? _kDefaultQuietStart,
      );
      _quietEnd = _parseTime(
        prefs.getString(_kQuietHoursEnd) ?? _kDefaultQuietEnd,
      );
    });
  }

  Future<void> _setNotificationsEnabled(bool value) async {
    setState(() => _notificationsEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kNotificationsEnabled, value);
    NotificationService().refreshPreferences();
    // On web, prompt the browser permission dialog on user gesture.
    if (value && kIsWeb) {
      await NotificationService().promptPermission();
    }
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

  Future<void> _setDndEnabled(bool value) async {
    setState(() => _dndEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kDndEnabled, value);
    NotificationService().refreshPreferences();
  }

  Future<void> _setQuietHoursEnabled(bool value) async {
    setState(() => _quietHoursEnabled = value);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool(_kQuietHoursEnabled, value);
    NotificationService().refreshPreferences();
  }

  Future<void> _pickQuietStart() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _quietStart,
      helpText: 'Quiet Hours Start',
    );
    if (picked == null || !mounted) return;
    setState(() => _quietStart = picked);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQuietHoursStart, _formatTime(picked));
    NotificationService().refreshPreferences();
  }

  Future<void> _pickQuietEnd() async {
    final picked = await showTimePicker(
      context: context,
      initialTime: _quietEnd,
      helpText: 'Quiet Hours End',
    );
    if (picked == null || !mounted) return;
    setState(() => _quietEnd = picked);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_kQuietHoursEnd, _formatTime(picked));
    NotificationService().refreshPreferences();
  }

  void _setSoundEnabled(bool value) {
    setState(() => _soundEnabled = value);
    SoundService().enabled = value;
  }

  Future<void> _setNotificationSound(NotificationSound sound) async {
    await SoundService().setNotificationSound(sound);
    setState(() => _notificationSound = sound);
    if (sound != NotificationSound.none) {
      await SoundService().previewSound(sound);
    }
  }

  Future<void> _sendTestNotification() async {
    try {
      try {
        await SoundService().playMessageReceived();
      } catch (_) {
        if (mounted) {
          ToastService.show(
            context,
            'Couldn\'t play sound on this platform',
            type: ToastType.warning,
          );
        }
      }
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
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 900),
        child: ListView(
          padding: const EdgeInsets.all(24),
          children: [
            Text(
              'Notifications',
              style: TextStyle(
                color: context.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
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

            // ---- DND active banner -------------------------------------------
            if (_dndEnabled) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  color: context.accent.withValues(alpha: 0.12),
                  border: Border.all(
                    color: context.accent.withValues(alpha: 0.31),
                  ),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.do_not_disturb_on,
                      color: context.accent,
                      size: 18,
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Text(
                        'Do Not Disturb is on — all notifications are muted.',
                        style: TextStyle(
                          color: context.accent,
                          fontSize: 13,
                          fontWeight: FontWeight.w500,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],

            // ---- Do Not Disturb toggle ----------------------------------------
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(
                Icons.do_not_disturb_on_outlined,
                color: _dndEnabled ? context.accent : context.textSecondary,
                size: 22,
              ),
              title: Text(
                'Do Not Disturb',
                style: TextStyle(color: context.textPrimary, fontSize: 14),
              ),
              subtitle: Text(
                'Mute all notifications until manually disabled.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: _dndEnabled,
              onChanged: _setDndEnabled,
            ),

            // ---- Quiet Hours --------------------------------------------------
            SwitchListTile.adaptive(
              contentPadding: EdgeInsets.zero,
              secondary: Icon(
                Icons.bedtime_outlined,
                color: _quietHoursEnabled
                    ? context.accent
                    : context.textSecondary,
                size: 22,
              ),
              title: Text(
                'Quiet Hours',
                style: TextStyle(color: context.textPrimary, fontSize: 14),
              ),
              subtitle: Text(
                'Silence notifications during a scheduled time window.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: _quietHoursEnabled,
              onChanged: _setQuietHoursEnabled,
            ),
            if (_quietHoursEnabled) ...[
              const SizedBox(height: 4),
              Padding(
                padding: const EdgeInsets.only(left: 16, right: 4, bottom: 4),
                child: Row(
                  children: [
                    Expanded(
                      child: _TimeTile(
                        label: 'Start time',
                        time: _quietStart,
                        onTap: _pickQuietStart,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _TimeTile(
                        label: 'End time',
                        time: _quietEnd,
                        onTap: _pickQuietEnd,
                      ),
                    ),
                  ],
                ),
              ),
            ],

            const Divider(height: 32),

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
              secondary: Icon(
                Icons.volume_up_outlined,
                color: _soundEnabled ? context.accent : context.textSecondary,
                size: 22,
              ),
              title: Text(
                'Enable Sound Effects',
                style: TextStyle(color: context.textPrimary, fontSize: 14),
              ),
              subtitle: Text(
                'Play sounds for messages, voice, and other app events.',
                style: TextStyle(color: context.textMuted, fontSize: 12),
              ),
              value: _soundEnabled,
              onChanged: _setSoundEnabled,
            ),
            _SoundPickerRow(
              selected: _notificationSound,
              onChanged: _setNotificationSound,
            ),
            if (_notificationsEnabled) ...[
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
                  icon: const Icon(
                    Icons.notifications_active_outlined,
                    size: 18,
                  ),
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
          ],
        ),
      ),
    );
  }
}
