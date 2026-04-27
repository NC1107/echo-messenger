import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_webrtc/flutter_webrtc.dart' as webrtc;
import 'package:shared_preferences/shared_preferences.dart';

import '../../providers/voice_settings_provider.dart';
import '../../services/notification_service.dart';
import '../../services/sound_service.dart';
import '../../services/toast_service.dart';
import '../../theme/echo_theme.dart';
import '../../utils/audio_level_analyzer.dart';

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

  Future<void> _setNotificationSound(NotificationSound sound) async {
    await SoundService().setNotificationSound(sound);
    setState(() => _notificationSound = sound);
    if (sound != NotificationSound.none) {
      await SoundService().previewSound(sound);
    }
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

  void _openVoiceVideoSubpage() {
    Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => const _VoiceVideoSubpage()));
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

        // ---- Voice & Video subpage entry (absorbed from former Audio section) ----
        ListTile(
          contentPadding: EdgeInsets.zero,
          leading: Icon(Icons.graphic_eq, color: context.accent, size: 22),
          title: Text(
            'Voice & Video',
            style: TextStyle(color: context.textPrimary, fontSize: 14),
          ),
          subtitle: Text(
            'Devices, push-to-talk, audio processing.',
            style: TextStyle(color: context.textMuted, fontSize: 12),
          ),
          trailing: Icon(
            Icons.chevron_right,
            color: context.textMuted,
            size: 20,
          ),
          onTap: _openVoiceVideoSubpage,
        ),
        const Divider(height: 32),

        // ---- DND active banner -------------------------------------------
        if (_dndEnabled) ...[
          Container(
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: context.accent.withValues(alpha: 0.12),
              border: Border.all(color: context.accent.withValues(alpha: 0.31)),
              borderRadius: BorderRadius.circular(8),
            ),
            child: Row(
              children: [
                Icon(Icons.do_not_disturb_on, color: context.accent, size: 18),
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
            color: _quietHoursEnabled ? context.accent : context.textSecondary,
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
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// Time tile widget
// ---------------------------------------------------------------------------

class _TimeTile extends StatelessWidget {
  const _TimeTile({
    required this.label,
    required this.time,
    required this.onTap,
  });

  final String label;
  final TimeOfDay time;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final formatted = time.format(context);
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        decoration: BoxDecoration(
          color: context.surface,
          border: Border.all(color: context.border),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              label,
              style: TextStyle(color: context.textMuted, fontSize: 11),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Icon(Icons.access_time, size: 14, color: context.accent),
                const SizedBox(width: 6),
                Text(
                  formatted,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Sound picker row
// ---------------------------------------------------------------------------

class _SoundPickerRow extends StatelessWidget {
  const _SoundPickerRow({required this.selected, required this.onChanged});

  final NotificationSound selected;
  final ValueChanged<NotificationSound> onChanged;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  'Message Sound',
                  style: TextStyle(color: context.textPrimary, fontSize: 14),
                ),
                const SizedBox(height: 2),
                Text(
                  'Sound played when you receive a message.',
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
              ],
            ),
          ),
          const SizedBox(width: 16),
          _SoundDropdown(selected: selected, onChanged: onChanged),
        ],
      ),
    );
  }
}

class _SoundDropdown extends StatelessWidget {
  const _SoundDropdown({required this.selected, required this.onChanged});

  final NotificationSound selected;
  final ValueChanged<NotificationSound> onChanged;

