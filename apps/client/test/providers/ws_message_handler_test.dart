import 'dart:async';

import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
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

// ---------------------------------------------------------------------------
// Fakes
// ---------------------------------------------------------------------------

class _FakeCryptoService extends CryptoService {
  final Set<String> invalidatedSessions = {};

  _FakeCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  bool get isInitialized => false;

  @override
  Future<void> invalidateSessionKey(String peerUserId) async {
    invalidatedSessions.add(peerUserId);
  }
}

class _FakeGroupCryptoService extends GroupCryptoService {
  final Set<String> invalidatedCaches = {};

  _FakeGroupCryptoService() : super(serverUrl: 'http://localhost:8080');

  @override
  Future<void> invalidateCache(String conversationId) async {
    invalidatedCaches.add(conversationId);
  }

  @override
  Future<(int, String)?> fetchGroupKey(String conversationId) async => null;
}

class _FakeChannelsNotifier extends ChannelsNotifier {
  final List<String> loadedChannels = [];
  final List<String> loadedVoiceSessions = [];

  _FakeChannelsNotifier(super.ref);

  @override
  Future<void> loadChannels(String conversationId) async {
    loadedChannels.add(conversationId);
  }

  @override
  Future<void> loadVoiceSessions(
    String conversationId,
    String channelId,
  ) async {
    loadedVoiceSessions.add('$conversationId:$channelId');
  }
}

class _FakeConversationsNotifier extends ConversationsNotifier {
  _FakeConversationsNotifier(super.ref) {
    state = const ConversationsState(
      conversations: [
        Conversation(
          id: 'conv-1',
          isGroup: false,
          members: [
            ConversationMember(userId: 'peer-1', username: 'alice'),
            ConversationMember(userId: 'my-user-id', username: 'testuser'),
          ],
        ),
        Conversation(
          id: 'group-1',
          isGroup: true,
          name: 'Test Group',
          members: [
            ConversationMember(
              userId: 'my-user-id',
              username: 'testuser',
              role: 'owner',
            ),
            ConversationMember(
              userId: 'peer-1',
              username: 'alice',
              role: 'member',
            ),
          ],
        ),
      ],
    );
  }

  @override
  Future<void> loadConversations() async {}
}

// ---------------------------------------------------------------------------
// Concrete handler for testing
// ---------------------------------------------------------------------------

class _TestWsHandler extends StateNotifier<WebSocketState>
    with WsMessageHandler {
  @override
  final Ref ref;

  @override
  final StreamController<Map<String, dynamic>> voiceSignalController =
      StreamController<Map<String, dynamic>>.broadcast();

  @override
  final StreamController<Map<String, dynamic>> deviceRevokedController =
      StreamController<Map<String, dynamic>>.broadcast();

  _TestWsHandler(this.ref) : super(const WebSocketState());
}

final _testHandlerProvider =
    StateNotifierProvider<_TestWsHandler, WebSocketState>(
      (ref) => _TestWsHandler(ref),
    );

// ---------------------------------------------------------------------------
// Test setup
// ---------------------------------------------------------------------------

// ignore_for_file: library_private_types_in_public_api
late ProviderContainer container;
late _TestWsHandler handler;
late _FakeCryptoService fakeCrypto;
late _FakeGroupCryptoService fakeGroupCrypto;
late _FakeChannelsNotifier fakeChannels;

void _setup() {
  fakeCrypto = _FakeCryptoService();
  fakeGroupCrypto = _FakeGroupCryptoService();

  container = ProviderContainer(
    overrides: [
      authProvider.overrideWith((ref) {
        final n = AuthNotifier(ref);
        n.state = const AuthState(
          isLoggedIn: true,
          userId: 'my-user-id',
          username: 'testuser',
          token: 'fake-token',
        );
        return n;
      }),
      serverUrlProvider.overrideWith((ref) {
        final n = ServerUrlNotifier();
        n.state = 'http://localhost:8080';
        return n;
      }),
      cryptoServiceProvider.overrideWithValue(fakeCrypto),
      groupCryptoServiceProvider.overrideWithValue(fakeGroupCrypto),
      cryptoProvider.overrideWith((ref) {
        final n = CryptoNotifier(ref);
        // Default: crypto NOT initialized (for new_message queue tests)
        n.state = const CryptoState(isInitialized: false);
        return n;
      }),
      conversationsProvider.overrideWith(
        (ref) => _FakeConversationsNotifier(ref),
      ),
      channelsProvider.overrideWith((ref) {
        fakeChannels = _FakeChannelsNotifier(ref);
        return fakeChannels;
      }),
    ],
  );

  handler = container.read(_testHandlerProvider.notifier);
}

