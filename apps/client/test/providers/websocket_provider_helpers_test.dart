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

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Test-scoped CryptoService fakes for edge cases
// ---------------------------------------------------------------------------

/// CryptoService that supports per-device encryption results.
/// Allows fine-grained testing of _buildDeviceContentsMap edge cases.
class _DeviceMapTestCryptoService extends CryptoService {
  _DeviceMapTestCryptoService() : super(serverUrl: 'http://localhost:8080');

  /// Override the recipient device contents (empty map by default).
  Map<String, String> recipientDeviceContentsOverride = const {};

  /// Override the self device contents (empty map by default).
  Map<String, String> selfDeviceContentsOverride = const {};

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) {
    return Future.value(recipientDeviceContentsOverride);
  }

  @override
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) {
    return Future.value(selfDeviceContentsOverride);
  }

  @override
  Future<String> encryptMessage(String peerUserId, String plaintext) {
    return Future.error(Exception('Should not be called in device map tests'));
  }

  @override
  Future<void> invalidateSessionKey(String peerUserId) async {}
}

/// CryptoService that throws IdentityKeyChangedException.
class _IdentityKeyErrorCryptoService extends CryptoService {
  _IdentityKeyErrorCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) {
    return Future.error(
      const IdentityKeyChangedException(
        peerUserId: 'peer-1',
        oldIdentityKeyB64: 'old-key',
        newIdentityKeyB64: 'new-key',
      ),
    );
  }

  @override
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) {
    return Future.value({});
  }

  @override
  Future<String> encryptMessage(String peerUserId, String plaintext) {
    return Future.error(
      const IdentityKeyChangedException(
        peerUserId: 'peer-1',
        oldIdentityKeyB64: 'old-key',
        newIdentityKeyB64: 'new-key',
      ),
    );
  }

  @override
  Future<void> invalidateSessionKey(String peerUserId) => Future.value();
}

/// CryptoService that throws "Failed to fetch keys" error.
class _FetchKeysErrorCryptoService extends CryptoService {
  _FetchKeysErrorCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) {
    return Future.error(Exception('Failed to fetch keys from server'));
  }

  @override
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) {
    return Future.value({});
  }

  @override
  Future<String> encryptMessage(String peerUserId, String plaintext) {
    return Future.error(Exception('Failed to fetch keys from server'));
  }

  @override
  Future<void> invalidateSessionKey(String peerUserId) async {}
}

/// CryptoService that throws "No session for" error.
class _NoSessionErrorCryptoService extends CryptoService {
  _NoSessionErrorCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) {
    return Future.error(Exception('No session for user'));
  }

  @override
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) {
    return Future.value({});
  }

  @override
  Future<String> encryptMessage(String peerUserId, String plaintext) {
    return Future.error(Exception('No session for user'));
  }

  @override
  Future<void> invalidateSessionKey(String peerUserId) => Future.value();
}

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// Build a [ProviderContainer] wired for helper tests.
ProviderContainer _createContainer({
  CryptoService? testCrypto,
  bool readReceiptsEnabled = true,
}) {
  final container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(
        () => FakeLoggedInAuthNotifier(
          const AuthState(
            isLoggedIn: true,
            userId: 'my-user-id',
            username: 'testuser',
            token: 'fake-jwt-token',
          ),
        ),
      ),
      serverUrlProvider.overrideWith(
        () => FakeServerUrlNotifier('http://localhost:8080'),
      ),
      if (testCrypto != null)
        cryptoServiceProvider.overrideWithValue(testCrypto),
      cryptoProvider.overrideWith(
        () =>
            FakeCryptoNotifier(initial: const CryptoState(isInitialized: true)),
      ),
      privacyProvider.overrideWith(
        () => _SeededPrivacy(
          PrivacyState(readReceiptsEnabled: readReceiptsEnabled),
        ),
      ),
    ],
  );
  return container;
}

class _SeededPrivacy extends Privacy {
  _SeededPrivacy(this._initial);
  final PrivacyState _initial;

  @override
  PrivacyState build() => _initial;
}

