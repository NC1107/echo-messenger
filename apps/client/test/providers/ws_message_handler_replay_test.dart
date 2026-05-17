// Tests for #26 replay suppression: cached messages must not re-bump the
// unread count or re-fire notifications on re-login.
//
// Kept in a separate file from ws_message_handler_test.dart to avoid
// Hive initialization interfering with the SoundService async-error timing
// in the existing mention-detection tests.

import 'dart:async';
import 'dart:io';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_flutter/hive_flutter.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/channels_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/conversations_provider.dart';
import 'package:echo_app/src/providers/crypto_provider.dart';
import 'package:echo_app/src/providers/server_url_provider.dart';
import 'package:echo_app/src/providers/ws_message_handler.dart';
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/services/message_cache.dart';

import '../helpers/mock_providers.dart';

// ---------------------------------------------------------------------------
// Fakes (minimal subset needed for these tests)
// ---------------------------------------------------------------------------

class _FakeCryptoService extends CryptoService {
  _FakeCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => false;
}

class _FakeGroupCryptoService extends GroupCryptoService {
  _FakeGroupCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  Future<(int, String)?> fetchGroupKey(String conversationId) async => null;
}

class _FakeChannelsNotifier extends Channels {
  @override
  ChannelsState build() => const ChannelsState();

  @override
  Future<void> loadChannels(String conversationId) async {}

  @override
  Future<void> loadVoiceSessions(
    String conversationId,
    String channelId,
  ) async {}
}

class _SeededCryptoNotifier extends CryptoNotifier {
  _SeededCryptoNotifier(this._initial);
  final CryptoState _initial;

  @override
  CryptoState build() => _initial;
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  @override
  ConversationsState build() => const ConversationsState(
    conversations: [
      Conversation(
        id: 'conv-1',
        isGroup: false,
        members: [
          ConversationMember(userId: 'peer-1', username: 'alice'),
          ConversationMember(userId: 'my-user-id', username: 'testuser'),
        ],
      ),
    ],
  );

  @override
  Future<void> loadConversations() async {}
}

class _TestWsHandler extends Notifier<WebSocketState> with WsMessageHandler {
  @override
  final StreamController<Map<String, dynamic>> voiceSignalController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  final StreamController<Map<String, dynamic>> deviceRevokedController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  WebSocketState build() => const WebSocketState();
}

final _testHandlerProvider = NotifierProvider<_TestWsHandler, WebSocketState>(
  _TestWsHandler.new,
);

// ---------------------------------------------------------------------------
// Test setup
// ---------------------------------------------------------------------------

late ProviderContainer _container;
late _TestWsHandler _handler;

void _setup() {
  _container = ProviderContainer(
    overrides: [
      authProvider.overrideWith(
        () => FakeLoggedInAuthNotifier(
          const AuthState(
            isLoggedIn: true,
            userId: 'my-user-id',
            username: 'testuser',
            token: 'fake-token',
          ),
        ),
      ),
      serverUrlProvider.overrideWith(
        () => FakeServerUrlNotifier('http://localhost:8080'),
      ),
      cryptoServiceProvider.overrideWithValue(_FakeCryptoService()),
      groupCryptoServiceProvider.overrideWithValue(_FakeGroupCryptoService()),
      cryptoProvider.overrideWith(
        () => _SeededCryptoNotifier(const CryptoState(isInitialized: false)),
      ),
      conversationsProvider.overrideWith(_FakeConversationsNotifier.new),
      channelsProvider.overrideWith(() => _FakeChannelsNotifier()),
    ],
  );
  _handler = _container.read(_testHandlerProvider.notifier);
}

const _myUserId = 'my-user-id';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory hiveTempDir;

  setUpAll(() async {
    hiveTempDir = await Directory.systemTemp.createTemp('ws_replay_hive_');
    Hive.init(hiveTempDir.path);
    await MessageCache.init();
  });

  tearDownAll(() async {
    await Hive.close();
    try {
      await hiveTempDir.delete(recursive: true);
    } catch (_) {}
  });

  setUp(() {
    SharedPreferences.setMockInitialValues({});
    _setup();
  });

  tearDown(() {
    _container.dispose();
  });

  // -----------------------------------------------------------------------
  // #26 — replay suppression: cached messages must not re-bump unread count
  // or re-fire notifications on re-login.
  // -----------------------------------------------------------------------

  group('#26 replay suppression via isMessageCachedSync', () {
    setUp(() async {
      // Scope the Hive cache to the test user so boxes are isolated.
      await MessageCache.initForUser(_myUserId, 'localhost');
    });

    test('new message (not in cache) is added to chat state normally', () {
      // No message pre-cached → alreadySeen = false → message delivered.
      _handler.handleServerMessage({
        'type': 'new_message',
        'message_id': 'msg-replay-new-1',
        'from_user_id': _myUserId, // self → no notification path
        'from_username': 'testuser',
        'conversation_id': 'conv-1',
        'content': 'brand new message',
        'timestamp': '2026-01-01T10:00:00Z',
      }, _myUserId);

      final chatNotifier = _container.read(chatProvider.notifier);
      final msgs = chatNotifier.state.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.content, 'brand new message');
    });

    test(
      'replayed message (already in cache) does not bump unread count',
      () async {
        // Pre-cache the message so isMessageCachedSync returns true.
        await MessageCache.cacheMessages('conv-1', [
          const ChatMessage(
            id: 'msg-replay-conv1',
            fromUserId: _myUserId, // self — avoids notification sound
            fromUsername: 'testuser',
            conversationId: 'conv-1',
            content: 'previously seen',
            timestamp: '2026-01-01T09:00:00Z',
            isMine: true,
          ),
        ]);

        // The sync check must now return true.
        expect(
          MessageCache.isMessageCachedSync('conv-1', 'msg-replay-conv1'),
          isTrue,
          reason: 'precondition: message must be in the open Hive box',
        );

        // Record unread count BEFORE the replayed message arrives.
        // Seed a prior message to give conv-1 a baseline unread count.
        final convsNotifier = _container.read(conversationsProvider.notifier);
        convsNotifier.onNewMessage(
          conversationId: 'conv-1',
          content: 'prior message',
          senderUsername: 'alice',
          timestamp: '2026-01-01T08:00:00Z',
        );
        final unreadBefore = _container
            .read(conversationsProvider)
            .conversations
            .firstWhere((c) => c.id == 'conv-1')
            .unreadCount;

        // Deliver the replayed message (it's already in the Hive cache).
        _handler.handleServerMessage({
          'type': 'new_message',
          'message_id': 'msg-replay-conv1',
          'from_user_id': _myUserId, // self — no notification fired
          'from_username': 'testuser',
          'conversation_id': 'conv-1',
          'content': 'previously seen',
          'timestamp': '2026-01-01T09:00:00Z',
        }, _myUserId);

        final unreadAfter = _container
            .read(conversationsProvider)
            .conversations
            .firstWhere((c) => c.id == 'conv-1')
            .unreadCount;

        // Unread count must NOT increase for the replayed message.
        expect(
          unreadAfter,
          equals(unreadBefore),
          reason: 'replayed offline message must not bump unread count (#26)',
        );
      },
    );

    test('isMessageCachedSync returns false when box is not yet open', () {
      // A conversation box that has never been accessed is not open.
      expect(
        MessageCache.isMessageCachedSync('conv-never-opened', 'any-id'),
        isFalse,
      );
    });
  });
}
