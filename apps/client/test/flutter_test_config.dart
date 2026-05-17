import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Global test setup — runs once before any test in this package.
///
/// Mocks platform-channel plugins that don't have a registered Dart
/// implementation in the test binary (audioplayers, flutter_secure_storage,
/// flutter_local_notifications). Without these mocks, a fire-and-forget
/// `SoundService().playMessageReceived()` triggers `MissingPluginException`
/// on `xyz.luan/audioplayers.global.init`, which leaks past the test
/// boundary and fails the test even though it never actually played.
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  TestWidgetsFlutterBinding.ensureInitialized();
  _stubPlatformChannel('xyz.luan/audioplayers.global');
  _stubPlatformChannel('xyz.luan/audioplayers');
  await testMain();
}

void _stubPlatformChannel(String name) {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(MethodChannel(name), (call) async => null);
}
