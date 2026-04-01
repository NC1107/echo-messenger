import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/auth_provider.dart';

void main() {
  group('AuthState', () {
    test('initial state is logged out with no token or userId', () {
      const state = AuthState();
      expect(state.isLoggedIn, isFalse);
      expect(state.token, isNull);
      expect(state.userId, isNull);
      expect(state.username, isNull);
      expect(state.error, isNull);
      expect(state.isLoading, isFalse);
    });

    test('copyWith preserves values', () {
      const state = AuthState(isLoggedIn: true, userId: '123', username: 'alice', token: 'tok');
      final copied = state.copyWith(error: 'test');
      expect(copied.isLoggedIn, isTrue);
      expect(copied.userId, '123');
      expect(copied.username, 'alice');
      expect(copied.error, 'test');
    });

    test('default AuthState represents logged out', () {
      const state = AuthState();
      expect(state.isLoggedIn, isFalse);
      expect(state.isLoading, isFalse);
    });
  });
}
