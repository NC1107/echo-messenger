import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// Simple service for playing UI sound effects.
///
/// Uses the audioplayers package which supports web via HTML5 audio.
class SoundService {
  static final SoundService _instance = SoundService._();
  factory SoundService() => _instance;
  SoundService._();

  static const _prefKey = 'sound_enabled';

  final AudioPlayer _sentPlayer = AudioPlayer();
  final AudioPlayer _receivedPlayer = AudioPlayer();
  final AudioPlayer _voiceJoinPlayer = AudioPlayer();
  final AudioPlayer _voiceLeavePlayer = AudioPlayer();

  bool _enabled = true;
  bool _initialized = false;

  /// Whether sound effects are currently enabled.
  bool get enabled => _enabled;

  /// Toggle sound effects on or off and persist the preference.
  set enabled(bool value) {
    _enabled = value;
    _persist(value);
  }

  /// Load the persisted sound preference from SharedPreferences.
  /// Should be called once during app initialization.
  Future<void> init() async {
    if (_initialized) return;
    _initialized = true;
    try {
      final prefs = await SharedPreferences.getInstance();
      _enabled = prefs.getBool(_prefKey) ?? true;
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
      await _sentPlayer.play(AssetSource('sounds/sent.mp3'), volume: 0.4);
    } catch (e) {
      debugPrint('[Sound] Failed to play sent sound: $e');
    }
  }

  /// Play a short "ding" sound when a new message is received.
  Future<void> playMessageReceived() async {
    if (!_enabled) return;
    try {
      await _receivedPlayer.play(
        AssetSource('sounds/received.mp3'),
        volume: 0.3,
      );
    } catch (e) {
      debugPrint('[Sound] Failed to play received sound: $e');
    }
  }

  /// Play ascending chime when joining a voice channel.
  Future<void> playVoiceJoin() async {
    if (!_enabled) return;
    try {
      await _voiceJoinPlayer.play(
        AssetSource('sounds/voice_join.mp3'),
        volume: 0.5,
      );
    } catch (e) {
      debugPrint('[Sound] Failed to play voice join sound: $e');
    }
  }

  /// Play descending chime when leaving a voice channel.
  Future<void> playVoiceLeave() async {
    if (!_enabled) return;
    try {
      await _voiceLeavePlayer.play(
        AssetSource('sounds/voice_leave.mp3'),
        volume: 0.5,
      );
    } catch (e) {
      debugPrint('[Sound] Failed to play voice leave sound: $e');
    }
  }

  void dispose() {
    _sentPlayer.dispose();
    _receivedPlayer.dispose();
    _voiceJoinPlayer.dispose();
    _voiceLeavePlayer.dispose();
  }
}
