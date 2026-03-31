import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/models/contact.dart';

void main() {
  group('Contact.fromJson', () {
    test('accepted contact parsed correctly', () {
      final json = {
        'id': 'contact-1',
        'user_id': 'user-abc',
        'username': 'alice',
        'display_name': 'Alice W',
        'status': 'accepted',
      };

      final contact = Contact.fromJson(json);

      expect(contact.status, 'accepted');
      expect(contact.id, 'contact-1');
      expect(contact.userId, 'user-abc');
      expect(contact.username, 'alice');
    });

    test('pending contact parsed correctly', () {
      final json = {
        'id': 'contact-2',
        'user_id': 'user-xyz',
        'username': 'bob',
        'display_name': null,
        'status': 'pending',
      };

      final contact = Contact.fromJson(json);

      expect(contact.status, 'pending');
    });

    test('with display name', () {
      final json = {
        'id': 'contact-3',
        'user_id': 'user-123',
        'username': 'carol',
        'display_name': 'Carol D',
        'status': 'accepted',
      };

      final contact = Contact.fromJson(json);

      expect(contact.displayName, 'Carol D');
    });

    test('without display name', () {
      final json = {
        'id': 'contact-4',
        'user_id': 'user-456',
        'username': 'dave',
        'display_name': null,
        'status': 'accepted',
      };

      final contact = Contact.fromJson(json);

      expect(contact.displayName, isNull);
    });
  });
}
