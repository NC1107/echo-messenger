import 'package:flutter_test/flutter_test.dart';

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
    test('is a no-op when no token has been registered (returns normally)', () async {
      // Without a current token or server URL, unregister is a no-op.
      await expectLater(
        PushTokenService.instance.unregister(),
        completes,
      );
    });
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
}
