/// Regression: a fresh device joining an encrypted group it has no key for
/// used to re-run the full `SecureKeyStore.readAll()` scan AND re-hit
/// `GET /api/groups/:id/keys/latest` on EVERY undecryptable message / rebuild —
/// a fetch storm + log flood. [GroupCryptoService.getGroupKey] now negative-
/// caches an unavailable key so repeat lookups short-circuit, and a manual
/// key refresh ([dropCachedKey]) lifts the suppression so a real key can land.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GroupCryptoService.getGroupKey — negative cache', () {
    setUp(() {
      SecureKeyStore.instance = FakeSecureKeyStore();
    });

    // A 200 envelope that can't be unwrapped (no CryptoService wired → legacy
    // fallback → fails the 32-byte shape check), so fetchGroupKey returns null.
    MockClient unwrappableEnvelope(void Function() onHit) {
      return MockClient((_) async {
        onHit();
        return http.Response(
          '{"encrypted_key":"c29tZS1lbnZlbG9wZQ==",'
          '"key_version":1,"min_wire_version":1}',
          200,
          headers: {'content-type': 'application/json'},
        );
      });
    }

    test('second lookup is served by the cache, not the server', () async {
      const groupId = 'group-no-key';
      final service = GroupCryptoService(serverUrl: 'http://example.test');
      var hits = 0;

      await http.runWithClient(() async {
        expect(await service.getGroupKey(groupId), isNull);
        expect(await service.getGroupKey(groupId), isNull);
      }, () => unwrappableEnvelope(() => hits++));

      expect(
        hits,
        1,
        reason: 'the repeat lookup must short-circuit on the negative cache',
      );
    });

    test(
      'dropCachedKey lifts the suppression so the next lookup re-fetches',
      () async {
        const groupId = 'group-refresh';
        final service = GroupCryptoService(serverUrl: 'http://example.test');
        var hits = 0;

        await http.runWithClient(() async {
          expect(
            await service.getGroupKey(groupId),
            isNull,
          ); // hit 1, caches "no key"
          expect(await service.getGroupKey(groupId), isNull); // served by cache
          await service.dropCachedKey(groupId); // user taps "Refresh key"
          expect(await service.getGroupKey(groupId), isNull); // hit 2
        }, () => unwrappableEnvelope(() => hits++));

        expect(
          hits,
          2,
          reason: 'a manual refresh must clear the negative cache and re-fetch',
        );
      },
    );
  });
}
