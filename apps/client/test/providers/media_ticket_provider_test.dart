import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/media_ticket_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a [ProviderContainer] with auth pre-seeded as logged in and a known
/// server URL so that [mediaTicketProvider] calls _fetch immediately on build.
ProviderContainer _makeContainer({String? token = 'fake-jwt'}) {
  SharedPreferences.setMockInitialValues({});
  return ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) {
        final n = AuthNotifier(ref);
        n.state = AuthState(
          isLoggedIn: token != null,
          userId: 'user-1',
          username: 'testuser',
          token: token,
          refreshToken: 'refresh-tok',
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
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('MediaTicket provider -- success path (#539)', () {
    test(
      'state becomes ticket string when server returns 200 with ticket',
      () async {
        final container = _makeContainer();
        addTearDown(container.dispose);

        await http.runWithClient(
          () async {
            // Read the provider (triggers build → _fetch).
            container.read(mediaTicketProvider);

            // Pump async work so _fetch completes and state is set.
            await Future<void>.delayed(Duration.zero);
            await Future<void>.delayed(Duration.zero);

            expect(
              container.read(mediaTicketProvider),
              'test-media-ticket-abc',
              reason:
                  'provider should expose the ticket string from server response',
            );
          },
          () => MockClient(
            (_) async => http.Response(
              jsonEncode({'ticket': 'test-media-ticket-abc'}),
              200,
            ),
          ),
        );
      },
    );
  });

  group('MediaTicket provider -- failure paths (#539)', () {
    test('state remains null when server returns 4xx', () async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      await http.runWithClient(() async {
        container.read(mediaTicketProvider);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(mediaTicketProvider),
          isNull,
          reason:
              '4xx response should leave ticket as null (graceful degradation)',
        );
      }, () => MockClient((_) async => http.Response('Unauthorized', 401)));
    });

    test('state remains null when network throws', () async {
      final container = _makeContainer();
      addTearDown(container.dispose);

      await http.runWithClient(() async {
        container.read(mediaTicketProvider);
        await Future<void>.delayed(Duration.zero);
        await Future<void>.delayed(Duration.zero);

        expect(
          container.read(mediaTicketProvider),
          isNull,
          reason:
              'network error should leave ticket as null (graceful degradation)',
        );
      }, () => MockClient((_) async => throw Exception('connection refused')));
    });

    test('state remains null when not logged in', () async {
      // Provider should not issue an HTTP request when there is no auth token.
      final container = _makeContainer(token: null);
      addTearDown(container.dispose);

      var requestCount = 0;
      await http.runWithClient(
        () async {
          container.read(mediaTicketProvider);
          await Future<void>.delayed(Duration.zero);

          expect(container.read(mediaTicketProvider), isNull);
          expect(
            requestCount,
            0,
            reason: 'no HTTP call should be made without a token',
          );
        },
        () => MockClient((_) async {
          requestCount++;
          return http.Response('', 200);
        }),
      );
    });
  });
}
