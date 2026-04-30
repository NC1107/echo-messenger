import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/media_ticket_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

import '../helpers/mock_http_client.dart';

void main() {
  setUpAll(() {
    registerHttpFallbackValues();
  });

  group('MediaTicketNotifier', () {
    late MockHttpClient mockClient;
    late ProviderContainer container;

    /// Returns a [ProviderContainer] with the server URL fixed to localhost
    /// and the auth state preset to [authState].
    ProviderContainer buildContainer(AuthState authState) {
      final c = ProviderContainer(
        overrides: [
          serverUrlProvider.overrideWith((ref) {
            final n = ServerUrlNotifier();
            n.state = 'http://localhost:8080';
            return n;
          }),
          authProvider.overrideWith((ref) {
            final n = AuthNotifier(ref);
            n.state = authState;
            return n;
          }),
        ],
      );
      addTearDown(c.dispose);
      return c;
    }

    setUp(() {
      SharedPreferences.setMockInitialValues({});
      mockClient = MockHttpClient();
      when(() => mockClient.close()).thenReturn(null);
    });

    // -----------------------------------------------------------------------
    // Initial state
    // -----------------------------------------------------------------------

    test('initial state is null when logged out', () {
      container = buildContainer(const AuthState());

      // Provider is read inside runWithClient so the mock intercepts any call.
      http.runWithClient(() {
        final ticket = container.read(mediaTicketProvider);
        expect(ticket, isNull);
      }, () => mockClient);
    });

    // -----------------------------------------------------------------------
    // Fetches ticket when already logged in at construction
    // -----------------------------------------------------------------------

    test('fetches ticket immediately when already logged in', () async {
      container = buildContainer(
        const AuthState(isLoggedIn: true, token: 'tok-123', userId: 'u1'),
      );

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/media/ticket')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async =>
            http.Response(jsonEncode({'ticket': 'my-ticket-abc'}), 200),
      );

      await http.runWithClient(() async {
        // Reading the provider triggers construction, which calls _fetch().
        container.read(mediaTicketProvider);
        // Give the async fetch a chance to complete.
        await Future<void>.delayed(Duration.zero);
      }, () => mockClient);

      expect(container.read(mediaTicketProvider), 'my-ticket-abc');
    });

    // -----------------------------------------------------------------------
    // Fetches ticket when auth state transitions to logged-in
    // -----------------------------------------------------------------------

    test('fetches ticket when auth state transitions to logged-in', () async {
      container = buildContainer(const AuthState());

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/media/ticket')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async =>
            http.Response(jsonEncode({'ticket': 'login-ticket'}), 200),
      );

      await http.runWithClient(() async {
        // Start reading the provider (starts listener).
        container.read(mediaTicketProvider);

        // Simulate login.
        container.read(authProvider.notifier).state = const AuthState(
          isLoggedIn: true,
          token: 'new-tok',
          userId: 'u1',
        );

        await Future<void>.delayed(Duration.zero);
      }, () => mockClient);

      expect(container.read(mediaTicketProvider), 'login-ticket');
    });

    // -----------------------------------------------------------------------
    // Clears ticket on logout
    // -----------------------------------------------------------------------

    test('clears ticket when auth state transitions to logged-out', () async {
      container = buildContainer(
        const AuthState(isLoggedIn: true, token: 'tok-123', userId: 'u1'),
      );

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/media/ticket')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer(
        (_) async =>
            http.Response(jsonEncode({'ticket': 'will-be-cleared'}), 200),
      );

      await http.runWithClient(() async {
        container.read(mediaTicketProvider);
        await Future<void>.delayed(Duration.zero);

        // Verify ticket was set.
        expect(container.read(mediaTicketProvider), 'will-be-cleared');

        // Simulate logout.
        container.read(authProvider.notifier).state = const AuthState();
        await Future<void>.delayed(Duration.zero);
      }, () => mockClient);

      expect(container.read(mediaTicketProvider), isNull);
    });

    // -----------------------------------------------------------------------
    // Failure handling
    // -----------------------------------------------------------------------

    test('state stays null when server returns non-200', () async {
      container = buildContainer(
        const AuthState(isLoggedIn: true, token: 'tok-123', userId: 'u1'),
      );

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/media/ticket')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('Unauthorized', 401));

      await http.runWithClient(() async {
        container.read(mediaTicketProvider);
        await Future<void>.delayed(Duration.zero);
      }, () => mockClient);

      expect(container.read(mediaTicketProvider), isNull);
    });

    test('state stays null when HTTP call throws', () async {
      container = buildContainer(
        const AuthState(isLoggedIn: true, token: 'tok-123', userId: 'u1'),
      );

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/media/ticket')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenThrow(Exception('network error'));

      await http.runWithClient(() async {
        container.read(mediaTicketProvider);
        await Future<void>.delayed(Duration.zero);
      }, () => mockClient);

      expect(container.read(mediaTicketProvider), isNull);
    });

    test('state stays null when response body has no ticket field', () async {
      container = buildContainer(
        const AuthState(isLoggedIn: true, token: 'tok-123', userId: 'u1'),
      );

      when(
        () => mockClient.post(
          any(that: predicate<Uri>((u) => u.path == '/api/media/ticket')),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      ).thenAnswer((_) async => http.Response('{}', 200));

      await http.runWithClient(() async {
        container.read(mediaTicketProvider);
        await Future<void>.delayed(Duration.zero);
      }, () => mockClient);

      expect(container.read(mediaTicketProvider), isNull);
    });

    // -----------------------------------------------------------------------
    // No fetch when server URL or token is missing
    // -----------------------------------------------------------------------

    test('does not fetch when server URL is empty', () async {
      final c = ProviderContainer(
        overrides: [
          serverUrlProvider.overrideWith((ref) {
            final n = ServerUrlNotifier();
            n.state = '';
            return n;
          }),
          authProvider.overrideWith((ref) {
            final n = AuthNotifier(ref);
            n.state = const AuthState(
              isLoggedIn: true,
              token: 'tok',
              userId: 'u1',
            );
            return n;
          }),
        ],
      );
      addTearDown(c.dispose);

      await http.runWithClient(() async {
        c.read(mediaTicketProvider);
        await Future<void>.delayed(Duration.zero);
      }, () => mockClient);

      // Verify mock was never called.
      verifyNever(
        () => mockClient.post(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
          encoding: any(named: 'encoding'),
        ),
      );

      expect(c.read(mediaTicketProvider), isNull);
    });
  });
}
