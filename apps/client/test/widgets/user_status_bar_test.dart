import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/widgets/user_status_bar.dart';

void main() {
  group('presenceStatusLabel', () {
    test('maps known statuses to human-readable labels', () {
      expect(presenceStatusLabel('online'), 'Online');
      expect(presenceStatusLabel('away'), 'Away');
      expect(presenceStatusLabel('dnd'), 'Do Not Disturb');
      expect(presenceStatusLabel('invisible'), 'Invisible');
    });

    test('falls back to Online for unknown values', () {
      expect(presenceStatusLabel(''), 'Online');
      expect(presenceStatusLabel('bogus'), 'Online');
    });
  });
}
