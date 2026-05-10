/// Tests for [BackgroundService] — the Android foreground-service Dart
/// shim that exposes voice-aware notification controls and pipes Mute /
/// Leave taps back from the native receiver.
///
/// We mock the `us.echomessenger/foreground_service` MethodChannel so the
/// tests run cross-platform without an Android device, and validate:
///   - start/stop/startVoice/stopVoice idempotency + mode flags
///   - the on-platform method names + arguments are what the Kotlin side
///     expects (regression guard for accidental key renames)
///   - notification-action MethodCall payloads dispatch into the expected
///     [VoiceNotificationAction] subclasses on the broadcast stream.
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/background_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('us.echomessenger/foreground_service');
  late List<MethodCall> calls;

  setUp(() {
    BackgroundService.debugTreatAsAndroid = true;
    BackgroundService.instance.resetForTesting();
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          return null;
        });
  });

  tearDown(() {
    BackgroundService.debugTreatAsAndroid = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  group('keep-alive mode', () {
    test('start() invokes "start" once', () async {
      await BackgroundService.instance.start();
      await BackgroundService.instance.start();
      // Second call is a no-op while running.
      expect(calls.where((c) => c.method == 'start').length, 1);
    });

    test('stop() invokes "stop" once', () async {
      await BackgroundService.instance.start();
      await BackgroundService.instance.stop();
      await BackgroundService.instance.stop();
      expect(calls.where((c) => c.method == 'stop').length, 1);
    });

    test('start() is a no-op once voice is running', () async {
      await BackgroundService.instance.startVoice(
        channelName: 'lounge',
        isMuted: false,
        participantCount: 1,
      );
      await BackgroundService.instance.start();
      // Voice is the higher-privileged mode; start() must not downgrade.
      expect(calls.where((c) => c.method == 'start').length, 0);
    });
  });

  group('voice mode', () {
    test('startVoice() sends the expected arguments', () async {
      await BackgroundService.instance.startVoice(
        channelName: 'lounge',
        isMuted: true,
        participantCount: 4,
      );
      final call = calls.singleWhere((c) => c.method == 'startVoice');
      expect(call.arguments, {
        'channelName': 'lounge',
        'isMuted': true,
        'participantCount': 4,
      });
      expect(BackgroundService.instance.isVoiceRunning, isTrue);
    });

    test('updateVoice() is a no-op when voice is not running', () async {
      await BackgroundService.instance.updateVoice(
        channelName: 'lounge',
        isMuted: false,
      );
      expect(calls.where((c) => c.method == 'updateVoice'), isEmpty);
    });

    test('updateVoice() omits null fields from the payload', () async {
      await BackgroundService.instance.startVoice(
        channelName: 'lounge',
        isMuted: false,
        participantCount: 2,
      );
      await BackgroundService.instance.updateVoice(isMuted: true);

      final update = calls.singleWhere((c) => c.method == 'updateVoice');
      expect(update.arguments, {'isMuted': true});
    });

    test(
      'stopVoice() invokes the platform method and clears the flag',
      () async {
        await BackgroundService.instance.startVoice(
          channelName: 'lounge',
          isMuted: false,
          participantCount: 1,
        );
        await BackgroundService.instance.stopVoice();
        expect(calls.last.method, 'stopVoice');
        expect(BackgroundService.instance.isVoiceRunning, isFalse);
      },
    );
  });

  group('notification-action stream', () {
    test(
      'mute action dispatches a VoiceMuteAction with the new state',
      () async {
        // Arrange: subscribe before the platform "delivers" the action.
        final received = <VoiceNotificationAction>[];
        final sub = BackgroundService.instance.notificationActions.listen(
          received.add,
        );

        // Act: simulate a platform → Dart MethodCall as the Android receiver
        // would deliver it.
        const codec = StandardMethodCodec();
        final payload = codec.encodeMethodCall(
          const MethodCall('onNotificationAction', {
            'action': 'mute',
            'muted': true,
          }),
        );
        await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
            .handlePlatformMessage(
              'us.echomessenger/foreground_service',
              payload,
              (_) {},
            );

        // Assert.
        await Future<void>.delayed(Duration.zero);
        expect(received, hasLength(1));
        final action = received.single;
        expect(action, isA<VoiceMuteAction>());
        expect((action as VoiceMuteAction).muted, isTrue);

        await sub.cancel();
      },
    );

    test('leave action dispatches a VoiceLeaveAction', () async {
      final received = <VoiceNotificationAction>[];
      final sub = BackgroundService.instance.notificationActions.listen(
        received.add,
      );

      const codec = StandardMethodCodec();
      final payload = codec.encodeMethodCall(
        const MethodCall('onNotificationAction', {'action': 'leave'}),
      );
      await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            'us.echomessenger/foreground_service',
            payload,
            (_) {},
          );

      await Future<void>.delayed(Duration.zero);
      expect(received, hasLength(1));
      expect(received.single, isA<VoiceLeaveAction>());

      await sub.cancel();
    });
  });
}
