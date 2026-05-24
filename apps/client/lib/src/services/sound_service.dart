import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Which sound to play for incoming message notifications.
enum NotificationSound {
  /// No sound.
  none,

  /// The default "ding" (received.ogg).
  defaultSound,

  /// A softer "whoosh" tone (sent.ogg) used as an alternate notification.
  subtle;

  /// Persisted string value stored in SharedPreferences.
  String get prefValue => name;

  static NotificationSound fromPrefValue(String? value) =>
      NotificationSound.values.firstWhere(
        (e) => e.name == value,
        orElse: () => NotificationSound.defaultSound,
      );

  /// Human-readable label shown in the UI.
  String get label => switch (this) {
    NotificationSound.none => 'None',
    NotificationSound.defaultSound => 'Default',
    NotificationSound.subtle => 'Subtle',
  };

  /// Asset path for this sound, or null when [none].
  String? get assetPath => switch (this) {
    NotificationSound.none => null,
    NotificationSound.defaultSound => 'sounds/received.ogg',
    NotificationSound.subtle => 'sounds/sent.ogg',
  };
}

/// Simple service for playing UI sound effects.
///
/// Uses the audioplayers package which supports web via HTML5 audio.
class SoundService {
  static final SoundService _instance = SoundService._();
  factory SoundService() => _instance;
  SoundService._();

  static const _prefKey = 'sound_enabled';
  static const _notificationSoundPrefKey = 'notification_sound';

  final AudioPlayer _sentPlayer = AudioPlayer();
  final AudioPlayer _receivedPlayer = AudioPlayer();
  final AudioPlayer _mentionPlayer = AudioPlayer();
  final AudioPlayer _voiceJoinPlayer = AudioPlayer();
  final AudioPlayer _voiceLeavePlayer = AudioPlayer();

  bool _enabled = true;
  bool _initialized = false;
  NotificationSound _notificationSound = NotificationSound.defaultSound;

  /// Whether sound effects are currently enabled.
  bool get enabled => _enabled;

  /// The selected notification sound for incoming messages.
  NotificationSound get notificationSound => _notificationSound;

  /// Toggle sound effects on or off and persist the preference.
  set enabled(bool value) {
    _enabled = value;
    _persist(value);
  }

