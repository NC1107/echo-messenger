import 'dart:async';

import 'package:flutter/foundation.dart' show debugPrint, kIsWeb;
import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'debug_log_service.dart';
import 'notification_service.dart';
import '../screens/settings/notification_section.dart'
    show shouldSuppressNotification;

/// Native (non-web) implementation using flutter_local_notifications.
///
/// Features:
/// - Separate Android channels for DMs and groups
/// - Conversation-based notification IDs (replace instead of stack)
/// - Tap-to-open-conversation via payload stream
/// - Focus-aware suppression (no notifications when app is in foreground)
NotificationService createNotificationService() =>
    _NativeNotificationService._instance;

class _NativeNotificationService implements NotificationService {
  static final _NativeNotificationService _instance =
      _NativeNotificationService._();
  _NativeNotificationService._();

  static final _plugin = FlutterLocalNotificationsPlugin();
  static bool _initialized = false;
  static bool _appFocused = true;

  /// Timestamp when the app was last foregrounded. Notifications are allowed
  /// for a short grace period after foregrounding so WS-delivered messages
  /// that were queued while offline still trigger local notifications.
  static DateTime _lastForeground = DateTime.now();
  static int _fallbackId = 100000;

  // Cached notification preferences (loaded from SharedPreferences).
  static bool _notificationsEnabled = true;
  static bool _dmEnabled = true;
  static bool _groupEnabled = true;

  /// Stream controller for notification tap events (conversation IDs).
  static final _tapController = StreamController<String>.broadcast();

  // ---------------------------------------------------------------------------
  // Android notification channels
  // ---------------------------------------------------------------------------

  static const _dmChannel = AndroidNotificationDetails(
    'echo_dm',
    'Direct Messages',
    channelDescription: 'Notifications for direct messages',
    importance: Importance.high,
    priority: Priority.high,
    groupKey: 'echo_dm_group',
  );

  static const _groupChannel = AndroidNotificationDetails(
    'echo_group',
    'Group Messages',
    channelDescription: 'Notifications for group messages',
    importance: Importance.defaultImportance,
    priority: Priority.defaultPriority,
    groupKey: 'echo_group_group',
  );

  static const _linuxDetails = LinuxNotificationDetails();

  // ---------------------------------------------------------------------------
  // Initialization
  // ---------------------------------------------------------------------------

  Future<void> _ensureInitialized() async {
    if (_initialized) return;
    try {
      const android = AndroidInitializationSettings('@mipmap/ic_launcher');
      const darwin = DarwinInitializationSettings(
        requestAlertPermission: true,
        requestBadgePermission: true,
        requestSoundPermission: true,
      );
      const linux = LinuxInitializationSettings(defaultActionName: 'Open');
      const initSettings = InitializationSettings(
        android: android,
        iOS: darwin,
        macOS: darwin,
        linux: linux,
      );
      await _plugin.initialize(
        settings: initSettings,
        onDidReceiveNotificationResponse: _onNotificationTap,
      );
      _initialized = true;
    } catch (e) {
      debugPrint('[Notifications] init failed: $e');
      DebugLogService.instance.log(
        LogLevel.error,
        'Notifications',
        'Init failed (notifications will not be shown). '
            'On Linux, ensure a D-Bus notification daemon is running: $e',
      );
    }
  }

  /// Called when the user taps a notification.
  static void _onNotificationTap(NotificationResponse response) {
    final conversationId = response.payload;
    if (conversationId != null && conversationId.isNotEmpty) {
      _tapController.add(conversationId);
    }
  }

  // ---------------------------------------------------------------------------
  // NotificationService interface
  // ---------------------------------------------------------------------------

  @override
  Stream<String> get onNotificationTap => _tapController.stream;

