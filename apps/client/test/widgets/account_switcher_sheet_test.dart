import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/services/accounts_storage.dart';
import 'package:echo_app/src/services/secure_key_store.dart';
import 'package:echo_app/src/widgets/account_switcher_sheet.dart';

import '../helpers/fake_secure_key_store.dart';
import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('AccountSwitcherSheet', () {
    late FakeSecureKeyStore fakeKeyStore;
    late AccountsStorage storage;

    setUp(() {
      SharedPreferences.setMockInitialValues(<String, Object>{});
      fakeKeyStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeKeyStore;
      storage = AccountsStorage(secureStore: fakeKeyStore);
    });

    /// Pump the sheet body directly with the active provider's storage
    /// swapped to [storage] (the fake-keystore-backed instance). We pump
    /// the body inline rather than going through `showEchoBottomSheet` so
    /// the test doesn't need a router or a real Scaffold to host the modal.
    Future<void> pumpSheet(
      WidgetTester tester, {
      required List<Override> extra,
    }) async {
      await tester.pumpApp(
        Consumer(
          builder: (ctx, ref, _) {
            ref.read(authProvider.notifier).setAccountsStorageForTest(storage);
            return const AccountSwitcherSheet();
          },
        ),
        overrides: [serverUrlOverride('http://localhost:8080'), ...extra],
      );
      // FutureBuilder needs a microtask + a frame to flush the
      // `listAccounts` Future.
      await tester.pumpAndSettle();
    }

    testWidgets('renders one row per stored account', (tester) async {
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-alice',
          username: 'alice',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r-a',
          lastUsed: DateTime.utc(2026, 1, 1),
        ),
      );
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-bob',
          username: 'bob',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r-b',
          lastUsed: DateTime.utc(2026, 1, 2),
        ),
      );
      await storage.setActiveAccount('u-alice@http://localhost:8080');

      await pumpSheet(tester, extra: const []);

      expect(find.text('alice'), findsOneWidget);
      expect(find.text('bob'), findsOneWidget);
      expect(find.text('Add another account'), findsOneWidget);
    });

    testWidgets('marks the active account with a check icon', (tester) async {
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-active',
          username: 'active_user',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r',
          lastUsed: DateTime.utc(2026, 1, 1),
        ),
      );
      await storage.upsertAccount(
        StoredAccount(
          userId: 'u-other',
          username: 'other_user',
          serverUrl: 'http://localhost:8080',
          refreshToken: 'r',
          lastUsed: DateTime.utc(2026, 1, 2),
        ),
      );
      await storage.setActiveAccount('u-active@http://localhost:8080');

      await pumpSheet(tester, extra: const []);

      // Exactly one check icon for the active row.
      expect(find.byIcon(Icons.check_circle), findsOneWidget);
    });

    testWidgets(
      'shows only "Add another account" when no accounts are stored',
      (tester) async {
        await pumpSheet(tester, extra: const []);
        expect(find.text('Add another account'), findsOneWidget);
        expect(find.byIcon(Icons.check_circle), findsNothing);
      },
    );
  });
}
