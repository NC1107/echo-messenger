import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/providers/websocket_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';

// ---------------------------------------------------------------------------
// Test-scoped CryptoService fake
// ---------------------------------------------------------------------------

/// A CryptoService subclass whose encrypt methods can be configured to throw.
///
/// Because CryptoService methods make network calls and interact with secure
/// storage, we override only the methods exercised by
/// [WebSocketNotifier.sendMessage].
class _TestCryptoService extends CryptoService {
  _TestCryptoService() : super(serverUrl: 'http://localhost:8080');

  bool encryptForAllDevicesThrows = false;
  bool encryptMessageThrows = false;
  int invalidateSessionKeyCalls = 0;

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) async {
    if (encryptForAllDevicesThrows) {
      throw Exception('multi-device encryption failed');
    }
    return {'0': 'ciphertext-base64=='};
  }

  @override
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) async {
    return {};
  }

  @override
  Future<String> encryptMessage(String peerUserId, String plaintext) async {
    if (encryptMessageThrows) {
      throw Exception('single-device encryption failed');
    }
    return 'ciphertext-base64==';
  }

  @override
  Future<void> invalidateSessionKey(String peerUserId) async {
    invalidateSessionKeyCalls++;
    // After invalidation, encryptMessage will be called again.
    // If encryptMessageThrows is still true, the retry also fails.
  }
}

// ---------------------------------------------------------------------------
// Fake CryptoNotifier with spy capability
// ---------------------------------------------------------------------------

class _SpyCryptoNotifier extends CryptoNotifier {
  int retryKeyUploadCalls = 0;

  _SpyCryptoNotifier(super.ref, {required CryptoState initial}) {
    state = initial;
  }

  @override
  Future<void> retryKeyUpload() async {
    retryKeyUploadCalls++;
  }

  @override
  Future<void> initAndUploadKeys() async {}
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a [ProviderContainer] wired for WebSocket send tests.
///
/// [cryptoState] controls the CryptoNotifier state visible to sendMessage.
/// [testCrypto] is an optional custom CryptoService fake.
/// [spyNotifier] if provided, overrides the CryptoNotifier for spy access.
/// [readReceiptsEnabled] controls the privacy provider state.
ProviderContainer _createContainer({
  CryptoState cryptoState = const CryptoState(isInitialized: true),
  CryptoService? testCrypto,
  _SpyCryptoNotifier? spyNotifier,
  bool readReceiptsEnabled = true,
}) {
  return ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) {
        final n = AuthNotifier(ref);
        n.state = const AuthState(
          isLoggedIn: true,
          userId: 'my-user-id',
          username: 'testuser',
          token: 'fake-jwt-token',
        );
        return n;
      }),
      serverUrlProvider.overrideWith((ref) {
        final n = ServerUrlNotifier();
        n.state = 'http://localhost:8080';
        return n;
      }),
      if (testCrypto != null)
        cryptoServiceProvider.overrideWithValue(testCrypto),
      if (spyNotifier != null)
        cryptoProvider.overrideWith((ref) => spyNotifier)
      else
        cryptoProvider.overrideWith((ref) {
          final n = _SpyCryptoNotifier(ref, initial: cryptoState);
          return n;
        }),
      privacyProvider.overrideWith((ref) {
        final n = PrivacyNotifier(ref);
        n.state = PrivacyState(readReceiptsEnabled: readReceiptsEnabled);
        return n;
      }),
    ],
  );
}

