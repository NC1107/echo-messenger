import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:echo_app/src/services/push_token_service.dart';

import '../helpers/mock_http_client.dart';

void main() {
  setUpAll(() {
    registerHttpFallbackValues();
  });

  group('PushTokenService', () {
    late MockHttpClient mockClient;
    late PushTokenService service;

    setUp(() {
      mockClient = MockHttpClient();
      when(() => mockClient.close()).thenReturn(null);
      service = PushTokenService.instance;
    });

    // -----------------------------------------------------------------------
    // unregister() — skips when no token has been set
    // -----------------------------------------------------------------------

    test('unregister() is a no-op when no current token', () async {
      // Do not configure _serverUrl or _authToken — neither is set.
      // No HTTP call should be made.
      await http.runWithClient(() async {
        await service.unregister();
      }, () => mockClient);

      verifyNever(
        () => mockClient.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      );
    });

    // -----------------------------------------------------------------------
    // unregister() — sends correct payload when a token is present
    // -----------------------------------------------------------------------

    test('unregister() sends DELETE request with device token', () async {
      // Use the test-only setter to inject state without going through the
      // iOS MethodChannel (which is unavailable in unit tests).
      service.setAuthToken('bearer-tok');
      service.setServerUrl('http://localhost:8080');
      service.setCurrentTokenForTest('apns-device-token-xyz');

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/push/unregister')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(jsonEncode({'status': 'ok'}), 200),
      );

      await http.runWithClient(() async {
        await service.unregister();
      }, () => mockClient);

      final captured = verify(
        () => mockClient.post(
          captureAny(
            that: predicate<Uri>((u) => u.path == '/api/push/unregister'),
          ),
          headers: captureAny(named: 'headers'),
          body: captureAny(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).captured;

      // Verify the URL, auth header, and body token.
      final uri = captured[0] as Uri;
      expect(uri.path, '/api/push/unregister');

      final headers = captured[1] as Map<String, String>;
      expect(headers['Authorization'], 'Bearer bearer-tok');

      final body = jsonDecode(captured[2] as String) as Map<String, dynamic>;
      expect(body['token'], 'apns-device-token-xyz');

      // Token should be cleared after unregister.
      // Calling unregister again should be a no-op.
      await http.runWithClient(() async {
        await service.unregister();
      }, () => mockClient);

      verifyNever(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/push/unregister')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      );
    });

    // -----------------------------------------------------------------------
    // unregister() — network errors are silently swallowed
    // -----------------------------------------------------------------------

    test('unregister() does not throw on network error', () async {
      service.setAuthToken('bearer-tok');
      service.setServerUrl('http://localhost:8080');
      service.setCurrentTokenForTest('apns-device-token-err');

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/push/unregister')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(Exception('network error'));

      // Should complete without throwing.
      await expectLater(
        http.runWithClient(() => service.unregister(), () => mockClient),
        completes,
      );
    });

    // -----------------------------------------------------------------------
    // setAuthToken() — updated token is used in subsequent calls
    // -----------------------------------------------------------------------

    test('setAuthToken() updates the auth token used in requests', () async {
      service.setServerUrl('http://localhost:8080');
      service.setCurrentTokenForTest('apns-token-for-auth-update');
      service.setAuthToken('old-tok');
      service.setAuthToken('new-tok');

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/push/unregister')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async => http.Response(jsonEncode({'status': 'ok'}), 200),
      );

      await http.runWithClient(() async {
        await service.unregister();
      }, () => mockClient);

      final captured = verify(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/push/unregister')),
          headers: captureAny(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).captured;

      final headers = captured[0] as Map<String, String>;
      expect(headers['Authorization'], 'Bearer new-tok');
    });
  });
}
