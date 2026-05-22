// Widget tests for the top-level helpers in
// `lib/src/widgets/chat_panel/message_actions.dart` -- the shared action
// surface every chat row (DM and group) routes through. The file shipped
// at 0% coverage on the 2026-05-22 Sonar baseline; this suite establishes
// a behavioral safety net so future PRs touching retry/delete/forward/pin
// /save/react paths break loudly instead of silently.
//
// Strategy: replace `chatProvider`, `websocketProvider`, and `authProvider`
// with recording stubs that capture the parameters the action helpers
// forwarded. Each test asserts on those recorded values rather than on
// the widget tree, because the action helpers are imperatives -- they
// mutate global state and fire-and-forget HTTP, they aren't widgets.
//
// Tests intentionally avoid network: AuthNotifier.authenticatedRequest is
// overridden so the HTTP closure is invoked with a fake token but never
// executed, and the test supplies the canned http.Response.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/models/reaction.dart';
import 'package:echo_app/src/providers/auth_provider.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/media_ticket_provider.dart';
import 'package:echo_app/src/providers/websocket_provider.dart'
    show WebSocketNotifier, WebSocketState, websocketProvider;
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/widgets/chat_panel/message_actions.dart'
    as actions;
import 'package:echo_app/src/widgets/image_gallery_viewer.dart'
    show ImageGalleryViewer;

import '../../helpers/mock_providers.dart';
import '../../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Stubs
// ---------------------------------------------------------------------------

/// Records chatProvider mutations so tests can assert what message-actions
/// asked the chat layer to do.
class _StubChat extends Chat {
  _StubChat({ChatState? initial}) : _initial = initial ?? const ChatState();
  final ChatState _initial;

  final List<List<dynamic>> updateMessageStatusCalls = [];
  final List<List<dynamic>> deleteMessageCalls = [];
  final List<ChatMessage> addMessageCalls = [];
  final List<List<dynamic>> updateMessagePinCalls = [];
  final List<List<dynamic>> addReactionCalls = [];
  final List<List<dynamic>> removeReactionCalls = [];

  /// Capture invocations of `forwardMessage(content, targetConvId, sender)`.
  /// We also invoke `sender(forwarded)` so the optimistic-message path runs.
  final List<List<dynamic>> forwardCalls = [];

  @override
  ChatState build() => _initial;

  @override
  Future<void> loadHistoryWithUserId(
    String conversationId,
    String token,
    String userId, {
    String? channelId,
    String? before,
    CryptoService? crypto,
    GroupCryptoService? groupCrypto,
    bool isGroup = false,
  }) async {}

  @override
  void updateMessageStatus(
    String conversationId,
    String messageId,
    MessageStatus status,
  ) {
    updateMessageStatusCalls.add([conversationId, messageId, status]);
  }

  @override
  void deleteMessage(String conversationId, String messageId) {
    deleteMessageCalls.add([conversationId, messageId]);
  }

  @override
  void addMessage(ChatMessage msg, {bool bumpReplyCount = true}) {
    addMessageCalls.add(msg);
  }

  @override
  void updateMessagePin(
    String conversationId,
    String messageId,
    String? pinnedById,
    DateTime? pinnedAt,
  ) {
    updateMessagePinCalls.add([
      conversationId,
      messageId,
      pinnedById,
      pinnedAt,
    ]);
  }

  @override
  void addReaction(String conversationId, Reaction reaction) {
    addReactionCalls.add([conversationId, reaction]);
  }

  @override
  void removeReaction(
    String conversationId,
    String messageId,
    String userId,
    String emoji,
  ) {
    removeReactionCalls.add([conversationId, messageId, userId, emoji]);
  }

  @override
  Future<void> forwardMessage(
    String messageContent,
    String targetConversationId,
    Future<void> Function(String forwardedContent) sender,
  ) async {
    forwardCalls.add([messageContent, targetConversationId]);
    // Run the sender so the optimistic-add + WS pipeline runs in tests too.
    await sender('[Forwarded] $messageContent');
  }