  @override
  Future<void> requestPermission() async {
    if (kIsWeb) return;
    await _ensureInitialized();
    await _loadPreferences();
    // Android 13+ runtime permission
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            AndroidFlutterLocalNotificationsPlugin
          >()
          ?.requestNotificationsPermission();
    } catch (_) {
      // Not on Android or permission denied -- non-fatal.
    }
    // iOS permission request
    try {
      await _plugin
          .resolvePlatformSpecificImplementation<
            IOSFlutterLocalNotificationsPlugin
          >()
          ?.requestPermissions(alert: true, badge: true, sound: true);
    } catch (_) {
      // Not on iOS or permission denied -- non-fatal.
    }
  }

  /// Load user notification preferences from SharedPreferences.
  /// Called at startup and can be called again when settings change.
  static Future<void> _loadPreferences() async {
    final prefs = await SharedPreferences.getInstance();
    _notificationsEnabled = prefs.getBool('notifications_enabled') ?? true;
    _dmEnabled = prefs.getBool('dm_notifications_enabled') ?? true;
    _groupEnabled = prefs.getBool('group_notifications_enabled') ?? true;
  }

  @override
  void refreshPreferences() {
    _loadPreferences();
  }

  @override
  void showMessageNotification({
    required String senderUsername,
    required String body,
    String? conversationId,
    String? conversationName,
    bool isGroup = false,
    bool isMuted = false,
    bool forceShow = false,
  }) {
    // Per-conversation mute always wins, even over forceShow.
    if (isMuted) return;

    // Suppress when the app is focused, but allow a 5-second grace period
    // after foregrounding so WS-reconnect messages still trigger notifications.
    if (_appFocused && !forceShow) {
      final elapsed = DateTime.now().difference(_lastForeground);
      if (elapsed.inSeconds > 5) return;
    }

    // Respect user notification preferences.
    if (!forceShow) {
      if (!_notificationsEnabled) return;
      if (isGroup && !_groupEnabled) return;
      if (!isGroup && !_dmEnabled) return;
    }

    // Check Do Not Disturb and Quiet Hours (async, suppress if active).
    if (!forceShow) {
      shouldSuppressNotification().then((suppress) {
        if (!suppress) {
          _showNotification(
            conversationId,
            senderUsername,
            body,
            isGroup,
            conversationName,
          );
        }
      });
      return;
    }

    _showNotification(
      conversationId,
      senderUsername,
      body,
      isGroup,
      conversationName,
    );
  }

  void _showNotification(
    String? conversationId,
    String senderUsername,
    String body,
    bool isGroup,
    String? conversationName,
  ) {
    _ensureInitialized().then((_) {
      if (!_initialized) return;

      final notificationId = _idForConversation(conversationId);
      final androidDetails = isGroup ? _groupChannel : _dmChannel;

      // iOS: group notifications by conversation, show conversation name
      final iosDetails = DarwinNotificationDetails(
        threadIdentifier: conversationId,
        subtitle: conversationName,
        presentAlert: true,
        presentBadge: true,
        presentSound: true,
      );

      _plugin.show(
        id: notificationId,
        title: senderUsername,
        body: body,
        notificationDetails: NotificationDetails(
          android: androidDetails,
          iOS: iosDetails,
          linux: _linuxDetails,
        ),
        payload: conversationId,
      );
    });
  }

  @override
  void cancelConversationNotifications(String conversationId) {
    if (!_initialized) return;
    _plugin.cancel(id: _idForConversation(conversationId));
  }

  @override
  void cancelAll() {
    if (!_initialized) return;
    _plugin.cancelAll();
  }

  @override
  void updateTabBadge(int totalUnread) {
    // No-op on native platforms (tab badge is a web concept).
  }

  @override
  Future<bool> promptPermission() async => true;

  @override
  void setAppFocused(bool focused) {
    if (focused && !_appFocused) {
      _lastForeground = DateTime.now();
    }
    _appFocused = focused;
  }

  // ---------------------------------------------------------------------------
  // Helpers
  // ---------------------------------------------------------------------------

  /// Deterministic notification ID from conversation ID.
  ///
  /// Messages in the same conversation reuse the same notification ID so
  /// new messages replace the existing notification instead of stacking.
  static int _idForConversation(String? conversationId) {
    if (conversationId == null || conversationId.isEmpty) {
      return _fallbackId++;
    }
    return conversationId.hashCode & 0x7FFFFFFF;
  }
}
