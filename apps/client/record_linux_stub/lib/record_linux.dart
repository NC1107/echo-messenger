import 'dart:async';
import 'dart:typed_data';
import 'package:record_platform_interface/record_platform_interface.dart';

/// Stub — voice recording is not supported on Linux desktop.
class RecordLinux extends RecordPlatform {
  static void registerWith() {
    RecordPlatform.instance = RecordLinux();
  }

  @override
  Future<void> cancel(String recorderId) async {}

  @override
  Future<void> create(String recorderId) async {}

  @override
  Future<void> dispose(String recorderId) async {}

  @override
  Future<Amplitude> getAmplitude(String recorderId) async =>
      Amplitude(current: -160.0, max: -160.0);

  @override
  Future<bool> hasPermission(String recorderId, {bool request = false}) async => false;

  @override
  Future<bool> isEncoderSupported(String recorderId, AudioEncoder encoder) async => false;

  @override
  Future<bool> isPaused(String recorderId) async => false;

  @override
  Future<bool> isRecording(String recorderId) async => false;

  @override
  Future<List<InputDevice>> listInputDevices(String recorderId) async => const [];

  @override
  Stream<RecordState> onStateChanged(String recorderId) => const Stream.empty();

  @override
  Future<void> pause(String recorderId) async {}

  @override
  Future<void> resume(String recorderId) async {}

  @override
  Future<void> start(String recorderId, RecordConfig config, {required String path}) async {}

  @override
  Future<Stream<Uint8List>> startStream(String recorderId, RecordConfig config) async =>
      const Stream.empty();

  @override
  Future<String?> stop(String recorderId) async => null;
}