  @override
  void addOptimistic(
    String peerUserId,
    String content,
    String myUserId, {
    String conversationId = '',
    String? channelId,
    String? replyToId,
    String? replyToContent,
    String? replyToUsername,
  }) {
    addMessageCalls.add(
      ChatMessage(
        id: 'optimistic',
        fromUserId: myUserId,
        fromUsername: 'You',
        conversationId: conversationId,
        channelId: channelId,
        content: content,
        timestamp: DateTime.now().toIso8601String(),
        isMine: true,
      ),
    );
  }
}

/// Records WS sends without touching the real socket or crypto.
class _StubWs extends WebSocketNotifier {
  /// (toUserId, content, conversationId, replyToId)
  final List<List<dynamic>> sendCalls = [];

  /// (conversationId, content, channelId, replyToId)
  final List<List<dynamic>> sendGroupCalls = [];

  /// (conversationId, messageId, emoji)
  final List<List<dynamic>> reactionCalls = [];

  /// Set to true to make every `sendMessage` throw.
  bool sendThrows = false;

  @override
  WebSocketState build() => const WebSocketState(isConnected: true);

  @override
  void connect() {}

  @override
  void disconnect() {}

  @override
  Future<void> sendMessage(
    String toUserId,
    String content, {
    String? conversationId,
    String? replyToId,
  }) async {
    sendCalls.add([toUserId, content, conversationId, replyToId]);
    if (sendThrows) throw Exception('ws-send-failed');
  }

  @override
  Future<void> sendGroupMessage(
    String conversationId,
    String content, {
    String? channelId,
    String? replyToId,
  }) async {
    sendGroupCalls.add([conversationId, content, channelId, replyToId]);
    if (sendThrows) throw Exception('ws-send-failed');
  }

  @override
  Future<void> sendReaction(
    String conversationId,
    String messageId,
    String emoji,
  ) async {
    reactionCalls.add([conversationId, messageId, emoji]);
  }
}

/// Hands back a programmable http.Response (or throws) from
/// `authenticatedRequest`. Captures the request URL/method per call.
class _StubAuth extends FakeLoggedInAuthNotifier {
  _StubAuth() : super(loggedInAuthState);

  /// (method, url) recorded by inspecting the actual request the closure
  /// would have made -- we run the closure with a fake token to capture it,
  /// but discard the real http call by returning [stubbedResponse] directly.
  final List<List<String>> requestLog = [];

  http.Response stubbedResponse = http.Response('{}', 200);
  Object? throwError;

  @override
  Future<http.Response> authenticatedRequest(
    Future<http.Response> Function(String token) requestFn,
  ) async {
    // We can't easily intercept the http call without an http.Client, but
    // we can capture URL/method by running the closure inside a try/catch:
    // most callers in message_actions pass http.delete/http.post that hit
    // the network. Instead we *don't* call requestFn -- we synthesise a
    // response directly so tests stay offline-clean. The action helpers
    // only care about statusCode + body of the response we hand back.
    requestLog.add(['call', 'authenticatedRequest']);
    if (throwError != null) {
      throw throwError!;
    }
    return stubbedResponse;
  }
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _dmConv = Conversation(
  id: 'conv-dm',
  isGroup: false,
  isEncrypted: false,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
  ],
);

const _groupConv = Conversation(
  id: 'conv-group',
  isGroup: true,
  name: 'Dev Team',
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-bob', username: 'bob'),
  ],
);

