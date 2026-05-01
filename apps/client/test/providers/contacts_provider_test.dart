import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:mocktail/mocktail.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/models/contact.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/contacts_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';

import '../helpers/mock_http_client.dart';

void main() {
  group('ContactsState', () {
    test('initial state has empty contacts and pending lists', () {
      const state = ContactsState();
      expect(state.contacts, isEmpty);
      expect(state.pendingRequests, isEmpty);
      expect(state.isLoading, isFalse);
      expect(state.error, isNull);
    });

    test('copyWith preserves contacts, pending, and isLoading', () {
      final state = const ContactsState(
        contacts: [
          Contact(
            id: 'c1',
            userId: 'u1',
            username: 'alice',
            status: 'accepted',
          ),
        ],
        pendingRequests: [
          Contact(id: 'c2', userId: 'u2', username: 'bob', status: 'pending'),
        ],
        isLoading: true,
      );
      final copied = state.copyWith();
      expect(copied.contacts, hasLength(1));
      expect(copied.pendingRequests, hasLength(1));
      expect(copied.isLoading, isTrue);
    });

    test('copyWith with no error argument preserves existing error', () {
      final state = const ContactsState(error: 'old error');
      // Omitting the error parameter preserves the current value.
      final copied = state.copyWith();
      expect(copied.error, 'old error');
    });

    test('copyWith with explicit null clears error', () {
      final state = const ContactsState(error: 'old error');
      final cleared = state.copyWith(error: null);
      expect(cleared.error, isNull);
    });

    test('copyWith updates contacts list', () {
      const state = ContactsState();
      final contacts = [
        const Contact(
          id: 'c1',
          userId: 'u1',
          username: 'alice',
          status: 'accepted',
        ),
        const Contact(
          id: 'c2',
          userId: 'u2',
          username: 'bob',
          status: 'accepted',
        ),
      ];
      final updated = state.copyWith(contacts: contacts);
      expect(updated.contacts, hasLength(2));
      expect(updated.contacts[0].username, 'alice');
      expect(updated.contacts[1].username, 'bob');
    });

    test('copyWith updates pending requests', () {
      const state = ContactsState();
      final pending = [
        const Contact(
          id: 'c1',
          userId: 'u1',
          username: 'carol',
          status: 'pending',
        ),
      ];
      final updated = state.copyWith(pendingRequests: pending);
      expect(updated.pendingRequests, hasLength(1));
      expect(updated.pendingRequests.first.username, 'carol');
    });

    test('contact status tracking -- accepted, pending, blocked', () {
      final contacts = [
        const Contact(
          id: 'c1',
          userId: 'u1',
          username: 'alice',
          status: 'accepted',
        ),
        const Contact(
          id: 'c2',
          userId: 'u2',
          username: 'bob',
          status: 'pending',
        ),
        const Contact(
          id: 'c3',
          userId: 'u3',
          username: 'carol',
          status: 'blocked',
        ),
      ];

      final accepted = contacts.where((c) => c.status == 'accepted').toList();
      expect(accepted, hasLength(1));
      expect(accepted.first.username, 'alice');

      final pending = contacts.where((c) => c.status == 'pending').toList();
      expect(pending, hasLength(1));
      expect(pending.first.username, 'bob');

      final blocked = contacts.where((c) => c.status == 'blocked').toList();
      expect(blocked, hasLength(1));
      expect(blocked.first.username, 'carol');
    });

    test('copyWith sets and clears error', () {
      const state = ContactsState();
      final withError = state.copyWith(error: 'Failed to load contacts');
      expect(withError.error, 'Failed to load contacts');

      final cleared = withError.copyWith(error: null);
      expect(cleared.error, isNull);
    });

    test('copyWith sets loading state', () {
      const state = ContactsState();
      final loading = state.copyWith(isLoading: true);
      expect(loading.isLoading, isTrue);
      final done = loading.copyWith(isLoading: false);
      expect(done.isLoading, isFalse);
    });

    test('contacts and pending lists are independent', () {
      final state = const ContactsState(
        contacts: [
          Contact(
            id: 'c1',
            userId: 'u1',
            username: 'alice',
            status: 'accepted',
          ),
        ],
        pendingRequests: [
          Contact(id: 'c2', userId: 'u2', username: 'bob', status: 'pending'),
        ],
      );

      // Updating contacts does not affect pending
      final updatedContacts = state.copyWith(contacts: []);
      expect(updatedContacts.contacts, isEmpty);
      expect(updatedContacts.pendingRequests, hasLength(1));

      // Updating pending does not affect contacts
      final updatedPending = state.copyWith(pendingRequests: []);
      expect(updatedPending.contacts, hasLength(1));
      expect(updatedPending.pendingRequests, isEmpty);
    });
  });

  // -----------------------------------------------------------------
  // #599: monotonic-generation guard for loadContacts.
  // Two concurrent reloads must not let the older response overwrite
  // the newer one's state.
  // -----------------------------------------------------------------
  group('ContactsNotifier.loadContacts stale-guard (#599)', () {
    late MockHttpClient mockClient;
    late ProviderContainer container;

    setUpAll(registerHttpFallbackValues);

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

    Map<String, dynamic> contactFixture(String id, String username) => {
      'id': id,
      'user_id': 'uid-$id',
      'username': username,
      'status': 'accepted',
    };

    test('late stale success does not overwrite fresh success', () async {
      final completers = <Completer<http.Response>>[
        Completer<http.Response>(),
        Completer<http.Response>(),
      ];
      var callIndex = 0;
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/contacts')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) => completers[callIndex++].future);

      final notifier = container.read(contactsProvider.notifier);
      await http.runWithClient(() async {
        // Fire two reloads without awaiting -- second is the "fresh" one.
        final a = notifier.loadContacts();
        final b = notifier.loadContacts();

        // Resolve B (fresh) first with [alice], then A (stale) with [bob].
        completers[1].complete(
          http.Response(jsonEncode([contactFixture('1', 'alice')]), 200),
        );
        await b;

        completers[0].complete(
          http.Response(jsonEncode([contactFixture('2', 'bob')]), 200),
        );
        await a;

        // Latest call (B / alice) must win even though A finished after.
        expect(notifier.state.contacts, hasLength(1));
        expect(notifier.state.contacts.first.username, 'alice');
        expect(notifier.state.isLoading, isFalse);
      }, () => mockClient);
    });

    test('late stale error does not clobber fresh success', () async {
      final completers = <Completer<http.Response>>[
        Completer<http.Response>(),
        Completer<http.Response>(),
      ];
      var callIndex = 0;
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/contacts')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) => completers[callIndex++].future);

      final notifier = container.read(contactsProvider.notifier);
      await http.runWithClient(() async {
        final a = notifier.loadContacts(); // stale -- will throw
        final b = notifier.loadContacts(); // fresh -- succeeds

        completers[1].complete(
          http.Response(jsonEncode([contactFixture('1', 'alice')]), 200),
        );
        await b;

        completers[0].completeError(const SocketException('boom'));
        await a;

        // Stale error must NOT overwrite fresh success.
        expect(notifier.state.contacts, hasLength(1));
        expect(notifier.state.contacts.first.username, 'alice');
        expect(notifier.state.error, isNull);
        expect(notifier.state.isLoading, isFalse);
      }, () => mockClient);
    });

    test('isLoading stays true until the latest call completes', () async {
      final completers = <Completer<http.Response>>[
        Completer<http.Response>(),
        Completer<http.Response>(),
      ];
      var callIndex = 0;
      when(
        () => mockClient.get(
          any(that: predicate<Uri>((u) => u.path == '/api/contacts')),
          headers: any(named: 'headers'),
        ),
      ).thenAnswer((_) => completers[callIndex++].future);

      final notifier = container.read(contactsProvider.notifier);
      await http.runWithClient(() async {
        final a = notifier.loadContacts();
        final b = notifier.loadContacts();

        expect(notifier.state.isLoading, isTrue);

        // Resolve the stale call first; loading must stay true.
        completers[0].complete(
          http.Response(jsonEncode([contactFixture('1', 'bob')]), 200),
        );
        await a;
        expect(
          notifier.state.isLoading,
          isTrue,
          reason: 'stale return must not flip isLoading=false',
        );

        // Resolve the fresh call -- THIS one clears loading.
        completers[1].complete(
          http.Response(jsonEncode([contactFixture('2', 'alice')]), 200),
        );
        await b;
        expect(notifier.state.isLoading, isFalse);
        expect(notifier.state.contacts.first.username, 'alice');
      }, () => mockClient);
    });
  });

  group('Contact model', () {
    test('fromJson parses correctly', () {
      final json = {
        'id': 'contact-1',
        'user_id': 'user-1',
        'username': 'alice',
        'display_name': 'Alice Wonderland',
        'avatar_url': 'https://example.com/avatar.png',
        'status': 'accepted',
      };
      final contact = Contact.fromJson(json);
      expect(contact.id, 'contact-1');
      expect(contact.userId, 'user-1');
      expect(contact.username, 'alice');
      expect(contact.displayName, 'Alice Wonderland');
      expect(contact.avatarUrl, 'https://example.com/avatar.png');
      expect(contact.status, 'accepted');
    });

    test('fromJson with null optional fields', () {
      final json = {
        'id': 'contact-2',
        'user_id': 'user-2',
        'username': 'bob',
        'status': 'pending',
      };
      final contact = Contact.fromJson(json);
      expect(contact.displayName, isNull);
      expect(contact.avatarUrl, isNull);
      expect(contact.status, 'pending');
    });
  });
}
