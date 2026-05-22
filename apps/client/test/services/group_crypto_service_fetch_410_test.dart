/// Production E2E regression: when the server returns 410 Gone from
/// `GET /api/groups/:id/keys/latest` ("no envelope for this user at the
/// latest version"), [GroupCryptoService.fetchGroupKey] must:
///
///   1. Return null (no key was cached).
///   2. Fire the `onGroupNeedsRotation` callback so the chat layer can
///      flip the per-conversation banner flag.
///
/// Previously the server fell back to the `__envelope__` sentinel and
/// served it as a 9-byte AES "key", which exploded downstream in
/// [assertGroupKeyShape] with `candidate key has wrong length: 9 bytes`.
library;

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/services/secure_key_store.dart';

import '../helpers/fake_secure_key_store.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('GroupCryptoService.fetchGroupKey — 410 Gone path', () {
    late FakeSecureKeyStore fakeStore;

    setUp(() {
      fakeStore = FakeSecureKeyStore();
      SecureKeyStore.instance = fakeStore;
    });

    test(
      'invokes onGroupNeedsRotation and returns null when server returns 410',
      () async {
        const groupId = 'group-needs-rotation';
        final service = GroupCryptoService(serverUrl: 'http://example.test');

        String? notifiedConversation;
        service.onGroupNeedsRotation = (convId) {
          notifiedConversation = convId;
        };

        await http.runWithClient(
          () async {
            final result = await service.fetchGroupKey(groupId);
            expect(result, isNull, reason: 'no key was cached');
          },
          () => MockClient((req) async {
            expect(req.url.path, contains('/api/groups/$groupId/keys/latest'));
            return http.Response(
              '{"code":"no-envelope-for-user","key_version":3}',
              410,
              headers: {'content-type': 'application/json'},
            );
          }),
        );

        expect(
          notifiedConversation,
          equals(groupId),
          reason:
              '410 must trigger the needs-rotation callback so the chat '
              'banner can surface the "Refresh key" affordance',
        );
      },
    );

    test('does NOT invoke onGroupNeedsRotation on 200 happy path', () async {
      const groupId = 'group-happy-path';
      final service = GroupCryptoService(serverUrl: 'http://example.test');

      bool notified = false;
      service.onGroupNeedsRotation = (_) {
        notified = true;
      };

      await http.runWithClient(
        () async {
          // 200 with a real-looking envelope. The unwrap path will fail
          // (no CryptoService wired -> falls through legacy plaintext-
          // key branch which then fails the structural-shape check),
          // but the test only cares that the 410 branch is NOT taken
          // on a 200.
          await service.fetchGroupKey(groupId);
        },
        () => MockClient((_) async {
          return http.Response(
            '{"encrypted_key":"c29tZS1lbnZlbG9wZQ==",'
            '"key_version":1,"min_wire_version":1}',
            200,
            headers: {'content-type': 'application/json'},
          );
        }),
      );

      expect(
        notified,
        isFalse,
        reason: '200 must NOT trip the needs-rotation flag',
      );
    });
  });
}
