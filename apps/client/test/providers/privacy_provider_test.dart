import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/privacy_provider.dart';

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
}