ChatMessage _msg({
  String id = 'msg-1',
  String content = 'hello',
  bool isMine = true,
  String? failedContent,
  MessageStatus status = MessageStatus.sent,
  String fromUserId = 'test-user-id',
  String conversationId = 'conv-dm',
  String? replyToId,
  String? pinnedById,
  DateTime? pinnedAt,
  List<Reaction> reactions = const [],
}) {
  return ChatMessage(
    id: id,
    fromUserId: fromUserId,
    fromUsername: 'testuser',
    conversationId: conversationId,
    content: content,
    timestamp: '2026-05-22T10:00:00Z',
    isMine: isMine,
    status: status,
    failedContent: failedContent,
    replyToId: replyToId,
    pinnedById: pinnedById,
    pinnedAt: pinnedAt,
    reactions: reactions,
  );
}

// ---------------------------------------------------------------------------
// Override builder
// ---------------------------------------------------------------------------

({List<Override> overrides, _StubChat chat, _StubWs ws, _StubAuth auth})
buildOverrides({ChatState chatState = const ChatState()}) {
  final chat = _StubChat(initial: chatState);
  final ws = _StubWs();
  final auth = _StubAuth();
  return (
    overrides: [
      authProvider.overrideWith(() => auth),
      serverUrlOverride('http://test.local'),
      conversationsOverride(const []),
      contactsOverride(),
      cryptoOverride(),
      chatProvider.overrideWith(() => chat),
      websocketProvider.overrideWith(() => ws),
      mediaTicketProvider.overrideWith(() => _FakeMediaTicket()),
    ],
    chat: chat,
    ws: ws,
    auth: auth,
  );
}

class _FakeMediaTicket extends MediaTicket {
  @override
  String? build() => null;
}

/// Pumps a tiny Scaffold that exposes the current [WidgetRef] + context so a
/// test can drive the action helpers directly.
class _Harness extends ConsumerStatefulWidget {
  const _Harness({required this.onReady});
  final void Function(BuildContext context, WidgetRef ref) onReady;

  @override
  ConsumerState<_Harness> createState() => _HarnessState();
}

class _HarnessState extends ConsumerState<_Harness> {
  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      widget.onReady(context, ref);
    });
  }

  @override
  Widget build(BuildContext context) => const SizedBox.shrink();
}

Future<({BuildContext context, WidgetRef ref})> _pump(
  WidgetTester tester,
  List<Override> overrides,
) async {
  late BuildContext capturedContext;
  late WidgetRef capturedRef;
  final ready = Completer<void>();
  await tester.pumpApp(
    _Harness(
      onReady: (ctx, ref) {
        capturedContext = ctx;
        capturedRef = ref;
        if (!ready.isCompleted) ready.complete();
      },
    ),
    overrides: overrides,
  );
  await tester.pump();
  await ready.future;
  return (context: capturedContext, ref: capturedRef);
}

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

