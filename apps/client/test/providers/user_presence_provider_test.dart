/// Verify that [userPresenceProvider] surfaces the local user's status from
/// authProvider as soon as auth lands, even before the server echoes a
/// presence_update back. Without this override the user sees a missing
/// status dot on their own avatar in the members panel.
library;

import 'package:echo_app/src/providers/auth/auth_provider.dart';
import 'package:echo_app/src/providers/user_presence_provider.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('userPresenceProvider returns online for the local user even when WS '
      'has not echoed a presence_update yet', () {
    final container = ProviderContainer();
    addTearDown(container.dispose);

    const myUserId = 'me';
    container.read(authProvider.notifier).state = const AuthState(
      userId: myUserId,
      presenceStatus: 'dnd',
    );

    final presence = container.read(userPresenceProvider(myUserId));
    expect(presence.isOnline, isTrue);
    expect(presence.status, 'dnd');
  });

  test(
    'userPresenceProvider still routes other userIds through the WS state',
    () {
      final container = ProviderContainer();
      addTearDown(container.dispose);

      container.read(authProvider.notifier).state = const AuthState(
        userId: 'me',
        presenceStatus: 'online',
      );

      final presence = container.read(userPresenceProvider('someone-else'));
      expect(presence.isOnline, isFalse);
      expect(presence.status, 'offline');
    },
  );
}
