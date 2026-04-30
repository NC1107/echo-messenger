/// #656 — group key rotation behaviour on the client side.
///
/// Verifies that `GroupCryptoService.performRotation`:
///
/// - drops cached + persisted material for the conversation BEFORE attempting
///   a re-upload, so we never encrypt with a now-revoked key,
/// - returns null cleanly when no [CryptoService] is wired (the default for
///   the bare service constructor used here).
///
/// We do not exercise the full HTTP path here — that requires the Signal
/// identity machinery which is covered separately. The integration tests
/// `group_key_rotation_on_kick.rs` cover the server-side bump + envelope
/// purge. This test pins the client cache contract.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GroupCryptoService.performRotation', () {
    late FakeSecureKeyStore fakeStore;

    setUp(() {
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
    });

    test(
      'evicts cached and persisted key for the conversation before rotating',
      () async {
        const groupId = 'group-rotate-1';
        final service = GroupCryptoService(serverUrl: 'http://localhost:0');

        // Seed an "old" key as if v1 had already been distributed.
        final v1Key = GroupCryptoService.generateGroupKey();
        await fakeStore.write('group_key_${groupId}_1', v1Key);
        // Sanity: getGroupKey resolves the seeded version.
        final pre = await service.getGroupKey(groupId);
        expect(pre, isNotNull);
        expect(pre!.$1, 1);

        // No CryptoService wired -> performRotation returns null but must
        // still purge the stale material so we cannot accidentally reuse it.
        final result = await service.performRotation(
          groupId,
          2,
          fetchMembers: () async => [
            {'user_id': 'alice'},
            {'user_id': 'bob'},
          ],
          fetchIdentityKey: (_) async => null,
        );
        expect(result, isNull);

        // Persisted key for v1 must be gone.
        final remaining = fakeStore.dump.keys
            .where((k) => k.startsWith('group_key_$groupId'))
            .toList();
        expect(
          remaining,
          isEmpty,
          reason: 'old envelope key must be purged before rotation',
        );

        // And the in-memory cache must miss too.
        // Rebuild a fresh service with the same backing store; if we used
        // the same instance the in-memory map is wiped, so probe with a new
        // GroupCryptoService that sees the (now empty) store.
        final probe = GroupCryptoService(serverUrl: 'http://localhost:0');
        final post = await probe.getGroupKey(groupId);
        // No HTTP server backing this test -> fetchGroupKey will fail; the
        // important assertion is that we did NOT find the stale v1 entry.
        expect(post, isNull);
      },
    );

    test(
      'returns null when no envelopes can be built (no identity keys)',
      () async {
        const groupId = 'group-rotate-2';
        final service = GroupCryptoService(serverUrl: 'http://localhost:0');

        final result = await service.performRotation(
          groupId,
          1,
          fetchMembers: () async => [
            {'user_id': 'alice'},
          ],
          // Identity-key resolver always fails -> no envelope can be built.
          fetchIdentityKey: (_) async => null,
        );
        expect(result, isNull);
      },
    );
  });
}
