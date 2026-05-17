/// Unit tests for [PushToTalkListener].
///
/// Verifies that the hardware-keyboard handler correctly calls
/// [SetCaptureEnabledCallback] on key-down / key-up events for the
/// configured PTT key, ignores unrelated keys, and respects the
/// idempotent start/stop lifecycle.
///
/// Key-event tests use [simulateKeyDownEvent] / [simulateKeyUpEvent] from
/// `flutter_test`.  [HardwareKeyboard] asserts that every key-up is preceded
/// by a matching key-down, so every test that presses a key must also release
/// it before the test returns.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/push_to_talk_listener.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  // Collect calls so each test can assert on them independently.
  late List<bool> captureEvents;
  late PushToTalkListener listener;

  // Space bar is the default PTT key (LogicalKeyboardKey.space.keyId == 32).
  const pttKey = LogicalKeyboardKey.space;
  final pttKeyId = pttKey.keyId.toString(); // '32'

  setUp(() {
    captureEvents = [];
    listener = PushToTalkListener(
      keyId: pttKeyId,
      onSetCaptureEnabled: captureEvents.add,
    );
  });

  tearDown(() {
    listener.stop();
  });

  group('PushToTalkListener lifecycle', () {
    test('isRunning is false before start', () {
      expect(listener.isRunning, isFalse);
    });

    test('isRunning becomes true after start', () {
      listener.start();
      expect(listener.isRunning, isTrue);
    });

    test('isRunning becomes false after stop', () {
      listener.start();
      listener.stop();
      expect(listener.isRunning, isFalse);
    });

    test('start() is idempotent — double start does not double-fire', () async {
      listener.start();
      listener.start(); // second call must be a no-op

      await simulateKeyDownEvent(pttKey, platform: 'linux');
      await simulateKeyUpEvent(pttKey, platform: 'linux');

      // Expect exactly one down + one up, not two of each.
      expect(captureEvents, [true, false]);
    });

    test('stop() is idempotent — double stop does not throw', () {
      listener.start();
      listener.stop();
      expect(() => listener.stop(), returnsNormally);
      expect(listener.isRunning, isFalse);
    });
  });

  group('PushToTalkListener key handling', () {
    setUp(() => listener.start());

    test('key-down / key-up pair fires true then false', () async {
      await simulateKeyDownEvent(pttKey, platform: 'linux');
      await simulateKeyUpEvent(pttKey, platform: 'linux');
      expect(captureEvents, [true, false]);
    });

    test('unrelated key does not fire callback', () async {
      await simulateKeyDownEvent(LogicalKeyboardKey.keyA, platform: 'linux');
      await simulateKeyUpEvent(LogicalKeyboardKey.keyA, platform: 'linux');
      expect(captureEvents, isEmpty);
    });

    test('handler does not fire after stop()', () async {
      listener.stop();
      await simulateKeyDownEvent(pttKey, platform: 'linux');
      await simulateKeyUpEvent(pttKey, platform: 'linux');
      expect(captureEvents, isEmpty);
    });

    test('handler fires again after restart', () async {
      listener.stop();
      listener.start();
      await simulateKeyDownEvent(pttKey, platform: 'linux');
      await simulateKeyUpEvent(pttKey, platform: 'linux');
      expect(captureEvents, [true, false]);
    });

    test('multiple press-release cycles accumulate events in order', () async {
      await simulateKeyDownEvent(pttKey, platform: 'linux');
      await simulateKeyUpEvent(pttKey, platform: 'linux');
      await simulateKeyDownEvent(pttKey, platform: 'linux');
      await simulateKeyUpEvent(pttKey, platform: 'linux');
      expect(captureEvents, [true, false, true, false]);
    });
  });

  group('PushToTalkListener custom key binding', () {
    test('respects a non-default keyId (Enter key)', () async {
      const enterKey = LogicalKeyboardKey.enter;
      final enterKeyId = enterKey.keyId.toString();
      final enterListener = PushToTalkListener(
        keyId: enterKeyId,
        onSetCaptureEnabled: captureEvents.add,
      );
      addTearDown(enterListener.stop);
      enterListener.start();

      // Enter press/release should trigger the callback.
      await simulateKeyDownEvent(enterKey, platform: 'linux');
      await simulateKeyUpEvent(enterKey, platform: 'linux');
      expect(captureEvents, [true, false]);

      // Space must be ignored by this listener.
      captureEvents.clear();
      await simulateKeyDownEvent(pttKey, platform: 'linux');
      await simulateKeyUpEvent(pttKey, platform: 'linux');
      expect(captureEvents, isEmpty);
    });
  });
}
