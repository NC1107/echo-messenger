import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/livekit_voice/livekit_voice_provider.dart';

void main() {
  group('deriveLiveKitUrl', () {
    test('apex echo-messenger.us derives livekit.echo-messenger.us', () {
      expect(
        deriveLiveKitUrl('https://echo-messenger.us'),
        'wss://livekit.echo-messenger.us',
      );
    });

    test('us-east regional API host normalizes to apex', () {
      expect(
        deriveLiveKitUrl('https://us-east.echo-messenger.us'),
        'wss://livekit.echo-messenger.us',
      );
    });

    test('arbitrary future region (eu) normalizes to apex', () {
      expect(
        deriveLiveKitUrl('https://eu.echo-messenger.us'),
        'wss://livekit.echo-messenger.us',
      );
    });

    test('self-host preserves verbatim host prefix', () {
      expect(
        deriveLiveKitUrl('https://chat.example.com'),
        'wss://livekit.chat.example.com',
      );
    });

    test('http schemes downgrade to ws', () {
      expect(
        deriveLiveKitUrl('http://localhost:8080'),
        'ws://livekit.localhost',
      );
    });

    test('echo lookalike domain is not normalized', () {
      expect(
        deriveLiveKitUrl('https://fakeecho-messenger.us'),
        'wss://livekit.fakeecho-messenger.us',
      );
    });
  });
}
