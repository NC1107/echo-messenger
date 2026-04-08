import 'package:flutter/foundation.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:shared_preferences/shared_preferences.dart';

class VoiceSettingsState {
  final String inputDeviceId;
  final String outputDeviceId;
  final String cameraDeviceId;
  final double inputGain;
  final double outputVolume;
  final bool pushToTalkEnabled;
  final String pushToTalkKeyId;
  final String pushToTalkKeyLabel;
  final bool selfMuted;
  final bool selfDeafened;
  final bool noiseSuppression;
  final bool echoCancellation;
  final bool autoGainControl;

  const VoiceSettingsState({
    this.inputDeviceId = 'default',
    this.outputDeviceId = 'default',
    this.cameraDeviceId = 'default',
    this.inputGain = 1.0,
    this.outputVolume = 1.0,
    this.pushToTalkEnabled = false,
    this.pushToTalkKeyId = '32',
    this.pushToTalkKeyLabel = 'Space',
    this.selfMuted = false,
    this.selfDeafened = false,
    this.noiseSuppression = true,
    this.echoCancellation = true,
    this.autoGainControl = true,
  });

  VoiceSettingsState copyWith({
    String? inputDeviceId,
    String? outputDeviceId,
    String? cameraDeviceId,
    double? inputGain,
    double? outputVolume,
    bool? pushToTalkEnabled,
    String? pushToTalkKeyId,
    String? pushToTalkKeyLabel,
    bool? selfMuted,
    bool? selfDeafened,
    bool? noiseSuppression,
    bool? echoCancellation,
    bool? autoGainControl,
  }) {
    return VoiceSettingsState(
      inputDeviceId: inputDeviceId ?? this.inputDeviceId,
      outputDeviceId: outputDeviceId ?? this.outputDeviceId,
      cameraDeviceId: cameraDeviceId ?? this.cameraDeviceId,
      inputGain: inputGain ?? this.inputGain,
      outputVolume: outputVolume ?? this.outputVolume,
      pushToTalkEnabled: pushToTalkEnabled ?? this.pushToTalkEnabled,
      pushToTalkKeyId: pushToTalkKeyId ?? this.pushToTalkKeyId,
      pushToTalkKeyLabel: pushToTalkKeyLabel ?? this.pushToTalkKeyLabel,
      selfMuted: selfMuted ?? this.selfMuted,
      selfDeafened: selfDeafened ?? this.selfDeafened,
      noiseSuppression: noiseSuppression ?? this.noiseSuppression,
      echoCancellation: echoCancellation ?? this.echoCancellation,
      autoGainControl: autoGainControl ?? this.autoGainControl,
    );
  }
}

class VoiceSettingsNotifier extends StateNotifier<VoiceSettingsState> {
  VoiceSettingsNotifier() : super(const VoiceSettingsState()) {
    _load();
  }

  static const _keyInputDevice = 'voice_input_device_id';
  static const _keyOutputDevice = 'voice_output_device_id';
  static const _keyCameraDevice = 'voice_camera_device_id';
  static const _keyInputGain = 'voice_input_gain';
  static const _keyOutputVolume = 'voice_output_volume';
  static const _keyPushToTalk = 'voice_push_to_talk_enabled';
  static const _keyPushToTalkKeyId = 'voice_push_to_talk_key_id';
  static const _keyPushToTalkKeyLabel = 'voice_push_to_talk_key_label';
  static const _keySelfMuted = 'voice_self_muted';
  static const _keySelfDeafened = 'voice_self_deafened';
  static const _keyNoiseSuppression = 'voice_noise_suppression';
  static const _keyEchoCancellation = 'voice_echo_cancellation';
  static const _keyAutoGainControl = 'voice_auto_gain_control';

