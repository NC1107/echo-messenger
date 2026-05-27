import 'dart:convert';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';

import '../helpers/mock_http_client.dart';
import '../helpers/mock_providers.dart';

void main() {
  group('PrivacyState', () {
    test('default state has sensible defaults', () {
      const state = PrivacyState();
      expect(state.readReceiptsEnabled, isTrue);
      expect(state.emailVisible, isFalse);
      expect(state.phoneVisible, isFalse);
      expect(state.emailDiscoverable, isFalse);
      expect(state.phoneDiscoverable, isFalse);
      expect(state.searchable, isTrue);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
    });

    test('copyWith preserves unchanged fields', () {
      const state = PrivacyState(
        readReceiptsEnabled: false,
        emailVisible: true,
        phoneVisible: true,
        emailDiscoverable: true,
        phoneDiscoverable: true,
        searchable: false,
      );

      final copied = state.copyWith(isLoading: true);
      expect(copied.readReceiptsEnabled, isFalse);
      expect(copied.emailVisible, isTrue);
      expect(copied.phoneVisible, isTrue);
      expect(copied.emailDiscoverable, isTrue);
      expect(copied.phoneDiscoverable, isTrue);
      expect(copied.searchable, isFalse);
      expect(copied.isLoading, isTrue);
    });

    test('copyWith sets error to null when not specified', () {
      const state = PrivacyState(error: 'some error');
      // error parameter uses null as sentinel (no override), so we cannot
      // clear it via copyWith -- this tests the actual behavior.
      final copied = state.copyWith(isLoading: false);
      // error should be cleared (null) since the copyWith passes null for error
      expect(copied.error, isNull);
    });

    test('copyWith can set error', () {
      const state = PrivacyState();
      final withError = state.copyWith(error: 'Network error');
      expect(withError.error, 'Network error');
    });

    test('copyWith can toggle each boolean', () {
      const state = PrivacyState();

      expect(
        state.copyWith(readReceiptsEnabled: false).readReceiptsEnabled,
        isFalse,
      );
      expect(state.copyWith(emailVisible: true).emailVisible, isTrue);
      expect(state.copyWith(phoneVisible: true).phoneVisible, isTrue);
      expect(state.copyWith(emailDiscoverable: true).emailDiscoverable, isTrue);
      expect(state.copyWith(phoneDiscoverable: true).phoneDiscoverable, isTrue);
      expect(state.copyWith(searchable: false).searchable, isFalse);
    });
  });

  group('Privacy notifier', () {
    setUpAll(registerHttpFallbackValues);

    test('load() when not logged in returns empty defaults', () async {
      final container = ProviderContainer(
        overrides: [
          authOverride(const AuthState(isLoggedIn: false)),
          serverUrlOverride(),
        ],
      );

      await container.read(privacyProvider.notifier).load();
      final state = container.read(privacyProvider);

      expect(state.readReceiptsEnabled, isTrue);
      expect(state.emailVisible, isFalse);
      expect(state.error, isNull);
    });

    test('load() succeeds with 200 response and parses all fields', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': false,
            'email_visible': true,
            'phone_visible': false,
            'email_discoverable': true,
            'phone_discoverable': false,
            'searchable': false,
            'show_online_status': false,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).load(),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.readReceiptsEnabled, isFalse);
      expect(state.emailVisible, isTrue);
      expect(state.phoneVisible, isFalse);
      expect(state.emailDiscoverable, isTrue);
      expect(state.phoneDiscoverable, isFalse);
      expect(state.searchable, isFalse);
      expect(state.showOnlineStatus, isFalse);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
    });

    test('load() defaults missing fields to sensible defaults', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => http.Response(jsonEncode({}), 200));

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).load(),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.readReceiptsEnabled, isTrue);
      expect(state.emailVisible, isFalse);
      expect(state.searchable, isTrue);
      expect(state.showOnlineStatus, isTrue);
    });

    test('load() handles HTTP error (non-200) gracefully', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenAnswer((_) async => http.Response('Unauthorized', 401));

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).load(),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.isLoading, isFalse);
      expect(state.error, 'Failed to load privacy settings');
    });

    test('load() handles network exceptions', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.get(any(), headers: any(named: 'headers')),
      ).thenThrow(Exception('Network timeout'));

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).load(),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.isLoading, isFalse);
      // Friendly message replaces the raw exception text (2026-05-27 fix —
      // see privacy_provider.dart). The raw error still goes to debugPrint
      // for support / debug logs.
      expect(state.error, contains("Couldn't load privacy settings"));
    });

    test('setReadReceiptsEnabled() updates state and sends PATCH', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': false,
            'email_visible': false,
            'phone_visible': false,
            'email_discoverable': false,
            'phone_discoverable': false,
            'searchable': true,
            'show_online_status': true,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container
            .read(privacyProvider.notifier)
            .setReadReceiptsEnabled(false),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.readReceiptsEnabled, isFalse);
      expect(state.error, isNull);

      verify(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).called(1);
    });

    test('setEmailVisible() updates state and sends PATCH', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': true,
            'email_visible': true,
            'phone_visible': false,
            'email_discoverable': false,
            'phone_discoverable': false,
            'searchable': true,
            'show_online_status': true,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).setEmailVisible(true),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.emailVisible, isTrue);
    });

    test('setPhoneVisible() updates state and sends PATCH', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': true,
            'email_visible': false,
            'phone_visible': true,
            'email_discoverable': false,
            'phone_discoverable': false,
            'searchable': true,
            'show_online_status': true,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).setPhoneVisible(true),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.phoneVisible, isTrue);
    });

    test('setEmailDiscoverable() updates state and sends PATCH', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': true,
            'email_visible': false,
            'phone_visible': false,
            'email_discoverable': true,
            'phone_discoverable': false,
            'searchable': true,
            'show_online_status': true,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () =>
            container.read(privacyProvider.notifier).setEmailDiscoverable(true),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.emailDiscoverable, isTrue);
    });

    test('setPhoneDiscoverable() updates state and sends PATCH', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': true,
            'email_visible': false,
            'phone_visible': false,
            'email_discoverable': false,
            'phone_discoverable': true,
            'searchable': true,
            'show_online_status': true,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () =>
            container.read(privacyProvider.notifier).setPhoneDiscoverable(true),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.phoneDiscoverable, isTrue);
    });

    test('setSearchable() updates state and sends PATCH', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': true,
            'email_visible': false,
            'phone_visible': false,
            'email_discoverable': false,
            'phone_discoverable': false,
            'searchable': false,
            'show_online_status': true,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).setSearchable(false),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.searchable, isFalse);
    });

    test('setShowOnlineStatus() updates state and sends PATCH', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer(
        (_) async => http.Response(
          jsonEncode({
            'read_receipts_enabled': true,
            'email_visible': false,
            'phone_visible': false,
            'email_discoverable': false,
            'phone_discoverable': false,
            'searchable': true,
            'show_online_status': false,
          }),
          200,
        ),
      );

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () =>
            container.read(privacyProvider.notifier).setShowOnlineStatus(false),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.showOnlineStatus, isFalse);
    });

    test('update with HTTP error reverts to previous state', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async => http.Response('Forbidden', 403));

      final container = ProviderContainer(
        overrides: [
          authOverride(loggedInAuthState),
          serverUrlOverride(),
          privacyProvider.overrideWith(
            () => _FakePrivacyNotifier(const PrivacyState(emailVisible: false)),
          ),
        ],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).setEmailVisible(true),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.emailVisible, isFalse);
      expect(state.error, 'Failed to save privacy settings');
    });

    test('update with network exception reverts to previous state', () async {
      final mockClient = MockHttpClient();
      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenThrow(Exception('Connection lost'));

      final container = ProviderContainer(
        overrides: [
          authOverride(loggedInAuthState),
          serverUrlOverride(),
          privacyProvider.overrideWith(
            () => _FakePrivacyNotifier(const PrivacyState(phoneVisible: false)),
          ),
        ],
      );

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).setPhoneVisible(true),
        () => mockClient,
      );

      final state = container.read(privacyProvider);
      expect(state.phoneVisible, isFalse);
      expect(state.error, contains('Connection lost'));
    });

    test('multiple sequential updates work correctly', () async {
      final mockClient = MockHttpClient();
      var callCount = 0;

      when(
        () => mockClient.patch(
          any(),
          headers: any(named: 'headers'),
          body: any(named: 'body'),
        ),
      ).thenAnswer((_) async {
        callCount++;
        return http.Response(
          jsonEncode({
            'read_receipts_enabled': callCount != 1,
            'email_visible': callCount == 2,
            'phone_visible': false,
            'email_discoverable': false,
            'phone_discoverable': false,
            'searchable': true,
            'show_online_status': true,
          }),
          200,
        );
      });

      final container = ProviderContainer(
        overrides: [authOverride(loggedInAuthState), serverUrlOverride()],
      );

      await http.runWithClient(
        () => container
            .read(privacyProvider.notifier)
            .setReadReceiptsEnabled(false),
        () => mockClient,
      );

      var state = container.read(privacyProvider);
      expect(state.readReceiptsEnabled, isFalse);

      await http.runWithClient(
        () => container.read(privacyProvider.notifier).setEmailVisible(true),
        () => mockClient,
      );

      state = container.read(privacyProvider);
      expect(state.emailVisible, isTrue);
    });
  });
}

class _FakePrivacyNotifier extends Privacy {
  _FakePrivacyNotifier(this._initial);

  final PrivacyState _initial;

  @override
  PrivacyState build() => _initial;
}
