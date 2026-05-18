/// Audit P0-2 acceptance tests for [CryptoService._healUploadKeysWithBackoff].
///
/// Verifies that:
///   1. A persistent upload failure exhausts all 5 attempts.
///   2. The terminal-failure observer fires exactly once when retries are
///      exhausted.
///   3. A success on attempt N stops the retry loop.
///   4. The exponential-backoff delay schedule is honoured (1s, 2s, 4s, 8s).
///
/// The retry helper is `@visibleForTesting`-exposed via
/// [CryptoService.healUploadKeysForTest] which forwards to the private
/// method and accepts an injectable delay function — so the tests can
/// fast-forward through what would otherwise be 30 seconds of real backoff.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/crypto_service.dart';

class _StubCrypto extends CryptoService {
  _StubCrypto({required this.failuresBeforeSuccess})
    : super(serverUrl: 'http://example.invalid');

  int failuresBeforeSuccess;
  int callCount = 0;

  @override
  Future<void> uploadKeys() async {
    callCount++;
    if (failuresBeforeSuccess > 0) {
      failuresBeforeSuccess--;
      throw Exception('simulated upload failure attempt #$callCount');
    }
    // Succeed without doing real network work.
  }
}

void main() {
  group('OTP-heal retry with exponential backoff (audit P0-2)', () {
    test('attempts up to 5 times when uploadKeys keeps failing', () async {
      final crypto = _StubCrypto(failuresBeforeSuccess: 99);
      final delays = <Duration>[];

      final result = await crypto.healUploadKeysForTest(
        delayOverride: (d) async => delays.add(d),
      );

      expect(result, isFalse, reason: 'all 5 attempts failed');
      expect(crypto.callCount, 5, reason: 'exactly 5 attempts');
    });

    test('delay schedule is exponential (1s, 2s, 4s, 8s)', () async {
      final crypto = _StubCrypto(failuresBeforeSuccess: 99);
      final delays = <Duration>[];

      await crypto.healUploadKeysForTest(
        delayOverride: (d) async => delays.add(d),
      );

      // 4 delays between 5 attempts.
      expect(delays.map((d) => d.inSeconds).toList(), [1, 2, 4, 8]);
    });

    test(
      'fires terminal-failure observer exactly once on exhaustion',
      () async {
        var observerFired = 0;
        final crypto = _StubCrypto(failuresBeforeSuccess: 99);
        crypto.setObservers(onKeyUploadTerminalFailure: () => observerFired++);

        await crypto.healUploadKeysForTest(delayOverride: (_) async {});

        expect(observerFired, 1);
      },
    );

    test(
      'does NOT fire terminal-failure observer when retry succeeds',
      () async {
        var observerFired = 0;
        final crypto = _StubCrypto(failuresBeforeSuccess: 2);
        crypto.setObservers(onKeyUploadTerminalFailure: () => observerFired++);

        final result = await crypto.healUploadKeysForTest(
          delayOverride: (_) async {},
        );

        expect(result, isTrue);
        expect(crypto.callCount, 3, reason: '2 fails + 1 success');
        expect(observerFired, 0);
      },
    );

    test('eventual success on attempt 4 stops retry loop', () async {
      final crypto = _StubCrypto(failuresBeforeSuccess: 3);
      final result = await crypto.healUploadKeysForTest(
        delayOverride: (_) async {},
      );
      expect(result, isTrue);
      expect(crypto.callCount, 4);
    });
  });
}