  Future<void> _load() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      state = state.copyWith(
        inputDeviceId: prefs.getString(_keyInputDevice) ?? 'default',
        outputDeviceId: prefs.getString(_keyOutputDevice) ?? 'default',
        cameraDeviceId: prefs.getString(_keyCameraDevice) ?? 'default',
        inputGain: prefs.getDouble(_keyInputGain) ?? 1.0,
        outputVolume: prefs.getDouble(_keyOutputVolume) ?? 1.0,
        pushToTalkEnabled: prefs.getBool(_keyPushToTalk) ?? false,
        pushToTalkKeyId: prefs.getString(_keyPushToTalkKeyId) ?? '32',
        pushToTalkKeyLabel: prefs.getString(_keyPushToTalkKeyLabel) ?? 'Space',
        selfMuted: prefs.getBool(_keySelfMuted) ?? false,
        selfDeafened: prefs.getBool(_keySelfDeafened) ?? false,
        noiseSuppression: prefs.getBool(_keyNoiseSuppression) ?? true,
        echoCancellation: prefs.getBool(_keyEchoCancellation) ?? true,
        autoGainControl: prefs.getBool(_keyAutoGainControl) ?? true,
      );
    } catch (e) {
      debugPrint('[VoiceSettings] load failed: $e');
    }
  }

  Future<void> _persist(VoiceSettingsState next) async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString(_keyInputDevice, next.inputDeviceId);
      await prefs.setString(_keyOutputDevice, next.outputDeviceId);
      await prefs.setString(_keyCameraDevice, next.cameraDeviceId);
      await prefs.setDouble(_keyInputGain, next.inputGain);
      await prefs.setDouble(_keyOutputVolume, next.outputVolume);
      await prefs.setBool(_keyPushToTalk, next.pushToTalkEnabled);
      await prefs.setString(_keyPushToTalkKeyId, next.pushToTalkKeyId);
      await prefs.setString(_keyPushToTalkKeyLabel, next.pushToTalkKeyLabel);
      await prefs.setBool(_keySelfMuted, next.selfMuted);
      await prefs.setBool(_keySelfDeafened, next.selfDeafened);
      await prefs.setBool(_keyNoiseSuppression, next.noiseSuppression);
      await prefs.setBool(_keyEchoCancellation, next.echoCancellation);
      await prefs.setBool(_keyAutoGainControl, next.autoGainControl);
    } catch (e) {
      debugPrint('[VoiceSettings] persist failed: $e');
    }
  }

  Future<void> setInputDevice(String value) async {
    final next = state.copyWith(inputDeviceId: value);
    state = next;
    await _persist(next);
  }

  Future<void> setOutputDevice(String value) async {
    final next = state.copyWith(outputDeviceId: value);
    state = next;
    await _persist(next);
  }

  Future<void> setCameraDevice(String value) async {
    final next = state.copyWith(cameraDeviceId: value);
    state = next;
    await _persist(next);
  }

  Future<void> setInputGain(double value) async {
    final next = state.copyWith(inputGain: value);
    state = next;
    await _persist(next);
  }

  Future<void> setOutputVolume(double value) async {
    final next = state.copyWith(outputVolume: value);
    state = next;
    await _persist(next);
  }

  Future<void> setPushToTalkEnabled(bool value) async {
    final next = state.copyWith(pushToTalkEnabled: value);
    state = next;
    await _persist(next);
  }

  Future<void> setPushToTalkKey({
    required String keyId,
    required String keyLabel,
  }) async {
    final next = state.copyWith(
      pushToTalkKeyId: keyId,
      pushToTalkKeyLabel: keyLabel,
    );
    state = next;
    await _persist(next);
  }

  Future<void> setSelfMuted(bool value) async {
    final next = state.copyWith(selfMuted: value);
    state = next;
    await _persist(next);
  }

  Future<void> setSelfDeafened(bool value) async {
    final next = state.copyWith(selfDeafened: value);
    state = next;
    await _persist(next);
  }

  Future<void> setNoiseSuppression(bool value) async {
    final next = state.copyWith(noiseSuppression: value);
    state = next;
    await _persist(next);
  }

  Future<void> setEchoCancellation(bool value) async {
    final next = state.copyWith(echoCancellation: value);
    state = next;
    await _persist(next);
  }

  Future<void> setAutoGainControl(bool value) async {
    final next = state.copyWith(autoGainControl: value);
    state = next;
    await _persist(next);
  }
}

final voiceSettingsProvider =
    StateNotifierProvider<VoiceSettingsNotifier, VoiceSettingsState>((ref) {
      return VoiceSettingsNotifier();
    });