  /// Update and persist the notification sound selection.
  ///
  /// Independent of the global [enabled] flag — picking "None" here only
  /// silences message-received pings, NOT sent / voice / other UI sounds.
  /// Conversely, picking "Default" or "Subtle" doesn't force-enable sounds
  /// globally; the caller still needs the [enabled] master switch on.
  Future<void> setNotificationSound(NotificationSound sound) async {
    _notificationSound = sound;
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_notificationSoundPrefKey, sound.prefValue);
    } catch (e) {
      debugPrint('[Sound] Failed to save notification sound preference: $e');
    }
  }

  /// Load the persisted sound preference from SharedPreferences.
  /// Should be called once during app initialization.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      // Master enable flag — independent of the notification-sound choice
      // (previously this was derived from the sound choice, which had the
      // user-visible effect of silencing the app forever once 'None' was
      // ever picked — see #924).
      _enabled = prefs.getBool(_prefKey) ?? true;
      final soundValue = prefs.getString(_notificationSoundPrefKey);
      if (soundValue != null) {
        _notificationSound = NotificationSound.fromPrefValue(soundValue);
      } else {
        // Fresh install or legacy-only install: default to the ding.
        _notificationSound = _enabled
            ? NotificationSound.defaultSound
            : NotificationSound.none;
      }
      // Breadcrumb for #1156: when sounds go silent again, this single line
      // tells a debugger whether the master flag or the sound choice was the
      // culprit before they reach for the asset files.
      assert(() {
        debugPrint(
          '[Sound] init: enabled=$_enabled sound=${_notificationSound.name}',
        );
        return true;
      }());
    } catch (e) {
      debugPrint('[Sound] Failed to load preference: $e');
    }
  }

  Future<void> _persist(bool value) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setBool(_prefKey, value);
    } catch (e) {
      debugPrint('[Sound] Failed to save preference: $e');
    }
  }

  /// Play a short "whoosh" sound when the user sends a message.
  Future<void> playMessageSent() async {
    if (!_enabled) return;
    try {
      // AssetSource prepends `assets/` internally on every platform, so
      // the path here must NOT include it — otherwise Linux resolves to
      // `assets/assets/sounds/sent.ogg` and fails to load.
      await _sentPlayer.play(AssetSource('sounds/sent.ogg'), volume: 0.4);
    } catch (e) {
      debugPrint('[Sound] Failed to play sent sound: $e');
    }
  }

  /// Play the selected notification sound when a new message is received.
  ///
  /// Errors are swallowed via `.catchError` rather than just try/await because
  /// the audioplayers package can settle a late completer with
  /// `MissingPluginException` AFTER the awaited `play()` returns — happens
  /// under flutter_test where no platform channel is bound. Without the
  /// explicit catch, the late rejection leaks past the test boundary and
  /// fails the test even though no production user could observe it.
  Future<void> playMessageReceived() async {
    if (!_enabled) return;
    final path = _notificationSound.assetPath;
    if (path == null) return;
    try {
      await _receivedPlayer.play(AssetSource(path), volume: 0.3).catchError((
        Object e,
      ) {
        debugPrint('[Sound] Failed to play received sound (late): $e');
      });
    } catch (e) {
      debugPrint('[Sound] Failed to play received sound: $e');
    }
  }

  /// Preview the given [sound] regardless of the current enabled state.
  Future<void> previewSound(NotificationSound sound) async {
    final path = sound.assetPath;
    if (path == null) return;
    try {
      await _receivedPlayer.play(AssetSource(path), volume: 0.3);
    } catch (e) {
      debugPrint('[Sound] Failed to preview sound: $e');
    }
  }

  /// Play ascending chime when joining a voice channel.
  Future<void> playVoiceJoin() async {
    if (!_enabled) return;
    try {
      await _voiceJoinPlayer.play(
        AssetSource('sounds/voice_join.ogg'),
        volume: 0.5,
      );
    } catch (e) {
      debugPrint('[Sound] Failed to play voice join sound: $e');
    }
  }

  /// Play a louder ping when the local user is @-mentioned in a message.
  ///
  /// Bypasses the [enabled] global only when no template asset is bundled
  /// for mentions yet — for now it reuses `received.ogg` at higher volume
  /// so the user can distinguish a mention from a normal message even with
  /// the same sample. Swap to `assets/sounds/mention.ogg` once a dedicated
  /// chime ships.
  ///
  /// OGG Vorbis is chosen over MP3 because `gst-plugins-base` (which ships
  /// in every Linux GStreamer install) decodes Vorbis out of the box, while
  /// MP3 requires `gst-libav` which the AppImage build does NOT bundle —
  /// MP3 assets played as silence on Linux desktops (#prod-2026-05-21).
  Future<void> playMention() async {
    if (!_enabled) return;
    try {
      await _mentionPlayer
          .play(AssetSource('sounds/received.ogg'), volume: 0.6)
          .catchError((Object e) {
            debugPrint('[Sound] Failed to play mention sound (late): $e');
          });
    } catch (e) {
      debugPrint('[Sound] Failed to play mention sound: $e');
    }
  }

  /// Play descending chime when leaving a voice channel.
  Future<void> playVoiceLeave() async {
    if (!_enabled) return;
    try {
      await _voiceLeavePlayer.play(
        AssetSource('sounds/voice_leave.ogg'),
        volume: 0.5,
      );
    } catch (e) {
      debugPrint('[Sound] Failed to play voice leave sound: $e');
    }
  }

  void dispose() {
    _sentPlayer.dispose();
    _receivedPlayer.dispose();
    _mentionPlayer.dispose();
    _voiceJoinPlayer.dispose();
    _voiceLeavePlayer.dispose();
  }
}