  @override
  Widget build(BuildContext context) {
    return DecoratedBox(
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surface,
        border: Border.all(color: context.border),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: DropdownButtonHideUnderline(
          child: DropdownButton<NotificationSound>(
            value: selected,
            dropdownColor: Theme.of(context).colorScheme.surface,
            style: TextStyle(color: context.textPrimary, fontSize: 13),
            icon: Icon(Icons.expand_more, size: 18, color: context.textMuted),
            borderRadius: BorderRadius.circular(8),
            items: NotificationSound.values.map((sound) {
              return DropdownMenuItem(
                value: sound,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      sound == NotificationSound.none
                          ? Icons.volume_off_outlined
                          : Icons.volume_up_outlined,
                      size: 15,
                      color: context.textSecondary,
                    ),
                    const SizedBox(width: 6),
                    Text(sound.label),
                  ],
                ),
              );
            }).toList(),
            onChanged: (sound) {
              if (sound != null) onChanged(sound);
            },
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Helpers (file-private)
// ---------------------------------------------------------------------------

TimeOfDay _parseTime(String value) {
  final parts = value.split(':');
  if (parts.length != 2) return const TimeOfDay(hour: 22, minute: 0);
  final hour = int.tryParse(parts[0]) ?? 22;
  final minute = int.tryParse(parts[1]) ?? 0;
  return TimeOfDay(hour: hour, minute: minute);
}

String _formatTime(TimeOfDay t) =>
    '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}';

/// Returns true when [now] falls in the [start, end) window.
///
/// Handles overnight windows (e.g. 22:00 – 07:00 wraps past midnight).
bool _isWithinQuietHours(TimeOfDay now, TimeOfDay start, TimeOfDay end) {
  final nowMins = now.hour * 60 + now.minute;
  final startMins = start.hour * 60 + start.minute;
  final endMins = end.hour * 60 + end.minute;

  if (startMins <= endMins) {
    // Same-day window (e.g. 09:00 – 17:00).
    return nowMins >= startMins && nowMins < endMins;
  } else {
    // Overnight window (e.g. 22:00 – 07:00).
    return nowMins >= startMins || nowMins < endMins;
  }
}

// ---------------------------------------------------------------------------
// Public helpers used by notification handlers
// ---------------------------------------------------------------------------

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

/// Returns true when DND is active or the current time falls within quiet
/// hours. Notification service implementations call this to suppress
/// notifications without delivering them to the user.
Future<bool> shouldSuppressNotification() async {
  final prefs = await SharedPreferences.getInstance();

  final dnd = prefs.getBool(_kDndEnabled) ?? false;
  if (dnd) return true;

  final quietEnabled = prefs.getBool(_kQuietHoursEnabled) ?? false;
  if (!quietEnabled) return false;

  final start = _parseTime(
    prefs.getString(_kQuietHoursStart) ?? _kDefaultQuietStart,
  );
  final end = _parseTime(prefs.getString(_kQuietHoursEnd) ?? _kDefaultQuietEnd);
  return _isWithinQuietHours(TimeOfDay.now(), start, end);
}

// ---------------------------------------------------------------------------
// Voice & Video subpage (absorbed from former AudioSection).
// Lives as a private subpage of NotificationSection so the merge keeps the
// 3-group settings layout. Public flow: tap "Voice & Video" row above to push.
// ---------------------------------------------------------------------------

class _VoiceVideoSubpage extends ConsumerStatefulWidget {
  const _VoiceVideoSubpage();

  @override
  ConsumerState<_VoiceVideoSubpage> createState() => _VoiceVideoSubpageState();
}

class _VoiceVideoSubpageState extends ConsumerState<_VoiceVideoSubpage> {
  List<Map<String, String>> _audioInputDevices = [
    {'id': 'default', 'name': 'Default Microphone'},
  ];
  List<Map<String, String>> _audioOutputDevices = [
    {'id': 'default', 'name': 'Default Output'},
  ];
  List<Map<String, String>> _videoInputDevices = [
    {'id': 'default', 'name': 'Default Camera'},
  ];
  bool _devicesLoaded = false;

  // Mic test state
  bool _isMicTesting = false;
  double _micLevel = 0.0;
  Timer? _micTestTimer;
  webrtc.MediaStream? _micTestStream;
  AudioLevelAnalyzer? _audioLevelAnalyzer;

  // Sound test state
  bool _isPlayingTestSound = false;

  String _friendlyKeyLabel(LogicalKeyboardKey key) {
    if (key == LogicalKeyboardKey.space) return 'Space';
    if (key == LogicalKeyboardKey.controlLeft ||
        key == LogicalKeyboardKey.controlRight) {
      return 'Ctrl';
    }
    if (key == LogicalKeyboardKey.shiftLeft ||
        key == LogicalKeyboardKey.shiftRight) {
      return 'Shift';
    }
    if (key == LogicalKeyboardKey.altLeft ||
        key == LogicalKeyboardKey.altRight) {
      return 'Alt';
    }
    if (key == LogicalKeyboardKey.metaLeft ||
        key == LogicalKeyboardKey.metaRight) {
      return 'Meta';
    }

    final label = key.keyLabel.trim();
    if (label.isNotEmpty) return label.toUpperCase();
    return (key.debugName ?? 'Unknown').replaceAll(' ', '');
  }

  @override
  void dispose() {
    _stopMicTest();
    super.dispose();
  }

  Future<void> _playTestSound() async {
    if (_isPlayingTestSound) return;
    setState(() => _isPlayingTestSound = true);

    try {
      await SoundService().playMessageReceived();
      // Brief delay so the button shows "Playing..." while the sound plays.
      await Future<void>.delayed(const Duration(milliseconds: 600));
    } catch (_) {
      // Audio not available
    }
    if (mounted) setState(() => _isPlayingTestSound = false);
  }

  Future<void> _startMicTest() async {
    if (_isMicTesting) return;
    setState(() {
      _isMicTesting = true;
      _micLevel = 0.0;
    });

    try {
      _micTestStream = await webrtc.navigator.mediaDevices.getUserMedia({
        'audio': true,
        'video': false,
      });

      // Create an audio level analyzer from the real mic stream
      _audioLevelAnalyzer = AudioLevelAnalyzer.fromStream(_micTestStream!);

      // Poll the real mic level every 50ms for responsive metering.
      _micTestTimer = Timer.periodic(const Duration(milliseconds: 50), (timer) {
        if (!mounted) {
          _stopMicTest();
          return;
        }
        final level = _audioLevelAnalyzer?.getLevel() ?? 0.0;
        setState(() {
          _micLevel = level;
        });
      });
    } catch (_) {
      if (mounted) {
        setState(() {
          _isMicTesting = false;
          _micLevel = 0.0;
        });
      }
    }
  }

  void _stopMicTest() {
    _micTestTimer?.cancel();
    _micTestTimer = null;

    _audioLevelAnalyzer?.dispose();
    _audioLevelAnalyzer = null;

    final stream = _micTestStream;
    if (stream != null) {
      for (final track in stream.getTracks()) {
        track.stop();
      }
      stream.dispose();
      _micTestStream = null;
    }

    if (mounted) {
      setState(() {
        _isMicTesting = false;
        _micLevel = 0.0;
      });
    }
  }

  Future<void> _capturePushToTalkKey(VoiceSettingsNotifier notifier) async {
    final result = await showDialog<Map<String, String>>(
      context: context,
      builder: (dialogContext) {
        String captured = 'Press any key...';
        return StatefulBuilder(
          builder: (dialogContext, setDialogState) => AlertDialog(
            backgroundColor: context.surface,
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(12),
              side: BorderSide(color: context.border),
            ),
            title: Text(
              'Set Push-to-Talk Key',
              style: TextStyle(color: context.textPrimary, fontSize: 17),
            ),
            content: Focus(
              autofocus: true,
              onKeyEvent: (_, event) {
                if (event is KeyDownEvent) {
                  final label = _friendlyKeyLabel(event.logicalKey);
                  setDialogState(() {
                    captured = label;
                  });
                  Navigator.pop(dialogContext, {
                    'id': event.logicalKey.keyId.toString(),
                    'label': label,
                  });
                }
                return KeyEventResult.handled;
              },
              child: Container(
                width: 340,
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 14,
                ),
                decoration: BoxDecoration(
                  color: context.mainBg,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: context.border),
                ),
                child: Text(
                  captured,
                  style: TextStyle(
                    color: context.textPrimary,
                    fontSize: 14,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(dialogContext),
                child: const Text('Cancel'),
              ),
            ],
          ),
        );
      },
    );

    if (result == null) return;
    final keyId = result['id'];
    final keyLabel = result['label'];
    if (keyId == null || keyLabel == null) return;
    await notifier.setPushToTalkKey(keyId: keyId, keyLabel: keyLabel);
  }

  Future<void> _loadAudioDevices() async {
    if (_devicesLoaded) return;
    _devicesLoaded = true;
    try {
      final devices = await webrtc.navigator.mediaDevices.enumerateDevices();
      final inputs = <Map<String, String>>[
        {'id': 'default', 'name': 'Default Microphone'},
      ];
      final outputs = <Map<String, String>>[
        {'id': 'default', 'name': 'Default Output'},
      ];
      final cameras = <Map<String, String>>[
        {'id': 'default', 'name': 'Default Camera'},
      ];
      for (final d in devices) {
        final label = d.label.isNotEmpty ? d.label : d.deviceId;
        if (d.kind == 'audioinput' && d.deviceId != 'default') {
          inputs.add({'id': d.deviceId, 'name': label});
        } else if (d.kind == 'audiooutput' && d.deviceId != 'default') {
          outputs.add({'id': d.deviceId, 'name': label});
        } else if (d.kind == 'videoinput' && d.deviceId != 'default') {
          cameras.add({'id': d.deviceId, 'name': label});
        }
      }
      if (mounted) {
        setState(() {
          _audioInputDevices = inputs;
          _audioOutputDevices = outputs;
          _videoInputDevices = cameras;
        });
      }
    } catch (_) {
      // Enumeration not available on this platform
    }
  }

  Color _micLevelColor() {
    if (_micLevel > 0.7) return EchoTheme.danger;
    if (_micLevel > 0.4) return Colors.orange;
    return EchoTheme.online;
  }

  /// Reusable device picker dropdown.
  Widget _buildDevicePicker({
    required String label,
    required List<Map<String, String>> devices,
    required String currentId,
    required ValueChanged<String> onChanged,
  }) {
    return DropdownButtonFormField<String>(
      initialValue: devices.any((d) => d['id'] == currentId)
          ? currentId
          : 'default',
      decoration: InputDecoration(labelText: label),
      items: devices
          .map(
            (device) => DropdownMenuItem(
              value: device['id'],
              child: Text(device['name']!),
            ),
          )
          .toList(),
      onChanged: (value) {
        if (value != null) onChanged(value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final voice = ref.watch(voiceSettingsProvider);
    final notifier = ref.read(voiceSettingsProvider.notifier);

    // Load real devices on first build
    _loadAudioDevices();

    final inputDevices = _audioInputDevices;
    final outputDevices = _audioOutputDevices;
    final cameraDevices = _videoInputDevices;

    return Scaffold(
      backgroundColor: context.mainBg,
      appBar: AppBar(
        backgroundColor: context.sidebarBg,
        title: Text(
          'Voice & Video',
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
      body: ListView(
        padding: const EdgeInsets.all(24),
        children: [
          Text(
            'Configure voice device preferences and push-to-talk behavior.',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 13,
              height: 1.5,
            ),
          ),
          const SizedBox(height: 18),
          _buildDevicePicker(
            label: 'Input Device',
            devices: inputDevices,
            currentId: voice.inputDeviceId,
            onChanged: notifier.setInputDevice,
          ),
          const SizedBox(height: 12),
          _buildDevicePicker(
            label: 'Output Device',
            devices: outputDevices,
            currentId: voice.outputDeviceId,
            onChanged: notifier.setOutputDevice,
          ),
          const SizedBox(height: 12),
          _buildDevicePicker(
            label: 'Camera',
            devices: cameraDevices,
            currentId: voice.cameraDeviceId,
            onChanged: notifier.setCameraDevice,
          ),
          const SizedBox(height: 16),
          Text(
            'Input Sensitivity',
            style: TextStyle(color: context.textPrimary, fontSize: 13),
          ),
          Slider(
            value: voice.inputGain,
            min: 0,
            max: 2,
            divisions: 20,
            label: voice.inputGain.toStringAsFixed(1),
            onChanged: notifier.setInputGain,
          ),
          const SizedBox(height: 8),
          Text(
            'Output Volume',
            style: TextStyle(color: context.textPrimary, fontSize: 13),
          ),
          Slider(
            value: voice.outputVolume,
            min: 0,
            max: 1,
            divisions: 20,
            label: (voice.outputVolume * 100).round().toString(),
            onChanged: notifier.setOutputVolume,
          ),
          const SizedBox(height: 16),
          Row(
            children: [
              OutlinedButton.icon(
                onPressed: _isPlayingTestSound ? null : _playTestSound,
                icon: Icon(
                  _isPlayingTestSound ? Icons.volume_up : Icons.play_arrow,
                  size: 18,
                ),
                label: Text(_isPlayingTestSound ? 'Playing...' : 'Test Sound'),
              ),
              const SizedBox(width: 12),
              OutlinedButton.icon(
                onPressed: _isMicTesting ? _stopMicTest : _startMicTest,
                icon: Icon(_isMicTesting ? Icons.stop : Icons.mic, size: 18),
                label: Text(_isMicTesting ? 'Stop' : 'Test Microphone'),
              ),
            ],
          ),
          if (_isMicTesting) ...[
            const SizedBox(height: 10),
            Row(
              children: [
                Icon(Icons.mic, size: 16, color: context.textSecondary),
                const SizedBox(width: 8),
                Expanded(
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: _micLevel,
                      minHeight: 8,
                      backgroundColor: context.surface,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        _micLevelColor(),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${(_micLevel * 100).round()}%',
                  style: TextStyle(color: context.textSecondary, fontSize: 12),
                ),
              ],
            ),
          ],
          const SizedBox(height: 10),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Push-to-Talk',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'When enabled, your mic transmits only while push-to-talk is active.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: voice.pushToTalkEnabled,
            onChanged: notifier.setPushToTalkEnabled,
          ),
          AnimatedOpacity(
            opacity: voice.pushToTalkEnabled ? 1.0 : 0.4,
            duration: const Duration(milliseconds: 200),
            child: IgnorePointer(
              ignoring: !voice.pushToTalkEnabled,
              child: ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(
                  'Push-to-Talk Key',
                  style: TextStyle(color: context.textPrimary, fontSize: 14),
                ),
                subtitle: Text(
                  voice.pushToTalkKeyLabel,
                  style: TextStyle(color: context.textMuted, fontSize: 12),
                ),
                trailing: OutlinedButton(
                  onPressed: () => _capturePushToTalkKey(notifier),
                  child: const Text('Set Key'),
                ),
              ),
            ),
          ),
          const SizedBox(height: 16),
          Divider(color: context.border),
          const SizedBox(height: 16),
          Text(
            'Audio Processing',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            'These settings apply the next time you join a voice channel.',
            style: TextStyle(
              color: context.textSecondary,
              fontSize: 12,
              height: 1.5,
            ),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Noise Suppression',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Reduce background noise like fans, typing, and ambient sounds.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: voice.noiseSuppression,
            onChanged: (v) => notifier.setNoiseSuppression(v),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Echo Cancellation',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Prevent your speakers from feeding back into your microphone.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: voice.echoCancellation,
            onChanged: (v) => notifier.setEchoCancellation(v),
          ),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Auto Gain Control',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Automatically adjust microphone volume for consistent levels.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: voice.autoGainControl,
            onChanged: (v) => notifier.setAutoGainControl(v),
          ),
          const SizedBox(height: 16),
          Divider(color: context.border),
          const SizedBox(height: 16),
          Text(
            'Channel Behaviour',
            style: TextStyle(
              color: context.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w600,
            ),
          ),
          const SizedBox(height: 4),
          SwitchListTile.adaptive(
            contentPadding: EdgeInsets.zero,
            title: Text(
              'Confirm before joining voice channel',
              style: TextStyle(color: context.textPrimary, fontSize: 14),
            ),
            subtitle: Text(
              'Show a confirmation dialog before connecting to a voice channel.',
              style: TextStyle(color: context.textMuted, fontSize: 12),
            ),
            value: voice.confirmBeforeJoinVoice,
            onChanged: notifier.setConfirmBeforeJoinVoice,
          ),
        ],
      ),
    );
  }
}
