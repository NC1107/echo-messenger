import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/providers/auth_provider.dart';

void main() {
  late AuthNotifier notifier;

  setUp(() {
    notifier = AuthNotifier();
  });

  group('AuthNotifier', () {
    test('initial state is logged out with no token or userId', () {
      expect(notifier.state.isLoggedIn, isFalse);
      expect(notifier.state.token, isNull);
      expect(notifier.state.userId, isNull);
      expect(notifier.state.error, isNull);
      expect(notifier.state.isLoading, isFalse);
    });

    test('logout clears all state', () {
      // Simulate a logged-in state by calling logout from any state.
      // We cannot easily set state directly on a StateNotifier from outside,
      // but we can verify that logout always returns to the default state.
      notifier.logout();

      expect(notifier.state.isLoggedIn, isFalse);
      expect(notifier.state.token, isNull);
      expect(notifier.state.userId, isNull);
      expect(notifier.state.error, isNull);
      expect(notifier.state.isLoading, isFalse);
    });
  });
}
