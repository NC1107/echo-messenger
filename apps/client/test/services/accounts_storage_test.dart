import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/services/accounts_storage.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('StoredAccount', () {
    test('id is userId@serverUrl', () {
      final account = StoredAccount(
        userId: 'u1',
        username: 'alice',
        serverUrl: 'https://server.example',
        refreshToken: 'r',
        lastUsed: DateTime(2026, 5, 28),
      );
      expect(account.id, 'u1@https://server.example');
    });

    test('toJson/fromJson roundtrip preserves fields', () {
      final source = StoredAccount(
        userId: 'u1',
        username: 'alice',
        avatarUrl: '/avatars/u1.png',
        serverUrl: 'https://server.example',
        refreshToken: 'rt-abc',
        lastUsed: DateTime.utc(2026, 5, 28, 10, 30),
      );
      final roundTrip = StoredAccount.fromJson(source.toJson());
      expect(roundTrip, isNotNull);
      expect(roundTrip, equals(source));
    });

    test('fromJson returns null when required fields missing', () {
      expect(StoredAccount.fromJson(<String, dynamic>{}), isNull);
      expect(
        StoredAccount.fromJson(<String, dynamic>{
          'user_id': 'u1',
          'username': 'alice',
          // serverUrl missing
        }),
        isNull,
      );
    });
  });

  group('AccountsStorage', () {
    late FakeSecureKeyStore fakeStore;
    late AccountsStorage storage;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
      storage = AccountsStorage(secureStore: fakeStore);
    });

    test('load returns empty snapshot on fresh install', () async {
      final snap = await storage.load();
      expect(snap.accounts, isEmpty);
      expect(snap.activeAccountId, isNull);
      expect(snap.active, isNull);
    });

    test('upsertAccount appends new and bumps lastUsed', () async {
      final a1 = StoredAccount(
        userId: 'u1',
        username: 'alice',
        serverUrl: 'https://server.example',
        refreshToken: 'r1',
        lastUsed: DateTime.utc(2020, 1, 1),
      );
      final snap = await storage.upsertAccount(a1);
      expect(snap.accounts, hasLength(1));
      // lastUsed should be stamped to "now" (after Jan 1 2020).
      expect(
        snap.accounts.first.lastUsed.isAfter(DateTime.utc(2020, 1, 1)),
        isTrue,
      );
      expect(snap.accounts.first.userId, 'u1');
    });

    test('upsertAccount replaces existing by id without duplicating', () async {
      final a1 = StoredAccount(
        userId: 'u1',
        username: 'alice',
        serverUrl: 'https://server.example',
        refreshToken: 'r1',
        lastUsed: DateTime.utc(2020, 1, 1),
      );
      await storage.upsertAccount(a1);
      final a1Renamed = a1.copyWith(username: 'alice2', refreshToken: 'r1-new');
      final snap = await storage.upsertAccount(a1Renamed);
      expect(snap.accounts, hasLength(1));
      expect(snap.accounts.first.username, 'alice2');
      expect(snap.accounts.first.refreshToken, 'r1-new');
    });

    test('two distinct accounts persist separately', () async {
      final a = StoredAccount(
        userId: 'u1',
        username: 'alice',
        serverUrl: 'https://s1.example',
        refreshToken: 'r1',
        lastUsed: DateTime.utc(2020, 1, 1),
      );
      final b = StoredAccount(
        userId: 'u2',
        username: 'bob',
        serverUrl: 'https://s1.example',
        refreshToken: 'r2',
        lastUsed: DateTime.utc(2020, 1, 1),
      );
      await storage.upsertAccount(a);
      final snap = await storage.upsertAccount(b);
      expect(snap.accounts, hasLength(2));
      // Reload from a fresh storage instance to verify persistence.
      final reloaded = await AccountsStorage(secureStore: fakeStore).load();
      expect(reloaded.accounts, hasLength(2));
    });

    test('setActiveAccount + load surfaces active', () async {
      final a = StoredAccount(
        userId: 'u1',
        username: 'alice',
        serverUrl: 'https://s.example',
        refreshToken: 'r',
        lastUsed: DateTime.utc(2020, 1, 1),
      );
      await storage.upsertAccount(a);
      await storage.setActiveAccount(a.id);
      final snap = await storage.load();
      expect(snap.activeAccountId, a.id);
      expect(snap.active?.userId, 'u1');
    });

    test(
      'removeAccount drops the row and clears active pointer when matching',
      () async {
        final a = StoredAccount(
          userId: 'u1',
          username: 'alice',
          serverUrl: 'https://s.example',
          refreshToken: 'r1',
          lastUsed: DateTime.utc(2020, 1, 1),
        );
        final b = StoredAccount(
          userId: 'u2',
          username: 'bob',
          serverUrl: 'https://s.example',
          refreshToken: 'r2',
          lastUsed: DateTime.utc(2020, 1, 1),
        );
        await storage.upsertAccount(a);
        await storage.upsertAccount(b);
        await storage.setActiveAccount(a.id);

        // Removing the active account clears the pointer.
        final snap1 = await storage.removeAccount(a.id);
        expect(snap1.accounts.map((s) => s.userId), ['u2']);
        expect(snap1.activeAccountId, isNull);

        // Removing a non-active account preserves the pointer.
        await storage.setActiveAccount(b.id);
        await storage.upsertAccount(a); // re-add
        final snap2 = await storage.removeAccount(a.id);
        expect(snap2.activeAccountId, b.id);
      },
    );

    test('clear wipes both list and pointer', () async {
      final a = StoredAccount(
        userId: 'u1',
        username: 'alice',
        serverUrl: 'https://s.example',
        refreshToken: 'r1',
        lastUsed: DateTime.utc(2020, 1, 1),
      );
      await storage.upsertAccount(a);
      await storage.setActiveAccount(a.id);
      await storage.clear();
      final snap = await storage.load();
      expect(snap.accounts, isEmpty);
      expect(snap.activeAccountId, isNull);
    });

    test('AccountsSnapshot.active is null when pointer is stale', () {
      final accounts = [
        StoredAccount(
          userId: 'u1',
          username: 'alice',
          serverUrl: 'https://s.example',
          refreshToken: 'r',
          lastUsed: DateTime.utc(2020, 1, 1),
        ),
      ];
      const stale = AccountsSnapshot(
        accounts: [],
        activeAccountId: 'u1@https://s.example',
      );
      expect(stale.active, isNull);
      final fresh = AccountsSnapshot(
        accounts: accounts,
        activeAccountId: 'u1@https://s.example',
      );
      expect(fresh.active?.userId, 'u1');
    });
  });
}
