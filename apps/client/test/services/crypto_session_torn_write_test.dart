/// Audit P1-3 acceptance: verify the torn-write intent marker round-trips
/// through [SecureKeyStore] and `scanAndClearTornSessionWrites` reports
/// any markers left behind by a crashed `_decryptNormalMessage`.
///
/// We don't (and can't) directly test "process killed mid-decrypt" in a
/// unit test — that's exactly why the instrumentation exists in the
/// first place. What we *can* prove is the round-trip contract: writing
/// intent markers makes them visible to the scan, and successful clears
/// remove them. Real telemetry comes from production once this lands.
library;

import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  late FakeSecureKeyStore store;
  late CryptoService crypto;

  setUp(() {
    store = FakeSecureKeyStore();
    SecureKeyStore.instance = store;
    crypto = CryptoService(serverUrl: 'http://example.invalid');
  });

  group('Torn-write instrumentation (audit P1-3)', () {
    test('returns empty list when no intent markers are present', () async {
      final torn = await crypto.scanAndClearTornSessionWrites();
      expect(torn, isEmpty);
    });

    test('finds markers left behind by an interrupted decrypt and reports '
        'the bare session keys', () async {
      // Simulate the post-crash state: pre-save wrote an intent marker,
      // post-save never ran. The FakeSecureKeyStore is a Map<String,String>
      // so we can poke entries in directly to mimic on-disk state.
      await store.write('echo_session_writeahead_peer-A', '2026-05-18T12:00');
      await store.write(
        'echo_session_writeahead_peer-B:42',
        '2026-05-18T12:00',
      );

      final torn = await crypto.scanAndClearTornSessionWrites();

      expect(torn, containsAll(['peer-A', 'peer-B:42']));
      expect(torn.length, 2);
    });

    test('clears markers as a side effect so re-scans return empty', () async {
      await store.write('echo_session_writeahead_peer-A', 'mark');

      final firstScan = await crypto.scanAndClearTornSessionWrites();
      expect(firstScan, ['peer-A']);

      final secondScan = await crypto.scanAndClearTornSessionWrites();
      expect(
        secondScan,
        isEmpty,
        reason: 'markers should be cleared after the first scan',
      );
    });

    test('intent-prefix is orthogonal to _sessionPrefix so _loadSessions '
        'cannot mis-parse a writeahead marker as a session', () async {
      // The session prefix is `echo_signal_session_`. The intent prefix
      // is `echo_session_writeahead_`. They share `echo_` but not the
      // common suffix that `_loadSessions` iterates by.
      await store.write('echo_session_writeahead_peer-A', '2026-05-18T12:00');

      // If the prefixes overlapped, _loadSessions would try jsonDecode
      // on the timestamp string and quarantine the marker as a
      // "corrupted session". The scan should still pick it up here.
      final torn = await crypto.scanAndClearTornSessionWrites();
      expect(torn, ['peer-A']);
    });

    test(
      'survives a session entry without an intent marker (mixed state)',
      () async {
        // A legitimate session entry should never be mistaken for an intent.
        await store.write(
          'echo_signal_session_peer-A',
          '{"some": "session-json"}',
        );
        await store.write('echo_session_writeahead_peer-B', 'mark');

        final torn = await crypto.scanAndClearTornSessionWrites();
        expect(torn, ['peer-B']);
        // The session entry stays untouched.
        expect(await store.read('echo_signal_session_peer-A'), isNotNull);
      },
    );
  });
}
