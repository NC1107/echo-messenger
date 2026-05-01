import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/widgets/chat/session_corrupted_banner.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

/// Fake notifier that controls whether [peerUserId] reports a corrupted
/// session and tracks how many times [forceResetSession] is called.
class _FakeCrypto extends FakeCryptoNotifier {
  // ignore: use_super_parameters
  _FakeCrypto(Ref ref, {required bool corrupted})
    : _corrupted = corrupted,
      super(ref, initial: const CryptoState(isInitialized: true));

  bool _corrupted;
  int resetCalls = 0;

  @override
  bool hasCorruptedSession(String peerUserId) => _corrupted;

  @override
  Future<void> forceResetSession(String peerUserId) async {
    resetCalls++;
    _corrupted = false;
  }
}

void main() {
  group('SessionCorruptedBanner (#176)', () {
    testWidgets('hidden when no corrupted session', (tester) async {
      await tester.pumpApp(
        const SessionCorruptedBanner(
          conversationId: 'conv-1',
          peerUserId: 'peer-1',
          peerName: 'alice',
        ),
        overrides: [
          authOverride(
            const AuthState(userId: 'me', username: 'me', token: 't'),
          ),
          cryptoProvider.overrideWith(
            (ref) => _FakeCrypto(ref, corrupted: false),
          ),
          webSocketOverride(),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.textContaining('needs a reset'), findsNothing);
      expect(find.text('Reset'), findsNothing);
    });

    testWidgets(
      'shows banner text and reset button when session is quarantined',
      (tester) async {
        await tester.pumpApp(
          const SessionCorruptedBanner(
            conversationId: 'conv-1',
            peerUserId: 'peer-1',
            peerName: 'alice',
          ),
          overrides: [
            authOverride(
              const AuthState(userId: 'me', username: 'me', token: 't'),
            ),
            cryptoProvider.overrideWith(
              (ref) => _FakeCrypto(ref, corrupted: true),
            ),
            webSocketOverride(),
          ],
        );
        await tester.pumpAndSettle();

        expect(
          find.textContaining('Encryption with @alice needs a reset'),
          findsOneWidget,
        );
        expect(find.text('Reset'), findsOneWidget);
      },
    );

    testWidgets('tapping reset calls forceResetSession and hides banner', (
      tester,
    ) async {
      late _FakeCrypto fakeCrypto;

      await tester.pumpApp(
        const SessionCorruptedBanner(
          conversationId: 'conv-1',
          peerUserId: 'peer-1',
          peerName: 'alice',
        ),
        overrides: [
          authOverride(
            const AuthState(userId: 'me', username: 'me', token: 't'),
          ),
          cryptoProvider.overrideWith((ref) {
            fakeCrypto = _FakeCrypto(ref, corrupted: true);
            return fakeCrypto;
          }),
          webSocketOverride(),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('Reset'), findsOneWidget);

      await tester.tap(find.text('Reset'));
      // Pump past the async reset and let the ToastService timers expire.
      await tester.pump();
      await tester.pump(const Duration(seconds: 4));

      expect(fakeCrypto.resetCalls, 1);
      // Banner hides itself optimistically after reset.
      expect(find.text('Reset'), findsNothing);
      expect(find.textContaining('needs a reset'), findsNothing);
    });
  });
}
