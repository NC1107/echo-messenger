import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

import '../helpers/mock_http_client.dart';

void main() {
  late MockHttpClient mockClient;
  late ProviderContainer container;

  setUpAll(() {
    registerHttpFallbackValues();
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    mockClient = MockHttpClient();
    when(() => mockClient.close()).thenReturn(null);

    container = ProviderContainer(
      overrides: [
        authProvider.overrideWith((ref) {
          final n = AuthNotifier(ref);
          n.state = const AuthState(
            isLoggedIn: true,
            userId: 'me',
            username: 'testuser',
            token: 'fake-token',
            refreshToken: 'fake-refresh',
          );
          return n;
        }),
        serverUrlProvider.overrideWith((ref) {
          final n = ServerUrlNotifier();
          n.state = 'http://localhost:8080';
          return n;
        }),
      ],
    );
  });

  tearDown(() => container.dispose());

  group('ChannelsNotifier.loadChannels', () {
    test('parses and sorts channels on 200', () async {
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/groups/g1/channels')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode([
            {
              'id': 'ch-2',
              'conversation_id': 'g1',
              'name': 'voice-1',
              'kind': 'voice',
              'position': 0,
              'created_at': '2026-01-01',
            },
            {
              'id': 'ch-1',
              'conversation_id': 'g1',
              'name': 'general',
              'kind': 'text',
              'position': 0,
              'created_at': '2026-01-01',
            },
          ]),
          200,
        ),
      );
      // Stub voice session load for voice channels.
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path.contains('/voice'))),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('[]', 200));

      final notifier = container.read(channelsProvider.notifier);
      await http.runWithClient(
        () => notifier.loadChannels('g1'),
        () => mockClient,
      );

      final channels = notifier.state.channelsFor('g1');
      expect(channels, hasLength(2));
      // Sorted by kind (text < voice), then position, then name.
      expect(channels.first.kind, 'text');
      expect(channels.last.kind, 'voice');
    });

    test('sets error on non-200', () async {
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/groups/g1/channels')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('not found', 404));

      final notifier = container.read(channelsProvider.notifier);
      await http.runWithClient(
        () => notifier.loadChannels('g1'),
        () => mockClient,
      );

      expect(notifier.state.error, isNotNull);
    });
  });

  group('ChannelsNotifier.createChannel', () {
    test('returns true on 201', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/groups/g1/channels')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 201));
      // Stub the loadChannels call that happens after create.
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/groups/g1/channels')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('[]', 200));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.createChannel('g1', 'new-channel', 'text'),
        () => mockClient,
      );

      expect(result, isTrue);
    });

    test('returns false on failure', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/groups/g1/channels')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('error', 500));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.createChannel('g1', 'ch', 'text'),
        () => mockClient,
      );

      expect(result, isFalse);
    });
  });

  group('ChannelsNotifier.deleteChannel', () {
    test('returns true on 200', () async {
      when(
        () => mockClient.delete(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/groups/g1/channels/ch-1',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('', 200));
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/groups/g1/channels')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) async => http.Response('[]', 200));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.deleteChannel('g1', 'ch-1'),
        () => mockClient,
      );

      expect(result, isTrue);
    });

    test('returns false on failure', () async {
      when(
        () => mockClient.delete(
          any(
            that: predicate<Uri>(
              (u) => u.path == '/api/groups/g1/channels/ch-1',
            ),
          ),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('', 403));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.deleteChannel('g1', 'ch-1'),
        () => mockClient,
      );

      expect(result, isFalse);
    });
  });

  group('ChannelsNotifier.joinVoiceChannel', () {
    test('returns true on 200', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path.contains('/voice/join'))),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => http.Response('[]', 200));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.joinVoiceChannel('g1', 'ch-1'),
        () => mockClient,
      );

      expect(result, isTrue);
    });

    test('returns false on non-200', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path.contains('/voice/join'))),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('error', 500));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.joinVoiceChannel('g1', 'ch-1'),
        () => mockClient,
      );

      expect(result, isFalse);
    });
  });

  group('ChannelsNotifier.leaveVoiceChannel', () {
    test('returns true on 200', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path.contains('/voice/leave'))),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => http.Response('[]', 200));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.leaveVoiceChannel('g1', 'ch-1'),
        () => mockClient,
      );

      expect(result, isTrue);
    });

    test('returns true on 400 with "no voice session found"', () async {
      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path.contains('/voice/leave'))),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('no voice session found', 400));
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => http.Response('[]', 200));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.leaveVoiceChannel('g1', 'ch-1'),
        () => mockClient,
      );

      expect(result, isTrue);
    });
  });

  group('ChannelsNotifier.updateVoiceState', () {
    test('returns true on 200 and sends correct body', () async {
      String? capturedBody;
      when(
        () => mockClient.put(
          any(that: predicate<Uri>((u) => u.path.contains('/voice/state'))),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((inv) async {
        capturedBody = inv.namedArguments[#body] as String?;
        return http.Response('{}', 200);
      });
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => http.Response('[]', 200));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.updateVoiceState(
          conversationId: 'g1',
          channelId: 'ch-1',
          isMuted: true,
          isDeafened: false,
          pushToTalk: true,
        ),
        () => mockClient,
      );

      expect(result, isTrue);
      expect(capturedBody, isNotNull);
      final parsed = jsonDecode(capturedBody!) as Map<String, dynamic>;
      expect(parsed['is_muted'], isTrue);
      expect(parsed['is_deafened'], isFalse);
      expect(parsed['push_to_talk'], isTrue);
    });

    test('returns false on failure', () async {
      when(
        () => mockClient.put(
          any(that: predicate<Uri>((u) => u.path.contains('/voice/state'))),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('error', 500));

      final notifier = container.read(channelsProvider.notifier);
      final result = await http.runWithClient(
        () => notifier.updateVoiceState(
          conversationId: 'g1',
          channelId: 'ch-1',
          isMuted: false,
          isDeafened: false,
          pushToTalk: false,
        ),
        () => mockClient,
      );

      expect(result, isFalse);
    });
  });
}
