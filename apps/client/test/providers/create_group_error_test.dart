import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

import '../helpers/mock_http_client.dart';
import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// #1161: surface the real server-side reason when group creation fails.
//
// createGroup must throw a [GroupException] whose message is safe to display
// to the user (the toast in new_message_screen.dart reads e.message verbatim).
// ---------------------------------------------------------------------------

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
        authProvider.overrideWith(
          () => FakeLoggedInAuthNotifier(
            const AuthState(
              isLoggedIn: true,
              userId: 'me',
              username: 'testuser',
              token: 'fake-token',
              refreshToken: 'fake-refresh',
            ),
          ),
        ),
        serverUrlProvider.overrideWith(
          () => FakeServerUrlNotifier('http://localhost:8080'),
        ),
        privacyProvider.overrideWith(Privacy.new),
      ],
    );
  });

  tearDown(() => container.dispose());

  group('ConversationsNotifier.createGroup error surfacing', () {
    test(
      '409 with server message throws GroupException carrying that message',
      () async {
        when(
          () => mockClient.post(
            any(that: predicate<Uri>((u) => u.path == '/api/groups')),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenAnswer(
          (_) async => http.Response('{"error": "Group name taken"}', 409),
        );

        final notifier = container.read(conversationsProvider.notifier);
        await expectLater(
          http.runWithClient(
            () => notifier.createGroup('Dupes', ['u1', 'u2']),
            () => mockClient,
          ),
          throwsA(
            isA<GroupException>().having(
              (e) => e.message,
              'message',
              'Group name taken',
            ),
          ),
        );
      },
    );

    test(
      'network failure throws GroupException with _friendlyError translation',
      () async {
        when(
          () => mockClient.post(
            any(that: predicate<Uri>((u) => u.path == '/api/groups')),
            headers: any(named: 'headers'),
            body: any(named: 'body'),
            encoding: any(named: 'encoding'),
          ),
        ).thenThrow(const SocketException('Connection refused'));

        final notifier = container.read(conversationsProvider.notifier);
        await expectLater(
          http.runWithClient(
            () => notifier.createGroup('Whatever', ['u1', 'u2']),
            () => mockClient,
          ),
          throwsA(
            isA<GroupException>().having(
              (e) => e.message,
              'message',
              predicate<String>(
                (m) => m.isNotEmpty && m != 'Failed to create group',
                'is a friendly non-empty message, not the generic fallback',
              ),
            ),
          ),
        );
      },
    );
  });
}