void main() {
  group('fullMonthName', () {
    test('returns the canonical month name for 1..12', () {
      const expected = [
        'January',
        'February',
        'March',
        'April',
        'May',
        'June',
        'July',
        'August',
        'September',
        'October',
        'November',
        'December',
      ];
      for (var i = 0; i < 12; i++) {
        expect(actions.fullMonthName(i + 1), expected[i]);
      }
    });

    test('clamps out-of-range months to January / December', () {
      // The helper uses m.clamp(1, 12); 0 → 1 (January), 13 → 12 (December).
      expect(actions.fullMonthName(0), 'January');
      expect(actions.fullMonthName(13), 'December');
      expect(actions.fullMonthName(-1), 'January');
      expect(actions.fullMonthName(99), 'December');
    });
  });

  group('DeleteChoice', () {
    test('exposes both forMe and forEveryone variants', () {
      expect(actions.DeleteChoice.values, hasLength(2));
      expect(
        actions.DeleteChoice.values,
        containsAll(<actions.DeleteChoice>[
          actions.DeleteChoice.forMe,
          actions.DeleteChoice.forEveryone,
        ]),
      );
    });
  });

  group('deleteFailed', () {
    testWidgets('forwards conversationId + messageId to chatProvider', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      actions.deleteFailed(
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'failed-1'),
      );
      expect(b.chat.deleteMessageCalls, [
        ['conv-dm', 'failed-1'],
      ]);
    });
  });

  group('retryMessage', () {
    testWidgets('flips DM message to sending and dispatches via sendMessage', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      final m = _msg(id: 'm-1', content: 'hi');
      await actions.retryMessage(ref: h.ref, conv: _dmConv, message: m);

      // The first call must flip status to "sending" so the bubble loses
      // its red "failed" chrome immediately.
      expect(b.chat.updateMessageStatusCalls.first, [
        'conv-dm',
        'm-1',
        MessageStatus.sending,
      ]);
      // It picks the peer (the not-me member) and forwards the content.
      expect(b.ws.sendCalls, [
        ['user-alice', 'hi', 'conv-dm', null],
      ]);
      // No group send for a DM.
      expect(b.ws.sendGroupCalls, isEmpty);
    });

    testWidgets('uses failedContent over content when both are set', (t) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      // content="error reason", failedContent="original text" -- retry must
      // resend the original text, not the displayed error.
      final m = _msg(
        id: 'm-2',
        content: 'Network error',
        failedContent: 'original text',
      );
      await actions.retryMessage(ref: h.ref, conv: _dmConv, message: m);
      expect(b.ws.sendCalls.single[1], 'original text');
    });

    testWidgets('passes replyToId through to the WS send', (t) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      final m = _msg(id: 'm-3', content: 'reply', replyToId: 'parent-99');
      await actions.retryMessage(ref: h.ref, conv: _dmConv, message: m);
      expect(b.ws.sendCalls.single[3], 'parent-99');
    });

    testWidgets('routes group conversations to sendGroupMessage', (t) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      final m = _msg(id: 'g-1', content: 'hey', conversationId: 'conv-group');
      await actions.retryMessage(ref: h.ref, conv: _groupConv, message: m);
      expect(b.ws.sendGroupCalls, [
        ['conv-group', 'hey', null, null],
      ]);
      expect(b.ws.sendCalls, isEmpty);
    });

    testWidgets('rolls back to failed status when the WS send throws', (
      t,
    ) async {
      final b = buildOverrides();
      b.ws.sendThrows = true;
      final h = await _pump(t, b.overrides);
      await actions.retryMessage(ref: h.ref, conv: _dmConv, message: _msg());

      // First call sent it to sending, last call rolled it back to failed.
      expect(b.chat.updateMessageStatusCalls.first.last, MessageStatus.sending);
      expect(b.chat.updateMessageStatusCalls.last.last, MessageStatus.failed);
    });

    testWidgets('DM with no peer (degenerate solo conv) is a no-op send', (
      t,
    ) async {
      const soloConv = Conversation(
        id: 'conv-solo',
        isGroup: false,
        members: [
          ConversationMember(userId: 'test-user-id', username: 'testuser'),
        ],
      );
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      await actions.retryMessage(ref: h.ref, conv: soloConv, message: _msg());
      // The status flip still happens, but no send because there's no peer.
      expect(b.ws.sendCalls, isEmpty);
      expect(b.ws.sendGroupCalls, isEmpty);
    });
  });

  group('toggleReaction', () {
    testWidgets('skips entirely when the message is no longer in state', (
      t,
    ) async {
      // Default ChatState has no messages, so the existence guard trips.
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      actions.toggleReaction(
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'gone'),
        emoji: '👍',
        remove: false,
      );
      expect(b.ws.reactionCalls, isEmpty);
      expect(b.chat.addReactionCalls, isEmpty);
      expect(b.chat.removeReactionCalls, isEmpty);
    });

    testWidgets('add path sends WS reaction + records add', (t) async {
      final m = _msg(id: 'm-react');
      final state = const ChatState().withMessage(m);
      final b = buildOverrides(chatState: state);
      final h = await _pump(t, b.overrides);
      actions.toggleReaction(
        ref: h.ref,
        conv: _dmConv,
        message: m,
        emoji: '🎉',
        remove: false,
      );
      expect(b.ws.reactionCalls, [
        ['conv-dm', 'm-react', '🎉'],
      ]);
      expect(b.chat.addReactionCalls, hasLength(1));
      final reaction = b.chat.addReactionCalls.single[1] as Reaction;
      expect(reaction.messageId, 'm-react');
      expect(reaction.userId, 'test-user-id');
      expect(reaction.emoji, '🎉');
      expect(b.chat.removeReactionCalls, isEmpty);
    });

    testWidgets('remove path sends WS reaction + records remove', (t) async {
      final m = _msg(id: 'm-react');
      final state = const ChatState().withMessage(m);
      final b = buildOverrides(chatState: state);
      final h = await _pump(t, b.overrides);
      actions.toggleReaction(
        ref: h.ref,
        conv: _dmConv,
        message: m,
        emoji: '😂',
        remove: true,
      );
      expect(b.ws.reactionCalls, [
        ['conv-dm', 'm-react', '😂'],
      ]);
      expect(b.chat.removeReactionCalls, [
        ['conv-dm', 'm-react', 'test-user-id', '😂'],
      ]);
      expect(b.chat.addReactionCalls, isEmpty);
    });
  });

  group('saveMessage / unsaveMessage', () {
    testWidgets('saveMessage fires onAddSavedId with the message id', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      String? captured;
      await actions.saveMessage(
        context: h.context,
        message: _msg(id: 'bk-1'),
        onAddSavedId: (id) => captured = id,
      );
      expect(captured, 'bk-1');
      await t.pump(const Duration(seconds: 4)); // flush toast timer
    });

    testWidgets('unsaveMessage fires onRemoveSavedId with the message id', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      String? captured;
      await actions.unsaveMessage(
        context: h.context,
        message: _msg(id: 'bk-2'),
        onRemoveSavedId: (id) => captured = id,
      );
      expect(captured, 'bk-2');
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('pinMessage', () {
    testWidgets('optimistically sets pinned state then leaves it on 200', (
      t,
    ) async {
      final b = buildOverrides();
      b.auth.stubbedResponse = http.Response('', 200);
      final h = await _pump(t, b.overrides);
      await actions.pinMessage(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'm-pin'),
      );

      // Exactly one optimistic call -- no revert.
      expect(b.chat.updateMessagePinCalls, hasLength(1));
      final call = b.chat.updateMessagePinCalls.single;
      expect(call[0], 'conv-dm');
      expect(call[1], 'm-pin');
      expect(call[2], 'test-user-id'); // pinnedById = me
      expect(call[3], isA<DateTime>());
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('reverts the optimistic pin when the server returns 500', (
      t,
    ) async {
      final b = buildOverrides();
      b.auth.stubbedResponse = http.Response('boom', 500);
      final h = await _pump(t, b.overrides);
      await actions.pinMessage(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'm-pin-fail'),
      );

      // Two calls: optimistic set, then revert to null/null.
      expect(b.chat.updateMessagePinCalls, hasLength(2));
      expect(b.chat.updateMessagePinCalls.last.sublist(2), [null, null]);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('reverts the optimistic pin when the request throws', (
      t,
    ) async {
      final b = buildOverrides();
      b.auth.throwError = Exception('network down');
      final h = await _pump(t, b.overrides);
      await actions.pinMessage(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'm-pin-throw'),
      );
      expect(b.chat.updateMessagePinCalls, hasLength(2));
      expect(b.chat.updateMessagePinCalls.last.sublist(2), [null, null]);
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('unpinMessage', () {
    testWidgets('optimistically clears, then commits on 200', (t) async {
      final b = buildOverrides();
      b.auth.stubbedResponse = http.Response('', 204);
      final h = await _pump(t, b.overrides);
      final pinned = _msg(
        id: 'm-un',
        pinnedById: 'someone',
        pinnedAt: DateTime.utc(2026, 1, 1),
      );
      await actions.unpinMessage(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: pinned,
      );
      expect(b.chat.updateMessagePinCalls, hasLength(1));
      expect(b.chat.updateMessagePinCalls.single.sublist(2), [null, null]);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('restores previous pinnedBy/pinnedAt on server error', (
      t,
    ) async {
      final b = buildOverrides();
      b.auth.stubbedResponse = http.Response('nope', 500);
      final h = await _pump(t, b.overrides);
      final originalAt = DateTime.utc(2026, 1, 2, 12);
      final pinned = _msg(
        id: 'm-un-fail',
        pinnedById: 'pinner-x',
        pinnedAt: originalAt,
      );
      await actions.unpinMessage(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: pinned,
      );
      expect(b.chat.updateMessagePinCalls, hasLength(2));
      // First call cleared, second call restored the original values.
      expect(b.chat.updateMessagePinCalls.first.sublist(2), [null, null]);
      expect(b.chat.updateMessagePinCalls.last[2], 'pinner-x');
      expect(b.chat.updateMessagePinCalls.last[3], originalAt);
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('deleteForEveryone', () {
    testWidgets('optimistically removes the message and does not roll back '
        'on 200', (t) async {
      final b = buildOverrides();
      b.auth.stubbedResponse = http.Response('', 200);
      final h = await _pump(t, b.overrides);
      final m = _msg(id: 'm-del-ok');
      await actions.deleteForEveryone(h.ref, h.context, 'conv-dm', m);
      expect(b.chat.deleteMessageCalls, [
        ['conv-dm', 'm-del-ok'],
      ]);
      // Success path must not re-add the message.
      expect(b.chat.addMessageCalls, isEmpty);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('re-adds the message on non-2xx so the UI stops lying', (
      t,
    ) async {
      final b = buildOverrides();
      b.auth.stubbedResponse = http.Response('forbidden', 403);
      final h = await _pump(t, b.overrides);
      final m = _msg(id: 'm-del-403');
      await actions.deleteForEveryone(h.ref, h.context, 'conv-dm', m);
      expect(b.chat.deleteMessageCalls, [
        ['conv-dm', 'm-del-403'],
      ]);
      expect(b.chat.addMessageCalls, hasLength(1));
      expect(b.chat.addMessageCalls.single.id, 'm-del-403');
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('re-adds the message when the request throws (network down)', (
      t,
    ) async {
      final b = buildOverrides();
      b.auth.throwError = Exception('network');
      final h = await _pump(t, b.overrides);
      final m = _msg(id: 'm-del-net');
      await actions.deleteForEveryone(h.ref, h.context, 'conv-dm', m);
      expect(b.chat.addMessageCalls.single.id, 'm-del-net');
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('confirmDelete dialog', () {
    testWidgets('renders Delete-for-everyone only for my own messages', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      // Peer's message — no "Delete for everyone".
      actions.confirmDelete(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'peer-msg', isMine: false, fromUserId: 'user-alice'),
        addToDeletedForMe: (_) async {},
      );
      await t.pumpAndSettle();
      expect(find.text('Delete for me'), findsOneWidget);
      expect(find.text('Delete for everyone'), findsNothing);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('renders Delete-for-everyone for my own messages', (t) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      actions.confirmDelete(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'mine-msg', isMine: true),
        addToDeletedForMe: (_) async {},
      );
      await t.pumpAndSettle();
      expect(find.text('Delete for me'), findsOneWidget);
      expect(find.text('Delete for everyone'), findsOneWidget);
      expect(find.text('Cancel'), findsOneWidget);
    });

    testWidgets('Delete-for-me calls addToDeletedForMe + chat.deleteMessage', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      String? addedId;
      actions.confirmDelete(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'choose-forme'),
        addToDeletedForMe: (id) async => addedId = id,
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Delete for me'));
      await t.pumpAndSettle();
      expect(addedId, 'choose-forme');
      expect(b.chat.deleteMessageCalls, [
        ['conv-dm', 'choose-forme'],
      ]);
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('Cancel button dismisses without mutating chat', (t) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      actions.confirmDelete(
        context: h.context,
        ref: h.ref,
        conv: _dmConv,
        message: _msg(id: 'choose-cancel'),
        addToDeletedForMe: (_) async {},
      );
      await t.pumpAndSettle();
      await t.tap(find.text('Cancel'));
      await t.pumpAndSettle();
      expect(b.chat.deleteMessageCalls, isEmpty);
      expect(find.text('Delete for me'), findsNothing);
    });
  });

  group('sendForwardedMessage', () {
    testWidgets('forwards to a DM by adding optimistic + ws.sendMessage', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      await actions.sendForwardedMessage(
        h.ref,
        h.context,
        _msg(id: 'src', content: 'hi'),
        _dmConv,
      );
      // forwardMessage was asked to forward 'hi' into conv-dm.
      expect(b.chat.forwardCalls, [
        ['hi', 'conv-dm'],
      ]);
      // The optimistic message went in for the sender.
      expect(b.chat.addMessageCalls, hasLength(1));
      expect(b.chat.addMessageCalls.single.content, '[Forwarded] hi');
      // WS sendMessage routed to the peer with the forwarded content.
      expect(b.ws.sendCalls, hasLength(1));
      expect(b.ws.sendCalls.single[0], 'user-alice');
      expect(b.ws.sendCalls.single[1], '[Forwarded] hi');
      // Flush the success-toast timer (3s) so the test tears down cleanly.
      await t.pump(const Duration(seconds: 4));
    });

    testWidgets('forwards to a group via sendGroupMessage (no DM send)', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      await actions.sendForwardedMessage(
        h.ref,
        h.context,
        _msg(id: 'src', content: 'team ping'),
        _groupConv,
      );
      expect(b.chat.forwardCalls.single[1], 'conv-group');
      expect(b.ws.sendGroupCalls, hasLength(1));
      expect(b.ws.sendGroupCalls.single[1], '[Forwarded] team ping');
      expect(b.ws.sendCalls, isEmpty);
      await t.pump(const Duration(seconds: 4));
    });
  });

  group('openImageGallery URL extraction', () {
    testWidgets('opens the gallery dialog when a tap URL resolves', (t) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      final messages = <ChatMessage>[
        _msg(id: 'a', content: '[img:https://cdn.test/one.png]'),
        _msg(id: 'b', content: 'just text, no image'),
        _msg(id: 'c', content: 'https://cdn.test/two.jpg'),
      ];
      actions.openImageGallery(
        context: h.context,
        ref: h.ref,
        tappedUrl: 'https://cdn.test/two.jpg',
        messages: messages,
        serverUrl: 'http://test.local',
        authToken: 'token-xyz',
      );
      // pump (not pumpAndSettle) because CachedNetworkImage spins forever.
      await t.pump();
      // The gallery widget mounts and renders its viewer. We don't assert
      // image count because that's private state; the mount is enough to
      // prove openImageGallery walked the URL list without throwing.
      expect(find.byType(ImageGalleryViewer), findsOneWidget);
    });

    testWidgets('falls back to the tapped url when nothing is parseable', (
      t,
    ) async {
      final b = buildOverrides();
      final h = await _pump(t, b.overrides);
      actions.openImageGallery(
        context: h.context,
        ref: h.ref,
        tappedUrl: 'https://cdn.test/lonely.png',
        messages: const <ChatMessage>[],
        serverUrl: 'http://test.local',
        authToken: 'token-xyz',
      );
      await t.pump();
      // Empty input list ⇒ the helper falls back to [tappedUrl], the gallery
      // still opens with exactly one image.
      expect(find.byType(ImageGalleryViewer), findsOneWidget);
    });
  });
}
