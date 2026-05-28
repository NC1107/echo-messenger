// Wire-shape contract test for [WebSocketNotifier]. Locks down the JSON
// frames the client emits so that any code-motion refactor (such as #1118)
// can not silently corrupt the bytes-on-wire.
//
// IMPORTANT: every assertion below ties to a server-side parser. Tightening
// a key, dropping a field, or renaming a top-level type breaks every
// existing client. Update server-side handlers in lockstep if you change
// anything here.

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/providers/privacy_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/providers/websocket_provider.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _WireCryptoService extends CryptoService {
  _WireCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) async {
    // Two recipient devices to exercise the multi-device map shape.
    return {
      '11': 'recip-dev-11-ciphertext==',
      '12': 'recip-dev-12-ciphertext==',
    };
  }

  @override
  Future<Map<String, String>> encryptForOwnDevices(
    String myUserId,
    String plaintext,
  ) async {
    // One self device (the sender's other device).
    return {'7': 'self-dev-7-ciphertext=='};
  }

  @override
  Future<String> encryptMessage(String peerUserId, String plaintext) async {
    return 'legacy-fallback-ciphertext==';
  }
}

class _NoMultiDeviceCryptoService extends CryptoService {
  _NoMultiDeviceCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => true;

  @override
  Future<Map<String, String>> encryptForAllDevices(
    String peerUserId,
    String plaintext,
  ) {
    throw Exception('No PreKey bundle found');
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
    return 'single-device-ciphertext==';
  }
}

class _SeededCrypto extends CryptoNotifier {
  _SeededCrypto(this._initial);
  final CryptoState _initial;
  @override
  CryptoState build() => _initial;
  @override
  Future<void> retryKeyUpload() async {}
  @override
  Future<void> initAndUploadKeys() async {}
}

class _SeededPrivacy extends Privacy {
  _SeededPrivacy(this._initial);
  final PrivacyState _initial;
  @override
  PrivacyState build() => _initial;
}

ProviderContainer _container({
  CryptoService? crypto,
  GroupCryptoService? groupCrypto,
  List<Conversation> seedConversations = const [],
}) {
  final c = ProviderContainer(
    overrides: [
      authProvider.overrideWith(
        () => FakeLoggedInAuthNotifier(
          const AuthState(
            isLoggedIn: true,
            userId: 'my-user-id',
            username: 'me',
            token: 'tkn',
          ),
        ),
      ),
      serverUrlProvider.overrideWith(
        () => FakeServerUrlNotifier('http://localhost:8080'),
      ),
      if (crypto != null) cryptoServiceProvider.overrideWithValue(crypto),
      if (groupCrypto != null)
        groupCryptoServiceProvider.overrideWithValue(groupCrypto),
      cryptoProvider.overrideWith(
        () => _SeededCrypto(const CryptoState(isInitialized: true)),
      ),
      privacyProvider.overrideWith(
        () => _SeededPrivacy(const PrivacyState(readReceiptsEnabled: true)),
      ),
    ],
  );
  if (seedConversations.isNotEmpty) {
    c.read(conversationsProvider.notifier).state = ConversationsState(
      conversations: seedConversations,
    );
  }
  return c;
}

