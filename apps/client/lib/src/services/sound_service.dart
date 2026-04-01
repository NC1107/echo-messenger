import 'package:audioplayers/audioplayers.dart';
import 'package:flutter/foundation.dart';

/// Simple service for playing UI sound effects.
///
/// Uses the audioplayers package which supports web via HTML5 audio.
class SoundService {
  static final SoundService _instance = SoundService._();
  factory SoundService() => _instance;
  SoundService._();

  final AudioPlayer _sentPlayer = AudioPlayer();
  final AudioPlayer _receivedPlayer = AudioPlayer();

  bool enabled = true;

  /// Play a short "whoosh" sound when the user sends a message.
  Future<void> playMessageSent() async {
    if (!enabled) return;
    try {
      await _sentPlayer.play(AssetSource('sounds/sent.mp3'), volume: 0.4);
    } catch (e) {
      debugPrint('[Sound] Failed to play sent sound: $e');
    }
  }

  /// Play a short "ding" sound when a new message is received.
  Future<void> playMessageReceived() async {
    if (!enabled) return;
    try {
      await _receivedPlayer.play(
        AssetSource('sounds/received.mp3'),
        volume: 0.3,
      );
    } catch (e) {
      debugPrint('[Sound] Failed to play received sound: $e');
    }
  }

  void dispose() {
    _sentPlayer.dispose();
    _receivedPlayer.dispose();
  }
}
