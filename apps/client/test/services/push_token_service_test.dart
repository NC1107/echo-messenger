import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:echo_app/src/services/push_token_service.dart';

void main() {
  // PushTokenService is a singleton; reset between tests by calling
  // setAuthToken or simply reading from the instance.

  group('PushTokenService singleton', () {
    test('instance returns the same object on repeated calls', () {
      final a = PushTokenService.instance;
      final b = PushTokenService.instance;
      expect(identical(a, b), isTrue);
    });
  });

  group('PushTokenService.setAuthToken', () {
    test('accepts a token string without throwing', () {
      expect(
        () => PushTokenService.instance.setAuthToken('new-jwt-token'),
        returnsNormally,
      );
    });

    test('can be called multiple times without error', () {
      PushTokenService.instance.setAuthToken('token-1');
      PushTokenService.instance.setAuthToken('token-2');
      PushTokenService.instance.setAuthToken('token-3');
    });
  });

  group('PushTokenService.unregister', () {
    test(
      'is a no-op when no token has been registered (returns normally)',
      () async {
        // Without a current token or server URL, unregister is a no-op.
        await expectLater(PushTokenService.instance.unregister(), completes);
      },
    );
  });

  group('PushTokenService.init', () {
    // On test platforms (non-iOS, non-web) init() is a documented no-op.
    // We verify it returns without throwing.
    test('init is a no-op on non-iOS platforms and returns normally', () {
      expect(
        () => PushTokenService.instance.init(
          serverUrl: 'http://localhost:8080',
          authToken: 'test-token',
          onWake: () {},
        ),
        returnsNormally,
      );
    });

    test('init can be called multiple times without error', () {
      PushTokenService.instance.init(
        serverUrl: 'http://localhost:8080',
        authToken: 'token-a',
        onWake: () {},
      );
      PushTokenService.instance.init(
        serverUrl: 'http://localhost:8080',
        authToken: 'token-b',
        onWake: () {},
      );
    });
  });

  // ---------------------------------------------------------------------------
  // HTTP-layer coverage for deregister -- #539
  // ---------------------------------------------------------------------------

  group('PushTokenService.deregister -- HTTP paths', () {
    test('calls DELETE /api/push/token and completes on 200', () async {
      var hitCount = 0;

      await http.runWithClient(
        () async {
          await PushTokenService.instance.deregister(
            serverUrl: 'http://localhost:8080',
            authToken: 'jwt-token',
          );
          expect(
            hitCount,
            1,
            reason: 'exactly one DELETE request should be sent',
          );
        },
        () => MockClient((req) async {
          expect(req.method, 'DELETE');
          expect(req.url.path, '/api/push/token');
          expect(req.headers['Authorization'], 'Bearer jwt-token');
          hitCount++;
          return http.Response('{"status":"ok"}', 200);
        }),
      );
    });

    test('swallows network errors and completes without throwing', () async {
      await http.runWithClient(() async {
        // Should not throw even when the network is unavailable.
        await expectLater(
          PushTokenService.instance.deregister(
            serverUrl: 'http://localhost:8080',
            authToken: 'jwt-token',
          ),
          completes,
        );
      }, () => MockClient((_) async => throw Exception('connection refused')));
    });

    test('is a no-op when serverUrl is empty', () async {
      var hitCount = 0;
      await http.runWithClient(
        () async {
          await PushTokenService.instance.deregister(
            serverUrl: '',
            authToken: 'tok',
          );
          expect(hitCount, 0, reason: 'no HTTP call when serverUrl is empty');
        },
        () => MockClient((_) async {
          hitCount++;
          return http.Response('', 200);
        }),
      );
    });
  });
}
