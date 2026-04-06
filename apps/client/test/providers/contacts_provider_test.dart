import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/contacts_provider.dart';
import 'package:echo_app/src/models/contact.dart';

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
      final state = ContactsState(
        contacts: [
          const Contact(
            id: 'c1',
            userId: 'u1',
            username: 'alice',
            status: 'accepted',
          ),
        ],
        pendingRequests: [
          const Contact(
            id: 'c2',
            userId: 'u2',
            username: 'bob',
            status: 'pending',
          ),
        ],
        isLoading: true,
      );
      final copied = state.copyWith();
      expect(copied.contacts, hasLength(1));
      expect(copied.pendingRequests, hasLength(1));
      expect(copied.isLoading, isTrue);
    });

    test('copyWith with no error argument clears error (by design)', () {
      final state = ContactsState(error: 'old error');
      // The copyWith uses direct assignment for error (not null-coalesce),
      // so calling copyWith() without error clears it.
      final copied = state.copyWith();
      expect(copied.error, isNull);
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
      final state = ContactsState(
        contacts: [
          const Contact(
            id: 'c1',
            userId: 'u1',
            username: 'alice',
            status: 'accepted',
          ),
        ],
        pendingRequests: [
          const Contact(
            id: 'c2',
            userId: 'u2',
            username: 'bob',
            status: 'pending',
          ),
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