const _myUserId = 'my-user-id';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    _setup();
  });

  tearDown(() {
    container.dispose();
  });

  // -----------------------------------------------------------------------
  // WebSocketState model tests (existing)
  // -----------------------------------------------------------------------

  group('WebSocketState', () {
    test('default state is disconnected', () {
      const state = WebSocketState();
      expect(state.isConnected, isFalse);
      expect(state.reconnectAttempts, 0);
      expect(state.typingUsers, isEmpty);
      expect(state.onlineUsers, isEmpty);
      expect(state.wasReplaced, isFalse);
    });

    test('copyWith preserves unchanged fields', () {
      const state = WebSocketState(
        isConnected: true,
        reconnectAttempts: 3,
        onlineUsers: {'user-1', 'user-2'},
      );
      final copied = state.copyWith(isConnected: false);
      expect(copied.isConnected, isFalse);
      expect(copied.reconnectAttempts, 3);
      expect(copied.onlineUsers, hasLength(2));
    });

    test('isUserOnline returns correct status', () {
      const state = WebSocketState(onlineUsers: {'user-1', 'user-3'});
      expect(state.isUserOnline('user-1'), isTrue);
      expect(state.isUserOnline('user-2'), isFalse);
    });

    test('typingIn returns usernames with recent timestamps', () {
      final now = DateTime.now();
      final state = WebSocketState(
        typingUsers: {
          'conv-1:': {
            'alice': now.subtract(const Duration(seconds: 2)),
            'bob': now.subtract(const Duration(seconds: 10)),
          },
        },
      );
      final typing = state.typingIn('conv-1');
      expect(typing, contains('alice'));
      expect(typing, isNot(contains('bob')));
    });

    test('typingIn supports channel-specific typing', () {
      final now = DateTime.now();
      final state = WebSocketState(
        typingUsers: {
          'conv-1:ch-1': {'alice': now},
          'conv-1:': {'bob': now},
        },
      );
      expect(state.typingIn('conv-1', channelId: 'ch-1'), contains('alice'));
      expect(state.typingIn('conv-1'), contains('bob'));
    });
  });

  // -----------------------------------------------------------------------
  // Event dispatch tests
  // -----------------------------------------------------------------------

  group('handleServerMessage: presence', () {
    test('adds user on online status', () {
      handler.handleServerMessage({
        'type': 'presence',
        'user_id': 'user-1',
        'status': 'online',
      }, _myUserId);

      expect(handler.state.isUserOnline('user-1'), isTrue);
    });

    test('removes user on offline status', () {
      handler.handleServerMessage({
        'type': 'presence',
        'user_id': 'user-1',
        'status': 'online',
      }, _myUserId);
      handler.handleServerMessage({
        'type': 'presence',
        'user_id': 'user-1',
        'status': 'offline',
      }, _myUserId);

      expect(handler.state.isUserOnline('user-1'), isFalse);
    });

    test('ignores empty user_id', () {
      handler.handleServerMessage({
        'type': 'presence',
        'user_id': '',
        'status': 'online',
      }, _myUserId);

      expect(handler.state.onlineUsers, isEmpty);
    });
  });

  group('handleServerMessage: presence_list', () {
    test('replaces onlineUsers set', () {
      handler.handleServerMessage({
        'type': 'presence_list',
        'users': ['u1', 'u2', 'u3'],
      }, _myUserId);

      expect(handler.state.onlineUsers, {'u1', 'u2', 'u3'});
    });

    test('handles empty list', () {
      handler.handleServerMessage({
        'type': 'presence_list',
        'users': <String>[],
      }, _myUserId);

      expect(handler.state.onlineUsers, isEmpty);
    });
  });

  group('handleServerMessage: typing', () {
    test('adds typing indicator for other user', () {
      handler.handleServerMessage({
        'type': 'typing',
        'conversation_id': 'conv-1',
        'from_user_id': 'peer-1',
        'from_username': 'alice',
      }, _myUserId);

      expect(handler.state.typingIn('conv-1'), contains('alice'));
    });

    test('ignores own typing indicator', () {
      handler.handleServerMessage({
        'type': 'typing',
        'conversation_id': 'conv-1',
        'from_user_id': _myUserId,
        'from_username': 'testuser',
      }, _myUserId);

      expect(handler.state.typingIn('conv-1'), isEmpty);
    });

    test('supports channel-specific typing', () {
      handler.handleServerMessage({
        'type': 'typing',
        'conversation_id': 'conv-1',
        'channel_id': 'ch-1',
        'from_user_id': 'peer-1',
        'from_username': 'alice',
      }, _myUserId);

      expect(
        handler.state.typingIn('conv-1', channelId: 'ch-1'),
        contains('alice'),
      );
      expect(handler.state.typingIn('conv-1'), isEmpty);
    });
  });

  group('handleServerMessage: session_replaced', () {
    test('sets wasReplaced and disconnects', () {
      handler.handleServerMessage({
        'type': 'session_replaced',
        'reason': 'Signed in on another device',
      }, _myUserId);

      expect(handler.state.wasReplaced, isTrue);
      expect(handler.state.isConnected, isFalse);
    });
  });

  group('handleServerMessage: message_sent', () {
    test('confirms pending message with server ID', () {
      // Add a pending message first.
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addOptimistic(
        'peer-1',
        'Hello',
        _myUserId,
        conversationId: 'conv-1',
      );
      final pendingId = chatNotifier.state
          .messagesForConversation('conv-1')
          .first
          .id;
      expect(pendingId, startsWith('pending_'));

      handler.handleServerMessage({
        'type': 'message_sent',
        'message_id': 'server-123',
        'conversation_id': 'conv-1',
        'timestamp': '2026-01-01T12:00:00Z',
      }, _myUserId);

      final msgs = chatNotifier.state.messagesForConversation('conv-1');
      expect(msgs.first.id, 'server-123');
      expect(msgs.first.status, MessageStatus.sent);
    });
  });

  group('handleServerMessage: delivered', () {
    test('updates message status to delivered', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        const ChatMessage(
          id: 'msg-1',
          fromUserId: 'my-user-id',
          fromUsername: 'testuser',
          conversationId: 'conv-1',
          content: 'Hello',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: true,
        ),
      );

      handler.handleServerMessage({
        'type': 'delivered',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
      }, _myUserId);

      final msg = chatNotifier.state.messagesForConversation('conv-1').first;
      expect(msg.status, MessageStatus.delivered);
    });
  });

  group('handleServerMessage: read_receipt', () {
    test('marks own messages as read', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        const ChatMessage(
          id: 'msg-1',
          fromUserId: 'my-user-id',
          fromUsername: 'testuser',
          conversationId: 'conv-1',
          content: 'Hello',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: true,
        ),
      );

      handler.handleServerMessage({
        'type': 'read_receipt',
        'conversation_id': 'conv-1',
      }, _myUserId);

      final msg = chatNotifier.state.messagesForConversation('conv-1').first;
      expect(msg.status, MessageStatus.read);
    });
  });

  group('handleServerMessage: message_deleted', () {
    test('removes message from chat', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        const ChatMessage(
          id: 'msg-1',
          fromUserId: 'peer-1',
          fromUsername: 'alice',
          conversationId: 'conv-1',
          content: 'To be deleted',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: false,
        ),
      );

      handler.handleServerMessage({
        'type': 'message_deleted',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
      }, _myUserId);

      expect(chatNotifier.state.messagesForConversation('conv-1'), isEmpty);
    });
  });

  group('handleServerMessage: message_edited', () {
    test('updates message content', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        const ChatMessage(
          id: 'msg-1',
          fromUserId: 'peer-1',
          fromUsername: 'alice',
          conversationId: 'conv-1',
          content: 'Original',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: false,
        ),
      );

      handler.handleServerMessage({
        'type': 'message_edited',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
        'content': 'Edited content',
        'edited_at': '2026-01-01T01:00:00Z',
      }, _myUserId);

      final msg = chatNotifier.state.messagesForConversation('conv-1').first;
      expect(msg.content, 'Edited content');
      expect(msg.editedAt, '2026-01-01T01:00:00Z');
    });
  });

  group('handleServerMessage: message_pinned / message_unpinned', () {
    test('pins a message', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        const ChatMessage(
          id: 'msg-1',
          fromUserId: 'peer-1',
          fromUsername: 'alice',
          conversationId: 'conv-1',
          content: 'Pin me',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: false,
        ),
      );

      handler.handleServerMessage({
        'type': 'message_pinned',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
        'pinned_by_id': 'peer-1',
        'pinned_at': '2026-01-01T02:00:00Z',
      }, _myUserId);

      final msg = chatNotifier.state.messagesForConversation('conv-1').first;
      expect(msg.pinnedById, 'peer-1');
      expect(msg.pinnedAt, isNotNull);
    });

    test('unpins a message', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        ChatMessage(
          id: 'msg-1',
          fromUserId: 'peer-1',
          fromUsername: 'alice',
          conversationId: 'conv-1',
          content: 'Pinned',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: false,
          pinnedById: 'peer-1',
          pinnedAt: DateTime(2026, 1, 1),
        ),
      );

      handler.handleServerMessage({
        'type': 'message_unpinned',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
      }, _myUserId);

      final msg = chatNotifier.state.messagesForConversation('conv-1').first;
      expect(msg.pinnedById, isNull);
    });
  });

  group('handleServerMessage: reaction', () {
    test('adds a reaction', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        const ChatMessage(
          id: 'msg-1',
          fromUserId: 'peer-1',
          fromUsername: 'alice',
          conversationId: 'conv-1',
          content: 'React to me',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: false,
        ),
      );

      handler.handleServerMessage({
        'type': 'reaction',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
        'user_id': 'peer-2',
        'username': 'bob',
        'emoji': '👍',
      }, _myUserId);

      final msg = chatNotifier.state.messagesForConversation('conv-1').first;
      expect(msg.reactions, hasLength(1));
      expect(msg.reactions.first.emoji, '👍');
    });

    test('removes a reaction', () {
      final chatNotifier = container.read(chatProvider.notifier);
      chatNotifier.addMessage(
        const ChatMessage(
          id: 'msg-1',
          fromUserId: 'peer-1',
          fromUsername: 'alice',
          conversationId: 'conv-1',
          content: 'Reacted',
          timestamp: '2026-01-01T00:00:00Z',
          isMine: false,
        ),
      );
      // First add a reaction via handler.
      handler.handleServerMessage({
        'type': 'reaction',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
        'user_id': 'peer-2',
        'username': 'bob',
        'emoji': '👍',
      }, _myUserId);

      // Then remove it.
      handler.handleServerMessage({
        'type': 'reaction',
        'action': 'remove',
        'conversation_id': 'conv-1',
        'message_id': 'msg-1',
        'user_id': 'peer-2',
        'username': 'bob',
        'emoji': '👍',
      }, _myUserId);

      final msg = chatNotifier.state.messagesForConversation('conv-1').first;
      expect(msg.reactions, isEmpty);
    });
  });

  group('handleServerMessage: key_reset', () {
    test('invalidates session and adds system event', () {
      handler.handleServerMessage({
        'type': 'key_reset',
        'from_user_id': 'peer-1',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
      }, _myUserId);

      expect(fakeCrypto.invalidatedSessions, contains('peer-1'));

      final chatNotifier = container.read(chatProvider.notifier);
      final msgs = chatNotifier.state.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.isSystemEvent, isTrue);
      expect(msgs.first.content, 'alice reset their encryption keys');
    });
  });

  group('handleServerMessage: voice_signal', () {
    test('pushes signal to stream', () async {
      final completer = Completer<Map<String, dynamic>>();
      handler.voiceSignalController.stream.first.then(completer.complete);

      handler.handleServerMessage({
        'type': 'voice_signal',
        'from_user_id': 'peer-1',
        'signal_data': 'some-sdp',
      }, _myUserId);

      final signal = await completer.future;
      expect(signal['from_user_id'], 'peer-1');
    });
  });

  group('handleServerMessage: call_started', () {
    test('adds system event', () {
      handler.handleServerMessage({
        'type': 'call_started',
        'from_username': 'alice',
        'conversation_id': 'conv-1',
      }, _myUserId);

      final chatNotifier = container.read(chatProvider.notifier);
      final msgs = chatNotifier.state.messagesForConversation('conv-1');
      expect(
        msgs.any((m) => m.content.contains('started a voice call')),
        isTrue,
      );
    });
  });

  group('handleServerMessage: new_message (crypto not initialized)', () {
    test('adds placeholder and queues for later decryption', () {
      // Use own user ID as sender to skip _notifyIfAllowed (SoundService
      // can't initialize in test environment).
      handler.handleServerMessage({
        'type': 'new_message',
        'message_id': 'msg-1',
        'from_user_id': _myUserId,
        'from_username': 'testuser',
        'conversation_id': 'conv-1',
        'content': 'some encrypted content',
        'timestamp': '2026-01-01T10:00:00Z',
      }, _myUserId);

      final chatNotifier = container.read(chatProvider.notifier);
      final msgs = chatNotifier.state.messagesForConversation('conv-1');
      expect(msgs, hasLength(1));
      expect(msgs.first.content, 'Securing message...');
    });
  });

  group('handleServerMessage: channel events', () {
    test('channel_created triggers channel reload', () {
      handler.handleServerMessage({
        'type': 'channel_created',
        'group_id': 'group-1',
      }, _myUserId);

      expect(fakeChannels.loadedChannels, contains('group-1'));
    });

    test('voice_session_joined triggers voice session reload', () {
      handler.handleServerMessage({
        'type': 'voice_session_joined',
        'group_id': 'group-1',
        'channel_id': 'ch-1',
      }, _myUserId);

      expect(fakeChannels.loadedVoiceSessions, contains('group-1:ch-1'));
    });
  });

  group('handleServerMessage: group_key_rotated', () {
    test('invalidates group key cache', () {
      handler.handleServerMessage({
        'type': 'group_key_rotated',
        'conversation_id': 'group-1',
      }, _myUserId);

      expect(fakeGroupCrypto.invalidatedCaches, contains('group-1'));
    });
  });

  group('handleServerMessage: heartbeat / error', () {
    test('heartbeat does not crash', () {
      handler.handleServerMessage({'type': 'heartbeat'}, _myUserId);
      // No assertion — just verifying no exception.
    });

    test('error does not crash', () {
      handler.handleServerMessage({
        'type': 'error',
        'message': 'something went wrong',
      }, _myUserId);
    });

    test('unknown type does not crash', () {
      handler.handleServerMessage({
        'type': 'completely_unknown_type',
      }, _myUserId);
    });
  });

  // #660 — group member list real-time update via WS
  group('handleServerMessage: member_added', () {
    test('appends new member to group conversation', () {
      handler.handleServerMessage({
        'type': 'member_added',
        'conversation_id': 'group-1',
        'user_id': 'peer-2',
        'username': 'charlie',
        'avatar_url': null,
        'role': 'member',
      }, _myUserId);

      final convs = container.read(conversationsProvider).conversations;
      final group = convs.firstWhere((c) => c.id == 'group-1');
      expect(group.members.map((m) => m.userId), contains('peer-2'));
      expect(
        group.members.firstWhere((m) => m.userId == 'peer-2').username,
        'charlie',
      );
    });

    test('does not duplicate an existing member', () {
      // alice (peer-1) is already in group-1
      handler.handleServerMessage({
        'type': 'member_added',
        'conversation_id': 'group-1',
        'user_id': 'peer-1',
        'username': 'alice',
        'role': 'member',
      }, _myUserId);

      final convs = container.read(conversationsProvider).conversations;
      final group = convs.firstWhere((c) => c.id == 'group-1');
      expect(group.members.where((m) => m.userId == 'peer-1'), hasLength(1));
    });

    test('ignores event with missing conversation_id', () {
      // Should not throw and should leave state unchanged.
      handler.handleServerMessage({
        'type': 'member_added',
        'conversation_id': '',
        'user_id': 'peer-3',
        'username': 'dave',
        'role': 'member',
      }, _myUserId);

      final convs = container.read(conversationsProvider).conversations;
      final group = convs.firstWhere((c) => c.id == 'group-1');
      expect(group.members, hasLength(2)); // unchanged
    });
  });
}
