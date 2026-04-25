import 'package:cryptography/cryptography.dart';
import 'package:echo_app/src/services/session_cache.dart';
import 'package:echo_app/src/services/signal_session.dart';
import 'package:echo_app/src/services/signal_x3dh.dart';
import 'package:flutter_test/flutter_test.dart';

/// Build a real, encrypt-capable Alice [SignalSession] via X3DH so we have
/// a session whose internal key material is non-zero (initBob leaves
/// sendChainKey as zeros, which would defeat the zeroing assertions).
Future<SignalSession> makeSession() async {
  final x25519 = X25519();
  final aliceIdentity = await x25519.newKeyPair();
  final bobIdentity = await x25519.newKeyPair();
  final bobSignedPrekey = await x25519.newKeyPair();

  final bobIdentityPub = await bobIdentity.extractPublicKey();
  final bobSignedPrekeyPub = await bobSignedPrekey.extractPublicKey();

  final initResult = await X3DH.initiate(
    aliceIdentity: aliceIdentity,
    bobIdentityKey: bobIdentityPub,
    bobSignedPrekey: bobSignedPrekeyPub,
  );

  return SignalSession.initAlice(initResult.sharedSecret, bobSignedPrekeyPub);
}

void main() {
  late DateTime now;
  DateTime nowFn() => now;

  group('SessionCache', () {
    setUp(() {
      now = DateTime(2026, 1, 1, 12, 0);
    });

    test('put then get returns the same session', () async {
      final cache = SessionCache(clock: nowFn, enablePeriodicEviction: false);
      final s = await makeSession();
      cache.put('peer-1', s);
      expect(identical(cache.get('peer-1'), s), isTrue);
      expect(cache.length, 1);
      cache.dispose();
    });

    test('get returns null on miss', () {
      final cache = SessionCache(clock: nowFn, enablePeriodicEviction: false);
      expect(cache.get('nobody'), isNull);
      cache.dispose();
    });

    test('expired entries are evicted on get', () async {
      final cache = SessionCache(
        clock: nowFn,
        ttl: const Duration(hours: 1),
        enablePeriodicEviction: false,
      );
      cache.put('peer-1', await makeSession());
      now = now.add(const Duration(hours: 2));
      expect(cache.get('peer-1'), isNull);
      expect(cache.length, 0);
      cache.dispose();
    });

    test('LRU eviction at maxEntries', () async {
      final cache = SessionCache(
        clock: nowFn,
        maxEntries: 3,
        enablePeriodicEviction: false,
      );
      cache.put('a', await makeSession());
      cache.put('b', await makeSession());
      cache.put('c', await makeSession());
      cache.put('d', await makeSession()); // evicts 'a'
      expect(cache.containsKey('a'), isFalse);
      expect(cache.containsKey('b'), isTrue);
      expect(cache.containsKey('c'), isTrue);
      expect(cache.containsKey('d'), isTrue);
      expect(cache.length, 3);
      cache.dispose();
    });

    test('LRU promotion: get refreshes ordering', () async {
      final cache = SessionCache(
        clock: nowFn,
        maxEntries: 3,
        enablePeriodicEviction: false,
      );
      cache.put('a', await makeSession());
      cache.put('b', await makeSession());
      cache.put('c', await makeSession());
      cache.get('a'); // 'a' is most recent now
      cache.put('d', await makeSession()); // should evict 'b'
      expect(cache.containsKey('a'), isTrue);
      expect(cache.containsKey('b'), isFalse);
      expect(cache.containsKey('c'), isTrue);
      expect(cache.containsKey('d'), isTrue);
      cache.dispose();
    });

    test('eviction zeroes key material', () async {
      final cache = SessionCache(clock: nowFn, enablePeriodicEviction: false);
      final s = await makeSession();
      final rootKeyRef = s.rootKey;
      final sendChainRef = s.sendChainKey;
      expect(
        rootKeyRef.any((b) => b != 0),
        isTrue,
        reason: 'pre: rootKey should be non-zero',
      );
      expect(
        sendChainRef.any((b) => b != 0),
        isTrue,
        reason: 'pre: sendChainKey should be non-zero',
      );

      cache.put('peer-1', s);
      cache.remove('peer-1');

      expect(
        rootKeyRef.every((b) => b == 0),
        isTrue,
        reason: 'post: rootKey should be zeroed',
      );
      expect(
        sendChainRef.every((b) => b == 0),
        isTrue,
        reason: 'post: sendChainKey should be zeroed',
      );
      cache.dispose();
    });

    test('replace via put zeroes the previous session', () async {
      final cache = SessionCache(clock: nowFn, enablePeriodicEviction: false);
      final s1 = await makeSession();
      final s2 = await makeSession();
      final ref = s1.rootKey;
      cache.put('peer-1', s1);
      cache.put('peer-1', s2);
      expect(
        ref.every((b) => b == 0),
        isTrue,
        reason: 'replaced session must be zeroed',
      );
      expect(identical(cache.get('peer-1'), s2), isTrue);
      cache.dispose();
    });

    test('evictExpired drops only expired', () async {
      final cache = SessionCache(
        clock: nowFn,
        ttl: const Duration(hours: 1),
        enablePeriodicEviction: false,
      );
      cache.put('a', await makeSession());
      now = now.add(const Duration(minutes: 30));
      cache.put('b', await makeSession());
      // Advance so 'a' is 1.5h old (expired) and 'b' is 1h old (boundary,
      // also expired given >= ttl semantics).
      now = now.add(const Duration(hours: 1));
      cache.evictExpired();
      expect(cache.containsKey('a'), isFalse);
      // 'b' is exactly at the TTL boundary; with >= ttl semantics it is
      // also evicted.  This is the intended conservative behaviour.
      expect(cache.containsKey('b'), isFalse);
      cache.dispose();
    });

    test('evictExpired keeps fresh entries', () async {
      final cache = SessionCache(
        clock: nowFn,
        ttl: const Duration(hours: 1),
        enablePeriodicEviction: false,
      );
      cache.put('a', await makeSession());
      now = now.add(const Duration(minutes: 30));
      cache.evictExpired();
      expect(cache.containsKey('a'), isTrue);
      cache.dispose();
    });

    test('clear zeroes and removes all', () async {
      final cache = SessionCache(clock: nowFn, enablePeriodicEviction: false);
      final s = await makeSession();
      final ref = s.rootKey;
      cache.put('peer-1', s);
      cache.clear();
      expect(cache.length, 0);
      expect(ref.every((b) => b == 0), isTrue);
      cache.dispose();
    });

    test('forEach visits every entry', () async {
      final cache = SessionCache(clock: nowFn, enablePeriodicEviction: false);
      cache.put('a', await makeSession());
      cache.put('b', await makeSession());
      final keys = <String>[];
      cache.forEach((k, _) => keys.add(k));
      expect(keys, containsAll(<String>['a', 'b']));
      cache.dispose();
    });

    test('remove returns false on missing key', () {
      final cache = SessionCache(clock: nowFn, enablePeriodicEviction: false);
      expect(cache.remove('nobody'), isFalse);
      cache.dispose();
    });

    test('dispose cancels timer and clears entries', () async {
      final cache = SessionCache(
        clock: nowFn,
        sweepInterval: const Duration(milliseconds: 50),
      );
      final s = await makeSession();
      final ref = s.rootKey;
      cache.put('peer-1', s);
      cache.dispose();
      expect(cache.length, 0);
      expect(ref.every((b) => b == 0), isTrue);
      // Calling dispose again is safe.
      cache.dispose();
    });
  });
}