void main() {
  group('DM send_message wire frame (multi-device)', () {
    test(
      'encodes type, to_user_id, content + per-recipient device map',
      () async {
        final c = _container(crypto: _WireCryptoService());
        addTearDown(c.dispose);

        final ws = c.read(websocketProvider.notifier);
        await ws.sendMessage(
          'peer-1',
          'hello',
          conversationId: 'conv-1',
          replyToId: 'msg-r',
          threadRootId: 'msg-t',
        );

        expect(ws.debugSentFrames, hasLength(1));
        final frame = ws.debugSentFrames.single;

        // Required top-level fields (server-side parser keys).
        expect(frame['type'], 'send_message');
        expect(frame['to_user_id'], 'peer-1');
        // Legacy fallback content = first recipient ciphertext (NOT self).
        expect(frame['content'], 'recip-dev-11-ciphertext==');
        expect(frame['conversation_id'], 'conv-1');
        expect(frame['reply_to_id'], 'msg-r');
        expect(frame['thread_root_id'], 'msg-t');

        // Multi-device envelope: outer key = userId, inner = deviceId -> ct.
        final rdc = frame['recipient_device_contents'] as Map<String, dynamic>;
        expect(rdc.keys, containsAll(['peer-1', 'my-user-id']));
        final peerMap = Map<String, dynamic>.from(rdc['peer-1'] as Map);
        expect(peerMap['11'], 'recip-dev-11-ciphertext==');
        expect(peerMap['12'], 'recip-dev-12-ciphertext==');
        final selfMap = Map<String, dynamic>.from(rdc['my-user-id'] as Map);
        expect(selfMap['7'], 'self-dev-7-ciphertext==');
      },
    );

    test('omits optional metadata when not provided', () async {
      final c = _container(crypto: _WireCryptoService());
      addTearDown(c.dispose);

      await c.read(websocketProvider.notifier).sendMessage('peer-2', 'hi');
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;

      expect(frame.containsKey('conversation_id'), isFalse);
      expect(frame.containsKey('reply_to_id'), isFalse);
      expect(frame.containsKey('thread_root_id'), isFalse);
      expect(frame['type'], 'send_message');
      expect(frame['to_user_id'], 'peer-2');
    });

    test('single-device fallback omits recipient_device_contents', () async {
      final c = _container(crypto: _NoMultiDeviceCryptoService());
      addTearDown(c.dispose);

      await c
          .read(websocketProvider.notifier)
          .sendMessage('peer-3', 'hi', conversationId: 'conv-3');
      final frames = c.read(websocketProvider.notifier).debugSentFrames;
      expect(frames, hasLength(1));
      final frame = frames.single;

      // Fallback path: legacy single ciphertext, no per-device map.
      expect(frame['type'], 'send_message');
      expect(frame['content'], 'single-device-ciphertext==');
      expect(frame.containsKey('recipient_device_contents'), isFalse);
      expect(frame['conversation_id'], 'conv-3');
    });
  });

  group('group send_message wire frame', () {
    test(
      'unencrypted group sends plaintext content + conversation_id',
      () async {
        final c = _container(
          seedConversations: [
            const Conversation(id: 'grp-1', isGroup: true, isEncrypted: false),
          ],
        );
        addTearDown(c.dispose);

        await c
            .read(websocketProvider.notifier)
            .sendGroupMessage(
              'grp-1',
              'public-text',
              channelId: 'chan-x',
              replyToId: 'r-1',
              threadRootId: 't-1',
            );

        final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
        expect(frame['type'], 'send_message');
        expect(frame['conversation_id'], 'grp-1');
        expect(frame['content'], 'public-text');
        expect(frame['channel_id'], 'chan-x');
        expect(frame['reply_to_id'], 'r-1');
        expect(frame['thread_root_id'], 't-1');
        // GRP1 plaintext path never sets client_message_id.
        expect(frame.containsKey('client_message_id'), isFalse);
        // Group send must NOT include the DM-only recipient_device_contents.
        expect(frame.containsKey('recipient_device_contents'), isFalse);
        expect(frame.containsKey('to_user_id'), isFalse);
      },
    );
  });

  group('control-frame wire shapes', () {
    test('typing frame shape', () {
      final c = _container();
      addTearDown(c.dispose);

      c
          .read(websocketProvider.notifier)
          .sendTyping('conv-1', channelId: 'ch-1');
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
      expect(frame, {
        'type': 'typing',
        'conversation_id': 'conv-1',
        'channel_id': 'ch-1',
      });
    });

    test('typing frame without channel omits channel_id', () {
      final c = _container();
      addTearDown(c.dispose);

      c.read(websocketProvider.notifier).sendTyping('conv-x');
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
      expect(frame, {'type': 'typing', 'conversation_id': 'conv-x'});
    });

    test('read_receipt frame shape', () {
      final c = _container();
      addTearDown(c.dispose);

      c.read(websocketProvider.notifier).sendReadReceipt('conv-r');
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
      expect(frame, {'type': 'read_receipt', 'conversation_id': 'conv-r'});
    });

    test('key_reset frame shape', () {
      final c = _container();
      addTearDown(c.dispose);

      c.read(websocketProvider.notifier).sendKeyReset('conv-k');
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
      expect(frame, {'type': 'key_reset', 'conversation_id': 'conv-k'});
    });

    test('call_started frame shape', () {
      final c = _container();
      addTearDown(c.dispose);

      c.read(websocketProvider.notifier).sendCallStarted('conv-c');
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
      expect(frame, {'type': 'call_started', 'conversation_id': 'conv-c'});
    });

    test('voice_signal frame shape', () {
      final c = _container();
      addTearDown(c.dispose);

      c
          .read(websocketProvider.notifier)
          .sendVoiceSignal(
            conversationId: 'conv-v',
            channelId: 'ch-v',
            toUserId: 'peer-v',
            signal: const {'sdp': 'offer-blob'},
          );
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
      expect(frame, {
        'type': 'voice_signal',
        'conversation_id': 'conv-v',
        'channel_id': 'ch-v',
        'to_user_id': 'peer-v',
        'signal': {'sdp': 'offer-blob'},
      });
    });

    test('canvas_event frame shape', () {
      final c = _container();
      addTearDown(c.dispose);

      c
          .read(websocketProvider.notifier)
          .sendCanvasEvent(
            channelId: 'ch-canvas',
            kind: 'stroke',
            payload: const {'x': 1, 'y': 2},
          );
      final frame = c.read(websocketProvider.notifier).debugSentFrames.single;
      expect(frame, {
        'type': 'canvas_event',
        'channel_id': 'ch-canvas',
        'kind': 'stroke',
        'payload': {'x': 1, 'y': 2},
      });
    });
  });
}
