/// Tests for [PipController] — the Picture-in-Picture method-channel
/// shim.  Mocks `us.echomessenger/pip` so the tests don't need a real
/// Android / iOS device, and validates:
///   - default 16:9 fallback when caller passes 0,0
///   - eligibility de-dup when called with the same dimensions
///   - disable() flushes state and asks the native side to clear
///   - onPipChanged platform callbacks update [isInPipNotifier]
library;

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/pip_controller.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel('us.echomessenger/pip');
  late List<MethodCall> calls;

  setUp(() {
    PipController.debugTreatAsMobile = true;
    PipController.instance.resetForTesting();
    calls = <MethodCall>[];
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          calls.add(call);
          if (call.method == 'enterPip') return true;
          return null;
        });
  });

  tearDown(() {
    PipController.debugTreatAsMobile = false;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  test('enable() with 0x0 falls back to a 16:9 default', () async {
    await PipController.instance.enable(width: 0, height: 0);
    final call = calls.singleWhere((c) => c.method == 'setEligible');
    expect(call.arguments, {'width': 1280, 'height': 720});
    expect(PipController.instance.isEligible, isTrue);
  });

  test('enable() de-dupes when called with the same dimensions', () async {
    await PipController.instance.enable(width: 1920, height: 1080);
    await PipController.instance.enable(width: 1920, height: 1080);
    expect(calls.where((c) => c.method == 'setEligible').length, 1);
  });

  test('enable() with new dimensions re-issues setEligible', () async {
    await PipController.instance.enable(width: 1280, height: 720);
    await PipController.instance.enable(width: 1920, height: 1080);
    expect(calls.where((c) => c.method == 'setEligible').length, 2);
  });

  test('disable() clears state and pushes 0,0', () async {
    await PipController.instance.enable(width: 1280, height: 720);
    await PipController.instance.disable();
    final last = calls.last;
    expect(last.method, 'setEligible');
    expect(last.arguments, {'width': 0, 'height': 0});
    expect(PipController.instance.isEligible, isFalse);
  });

  test('disable() is a no-op when never enabled', () async {
    await PipController.instance.disable();
    expect(calls, isEmpty);
  });

  test('enterPip() requires eligibility first', () async {
    final accepted = await PipController.instance.enterPip();
    expect(accepted, isFalse);
    expect(calls.where((c) => c.method == 'enterPip'), isEmpty);
  });

  test('enterPip() forwards once eligible', () async {
    await PipController.instance.enable(width: 1280, height: 720);
    final accepted = await PipController.instance.enterPip();
    expect(accepted, isTrue);
    expect(calls.where((c) => c.method == 'enterPip').length, 1);
  });

  test('onPipChanged callback flips isInPipNotifier', () async {
    expect(PipController.instance.isInPipNotifier.value, isFalse);

    const codec = StandardMethodCodec();
    final payload = codec.encodeMethodCall(
      const MethodCall('onPipChanged', {'inPip': true}),
    );
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage('us.echomessenger/pip', payload, (_) {});
    await Future<void>.delayed(Duration.zero);

    expect(PipController.instance.isInPipNotifier.value, isTrue);
  });
}