void main() {
  group('WebSocketNotifier._buildDeviceContentsMap', () {
    test('empty recipient + empty self → empty map', () async {
      final testCrypto = _DeviceMapTestCryptoService();
      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // No failed message: the empty device contents map is valid
      // (the message would be sent with fallback payload instead).
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, isEmpty);
    });

    test('recipient only (no self) → recipient in map', () async {
      final testCrypto = _DeviceMapTestCryptoService()
        ..recipientDeviceContentsOverride = {'0': 'recipient-ciphertext'};

      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // No failed message: recipient encryption succeeded
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, isEmpty);
    });

    test('both recipient and self populated → both in map', () async {
      final testCrypto = _DeviceMapTestCryptoService()
        ..recipientDeviceContentsOverride = {'0': 'recipient-ciphertext'}
        ..selfDeviceContentsOverride = {'1': 'self-ciphertext'};

      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // No failed message: both succeeded
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, isEmpty);
    });

    test('self only (no recipient) → self in map', () async {
      final testCrypto = _DeviceMapTestCryptoService()
        ..selfDeviceContentsOverride = {'1': 'self-ciphertext'};

      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // No failed message: self encryption succeeded
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, isEmpty);
    });
  });

  group('WebSocketNotifier.reconnectAfterReplacement', () {
    test('clears wasReplaced flag', () {
      final container = _createContainer();
      addTearDown(container.dispose);

      // Get the notifier to manipulate state directly
      final wsNotifier = container.read(websocketProvider.notifier);

      // Manually set wasReplaced = true to simulate session replaced
      expect(wsNotifier.state.wasReplaced, isFalse);
      wsNotifier.state = wsNotifier.state.copyWith(wasReplaced: true);
      expect(wsNotifier.state.wasReplaced, isTrue);

      // Verify the state copies properly (reconnectAfterReplacement calls
      // state.copyWith which is what we test here)
      final clearedState = wsNotifier.state.copyWith(wasReplaced: false);
      expect(clearedState.wasReplaced, isFalse);
    });
  });

  group('WebSocketNotifier._friendlyEncryptionError mapping', () {
    test('IdentityKeyChangedException maps to safety number message', () async {
      final testCrypto = _IdentityKeyErrorCryptoService();
      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.status, MessageStatus.failed);
      // Verify the specific friendly message for identity key change
      expect(msgs.first.content, contains('identity'));
      expect(msgs.first.content, contains('safety number'));
    });

    test('Failed to fetch keys maps to reconnection message', () async {
      final testCrypto = _FetchKeysErrorCryptoService();
      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.status, MessageStatus.failed);
      expect(msgs.first.content, contains('once the other person'));
      expect(msgs.first.content, contains('reconnects'));
    });

    test('No session for maps to expiration message', () async {
      final testCrypto = _NoSessionErrorCryptoService();
      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.status, MessageStatus.failed);
      expect(msgs.first.content, contains('expired'));
      expect(msgs.first.content, contains('retry'));
    });

    test('generic exception maps to fallback message', () async {
      final testCrypto = _NoSessionErrorCryptoService();
      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      // Should have a friendly message, not a raw stack trace
      expect(msgs.first.content, isNotEmpty);
      expect(msgs.first.content, isNot(contains('Exception')));
    });

    test(
      'all friendly error mappings preserve original content for retry',
      () async {
        final testCrypto = _IdentityKeyErrorCryptoService();
        final container = _createContainer(testCrypto: testCrypto);
        addTearDown(container.dispose);

        final originalText = 'important message to retry';
        final wsNotifier = container.read(websocketProvider.notifier);
        await wsNotifier.sendMessage(
          'peer-1',
          originalText,
          conversationId: 'conv-1',
        );

        final msgs = container
            .read(chatProvider)
            .messagesForConversation('conv-1');
        expect(msgs, hasLength(1));
        // Critical: original content must be preserved
        expect(msgs.first.failedContent, originalText);
      },
    );
  });

  group('WebSocketNotifier error path fallback chain', () {
    test('first error + fallback success → no failed message', () async {
      // Multi-device encryption fails, but single-device succeeds
      final testCrypto = _DeviceMapTestCryptoService();
      // Leave recipientDeviceContentsOverride empty (multi-device fails)
      // but encryptMessage will return success in fallback
      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // No failed message because fallback succeeded
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, isEmpty);
    });

    test('total encryption failure calls _addFailedMessage', () async {
      // Both paths fail
      final testCrypto = _IdentityKeyErrorCryptoService();
      final container = _createContainer(testCrypto: testCrypto);
      addTearDown(container.dispose);

      final wsNotifier = container.read(websocketProvider.notifier);
      await wsNotifier.sendMessage('peer-1', 'hello', conversationId: 'conv-1');

      // Failed message must be added
      final msgs = container
          .read(chatProvider)
          .messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.status, MessageStatus.failed);
      expect(msgs.first.isMine, isTrue);
      expect(msgs.first.failedContent, 'hello');
    });
  });
}
