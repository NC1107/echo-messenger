import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/widgets/identity_key_changed_banner.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

/// Test double that lets us drive `hasPeerIdentityKeyChanged` and observe
/// which acceptance method the banner calls.
class _FakeCrypto extends FakeCryptoNotifier {
  // ignore: use_super_parameters
  _FakeCrypto(Ref ref, {bool changed = false})
    : _changed = changed,
      super(ref, initial: const CryptoState(isInitialized: true));

  bool _changed;
  int acceptCalls = 0;
  int acknowledgeCalls = 0;

  @override
  Future<bool> hasPeerIdentityKeyChanged(String peerUserId) async => _changed;

  @override
  Future<void> acknowledgePeerIdentityKeyChange(String peerUserId) async {
    acknowledgeCalls++;
    _changed = false;
  }

  @override
  Future<void> acceptIdentityKeyChange(
    String peerUserId, {
    String? newIdentityKeyB64,
  }) async {
    acceptCalls++;
    _changed = false;
  }
}

const _conv = Conversation(
  id: 'conv-1',
  name: null,
  isGroup: false,
  lastMessage: '',
  lastMessageTimestamp: '2026-01-15T10:30:00Z',
  lastMessageSender: '',
  unreadCount: 0,
  members: [
    ConversationMember(userId: 'peer-1', username: 'alice'),
    ConversationMember(userId: 'me', username: 'me'),
  ],
);

void main() {
  group('IdentityKeyChangedBanner (#580)', () {
    setUp(() {
      SharedPreferences.setMockInitialValues({});
    });

    testWidgets('hidden when peer key has not changed', (tester) async {
      await tester.pumpApp(
        const IdentityKeyChangedBanner(conversation: _conv),
        overrides: [
          authOverride(
            const AuthState(userId: 'me', username: 'me', token: 't'),
          ),
          cryptoProvider.overrideWith(
            (ref) => _FakeCrypto(ref, changed: false),
          ),
        ],
      );
      await tester.pumpAndSettle();

      expect(find.text('Trust new key'), findsNothing);
      expect(find.text('Verify'), findsNothing);
    });

    testWidgets(
      'shows verify, trust new key, and dismiss actions when key changed',
      (tester) async {
        late _FakeCrypto fakeCrypto;
        await tester.pumpApp(
          const IdentityKeyChangedBanner(conversation: _conv),
          overrides: [
            authOverride(
              const AuthState(
                isLoggedIn: true,
                userId: 'me',
                username: 'me',
                token: 't',
              ),
            ),
            cryptoProvider.overrideWith((ref) {
              fakeCrypto = _FakeCrypto(ref, changed: true);
              return fakeCrypto;
            }),
          ],
        );
        // Drain the async _checkIdentityKey future + AnimatedSize tween.
        for (var i = 0; i < 10; i++) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        // Sanity: the fake started in the initialized state.
        expect(fakeCrypto.state.isInitialized, isTrue);

        expect(find.text('Verify'), findsOneWidget);
        expect(find.text('Trust new key'), findsOneWidget);
        // The close icon is the third action; we accept any Icon with the
        // close glyph as the dismiss control.
        expect(find.byIcon(Icons.close), findsOneWidget);
      },
    );

    testWidgets('Trust new key tap calls acceptIdentityKeyChange', (
      tester,
    ) async {
      late _FakeCrypto fakeCrypto;
      await tester.pumpApp(
        const IdentityKeyChangedBanner(conversation: _conv),
        overrides: [
          authOverride(
            const AuthState(userId: 'me', username: 'me', token: 't'),
          ),
          cryptoProvider.overrideWith((ref) {
            fakeCrypto = _FakeCrypto(ref, changed: true);
            return fakeCrypto;
          }),
        ],
      );
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      await tester.tap(find.text('Trust new key'));
      for (var i = 0; i < 5; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(fakeCrypto.acceptCalls, 1);
      // Banner should hide after accept.
      expect(find.text('Trust new key'), findsNothing);
    });
  });
}