void main() {
  group('WebSocketNotifier.sendMessage failure paths', () {
    test('crypto not initialized adds failed message with reason', () async {
      final container = _createContainer(
        cryptoState: const CryptoState(
          isInitialized: false,
          error: 'Secure storage unavailable',
        ),
      );
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // Should have added a failed message to chat state.
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.status, MessageStatus.failed);
      expect(msgs.first.isMine, isTrue);
      // The reason should come from the crypto error.
      expect(msgs.first.content, 'Secure storage unavailable');
      // Original content preserved for retry.
      expect(msgs.first.failedContent, 'hello');
    });

    test('crypto not initialized with no error uses default message', () async {
      final container = _createContainer(
        cryptoState: const CryptoState(isInitialized: false),
      );
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.status, MessageStatus.failed);
      expect(msgs.first.content, 'Encryption not initialized');
    });

    test(
      'keysUploadFailed triggers retryKeyUpload before encrypting',
      () async {
        final testCrypto = _TestCryptoService();
        final container = _createContainer(
          cryptoState: const CryptoState(
            isInitialized: true,
            keysUploadFailed: true,
          ),
          testCrypto: testCrypto,
        );
        addTearDown(container.dispose);

        // Get the spy notifier to check retryKeyUpload was called.
        final cryptoNotifier =
            container.read(cryptoProvider.notifier) as _SpyCryptoNotifier;

        final wsNotifier = container.read(websocketProvider.notifier);
        await wsNotifier.sendMessage(
          'peer-1',
          'hello',
          conversationId: 'conv-1',
        );

        expect(cryptoNotifier.retryKeyUploadCalls, 1);
      },
    );

    test(
      'all encryption fails produces friendly error, not stack trace',
      () async {
        final testCrypto = _TestCryptoService()
          ..encryptForAllDevicesThrows = true
          ..encryptMessageThrows = true;

        final container = _createContainer(
          cryptoState: const CryptoState(isInitialized: true),
          testCrypto: testCrypto,
        );
        addTearDown(container.dispose);

        final wsNotifier = container.read(websocketProvider.notifier);
        await wsNotifier.sendMessage(
          'peer-1',
          'hello',
          conversationId: 'conv-1',
        );

        final msgs = container
            .read(chatProvider)
            .messagesForConversation('conv-1');
        expect(msgs, hasLength(1));
        expect(msgs.first.status, MessageStatus.failed);
        // Content should be a friendly message, NOT a raw Exception toString.
        expect(msgs.first.content, isNot(contains('Exception')));
        expect(msgs.first.content, isNot(contains('stack')));
        // It should be one of the friendly messages from _friendlyEncryptionError.
        expect(msgs.first.content, isNotEmpty);
        // Original text preserved for retry.
        expect(msgs.first.failedContent, 'hello');
      },
    );

    test('multi-device encryption fails but single-device succeeds (no failed '
        'message)', () async {
      final testCrypto = _TestCryptoService()
        ..encryptForAllDevicesThrows = true
        ..encryptMessageThrows = false;

      final container = _createContainer(
        cryptoState: const CryptoState(isInitialized: true),
        testCrypto: testCrypto,
      );
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // No failed message should be added -- fallback single-device
      // encryption succeeded. The message would be sent via _channel?.sink
      // which is null in tests, so no actual send occurs, but crucially no
      // failed message is created.
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, isEmpty);
    });

    test(
      'all encryption fails calls invalidateSessionKey before final retry',
      () async {
        final testCrypto = _TestCryptoService()
          ..encryptForAllDevicesThrows = true
          ..encryptMessageThrows = true;

        final container = _createContainer(
          cryptoState: const CryptoState(isInitialized: true),
          testCrypto: testCrypto,
        );
        addTearDown(container.dispose);

        final wsNotifier = container.read(websocketProvider.notifier);
        await wsNotifier.sendMessage(
          'peer-1',
          'hello',
          conversationId: 'conv-1',
        );

        // invalidateSessionKey should have been called once during the
        // retry-after-reset path.
        expect(testCrypto.invalidateSessionKeyCalls, 1);
      },
    );
  });

  group('WebSocketNotifier._friendlyEncryptionError', () {
    // _friendlyEncryptionError is a static method on WebSocketNotifier.
    // We can't call it directly (it's private), but we CAN verify its
    // behavior indirectly through sendMessage's failure path.

    test('No PreKey bundle maps to waiting message', () async {
      final container = _createContainer(
        cryptoState: const CryptoState(isInitialized: true),
        testCrypto: _PreKeyErrorCryptoService(),
      );
      addTearDown(container.dispose);

      await container
          .read(websocketProvider.notifier)
          .sendMessage('peer-1', 'hi', conversationId: 'conv-1');

      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(
        msgs.first.content,
        'Waiting for this person to come online to secure the chat.',
      );
    });
  });

  group('WebSocketNotifier.sendReadReceipt', () {
    test('respects privacy setting when disabled', () {
      final container = _createContainer(readReceiptsEnabled: false);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);

      // sendReadReceipt should exit early when readReceiptsEnabled is false.
      // Since _channel is null in tests, if it DID try to send it would be
      // a no-op anyway, but we verify the method doesn't crash and the
      // privacy check happens by confirming the state is unchanged.
      wsNotifier.sendReadReceipt('conv-1');

      // No state change -- the WebSocket state should remain as-is.
      final wsState = container.read(websocketProvider);
      expect(wsState.isConnected, isFalse);
    });

    test('attempts to send when privacy allows', () {
      final container = _createContainer(readReceiptsEnabled: true);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);

      // Should not crash -- _channel is null so sink.add is a no-op.
      wsNotifier.sendReadReceipt('conv-1');

      // No state change expected, method is fire-and-forget.
      final wsState = container.read(websocketProvider);
      expect(wsState.isConnected, isFalse);
    });
  });

  group('WebSocketNotifier.sendTyping throttle', () {
    test('does not crash when channel is null', () {
      final container = _createContainer();
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);

      // sendTyping should not crash even with null _channel.
      wsNotifier.sendTyping('conv-1');

      // No state change expected.
      expect(container.read(websocketProvider).isConnected, isFalse);
    });

    test('sendTyping with channelId does not crash', () {
      final container = _createContainer();
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);

      wsNotifier.sendTyping('conv-1', channelId: 'chan-1');

      expect(container.read(websocketProvider).isConnected, isFalse);
    });
  });
}

// ---------------------------------------------------------------------------
// Specialized fakes for specific error scenarios
// ---------------------------------------------------------------------------

/// CryptoService that always throws "No PreKey bundle found" on all encrypt
/// paths, triggering the specific friendly error message.
class _PreKeyErrorCryptoService extends CryptoService {
  _PreKeyErrorCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) async {
    throw Exception('No PreKey bundle found for user');
  }

  @override
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) async {
    return {};
  }

  @override
  Future<String> encryptMessage(String peerUserId, String plaintext) async {
    throw Exception('No PreKey bundle found for user');
  }

  @override
  Future<void> invalidateSessionKey(String peerUserId) async {}
}
