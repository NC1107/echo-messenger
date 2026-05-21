// Tests for the freshly-split `chat_input_bar/parts/*.dart` mixins.
//
// These tests exercise the **library-private extensions** via their
// user-visible effects rather than calling private members directly:
// they type into the field, press keys, drive the GlobalKey<ChatInputBarState>
// API, and assert against recorded stub calls. Paired with the existing
// `chat_input_bar_test.dart` (rendering + edit-mode chrome) they cover the
// eight new part files.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_riverpod/flutter_riverpod.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:echo_app/src/models/chat_message.dart';
import 'package:echo_app/src/models/conversation.dart';
import 'package:echo_app/src/providers/chat_provider.dart';
import 'package:echo_app/src/providers/voice_settings_provider.dart';
import 'package:echo_app/src/providers/websocket_provider.dart'
    show WebSocketNotifier, WebSocketState, websocketProvider;
import 'package:echo_app/src/services/crypto_service.dart';
import 'package:echo_app/src/services/group_crypto_service.dart';
import 'package:echo_app/src/widgets/chat_input_bar.dart';

import '../helpers/mock_providers.dart';
import '../helpers/pump_app.dart';

// ---------------------------------------------------------------------------
// Recorder fakes
// ---------------------------------------------------------------------------

/// A chat notifier that records `addOptimistic` / `editMessage` /
/// `clearReplyTo` calls so tests can assert against them without
/// poking provider internals.
class _StubChat extends Chat {
  _StubChat([this._initial = const ChatState()]);
  final ChatState _initial;

  /// Append-only log of (peerUserId, content, conversationId) per
  /// `addOptimistic` call. The send pipeline funnels through this method
  /// before WS dispatch, so it's the cleanest assertion point.
  final List<List<String?>> addOptimisticCalls = [];

  /// Append-only log of (conversationId, messageId, newContent) per
  /// `editMessage` call from the edit-mode submit path.
  final List<List<String>> editMessageCalls = [];

  int clearReplyToCalls = 0;

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
  void clearReplyTo() {
    clearReplyToCalls++;
    // Do NOT mutate state here — `didUpdateWidget` calls this during a
    // build pass and Riverpod forbids in-build state changes. The
    // original Chat impl publishes via state= but tests don't need the
    // state mutation to assert behaviour.
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
    addOptimisticCalls.add([peerUserId, content, conversationId]);
    // Skip the real Timer-based timeout machinery — tests would leak.
  }

  @override
  void editMessage(
    String conversationId,
    String messageId,
    String newContent, {
    String? editedAt,
  }) {
    editMessageCalls.add([conversationId, messageId, newContent]);
  }
}

/// A WebSocket notifier that records `sendMessage` / `sendGroupMessage`
/// calls and stubs them so they never touch real crypto or sockets.
class _StubWs extends WebSocketNotifier {
  _StubWs();

  /// (toUserId, content, conversationId) per `sendMessage`.
  final List<List<String?>> sendCalls = [];

  /// (conversationId, content) per `sendGroupMessage`.
  final List<List<String?>> sendGroupCalls = [];

  /// Number of typing-indicator broadcasts.
  int typingCalls = 0;

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
    sendCalls.add([toUserId, content, conversationId]);
  }

  @override
  Future<void> sendGroupMessage(
    String conversationId,
    String content, {
    String? channelId,
    String? replyToId,
  }) async {
    sendGroupCalls.add([conversationId, content]);
  }

  @override
  void sendTyping(String conversationId, {String? channelId}) {
    typingCalls++;
  }
}

class _FakeVoiceSettings extends VoiceSettings {
  @override
  VoiceSettingsState build() => const VoiceSettingsState();
}

// ---------------------------------------------------------------------------
// Per-test override builder
// ---------------------------------------------------------------------------

({List<Override> overrides, _StubChat chat, _StubWs ws}) buildOverrides({
  ChatState chatState = const ChatState(),
}) {
  final chat = _StubChat(chatState);
  final ws = _StubWs();
  return (
    overrides: [
      ...standardOverrides(),
      chatProvider.overrideWith(() => chat),
      websocketProvider.overrideWith(() => ws),
      voiceSettingsProvider.overrideWith(_FakeVoiceSettings.new),
    ],
    chat: chat,
    ws: ws,
  );
}

// ---------------------------------------------------------------------------
// Fixtures
// ---------------------------------------------------------------------------

const _dmEncrypted = Conversation(
  id: 'conv-dm-enc',
  isGroup: false,
  isEncrypted: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
  ],
);

/// Non-encrypted DM. `_submitEdit` short-circuits on encrypted convs so
/// the edit-mode happy path needs `isEncrypted: false`.
const _dmPlain = Conversation(
  id: 'conv-dm-plain',
  isGroup: false,
  isEncrypted: false,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-bob', username: 'bob'),
  ],
);

const _group = Conversation(
  id: 'conv-group',
  name: 'Dev Team',
  isGroup: true,
  members: [
    ConversationMember(userId: 'test-user-id', username: 'testuser'),
    ConversationMember(userId: 'user-alice', username: 'alice'),
    ConversationMember(userId: 'user-bob', username: 'bob'),
  ],
);

/// Drives Enter on the focused TextField. Wrapper so tests stay readable.
Future<void> _pressEnter(WidgetTester tester) async {
  await tester.tap(find.byType(TextField));
  await tester.pump();
  await tester.sendKeyEvent(LogicalKeyboardKey.enter);
  await tester.pump();
}

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
  });

  // -------------------------------------------------------------------------
  // send_handling.dart
  // -------------------------------------------------------------------------
  group('send_handling part', () {
    testWidgets('Enter sends a text DM via WS sendMessage + clears field', (
      tester,
    ) async {
      final ctx = buildOverrides();
      var onSentCalls = 0;
      await tester.pumpApp(
        ChatInputBar(
          conversation: _dmEncrypted,
          onMessageSent: () => onSentCalls++,
        ),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'hello world');
      await _pressEnter(tester);
      // Drain the async _doSend.
      await tester.pump();

      expect(ctx.chat.addOptimisticCalls.length, 1);
      // (peerUserId, content, conversationId)
      expect(ctx.chat.addOptimisticCalls.single[0], 'user-alice');
      expect(ctx.chat.addOptimisticCalls.single[1], 'hello world');
      expect(ctx.chat.addOptimisticCalls.single[2], 'conv-dm-enc');

      expect(ctx.ws.sendCalls.length, 1);
      expect(ctx.ws.sendCalls.single[0], 'user-alice');
      expect(ctx.ws.sendCalls.single[1], 'hello world');

      // Field cleared so the next message starts fresh.
      final field = tester.widget<TextField>(find.byType(TextField));
      expect(field.controller!.text, isEmpty);
      // onMessageSent callback fires.
      expect(onSentCalls, 1);
    });

    testWidgets('Shift+Enter inserts a newline and does NOT send', (
      tester,
    ) async {
      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'line1');
      await tester.tap(find.byType(TextField));
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pump();

      expect(ctx.chat.addOptimisticCalls, isEmpty);
      expect(ctx.ws.sendCalls, isEmpty);
    });

    testWidgets('sending in a group routes to sendGroupMessage (not '
        'sendMessage)', (tester) async {
      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _group, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'team announcement');
      await _pressEnter(tester);
      await tester.pump();

      expect(ctx.ws.sendGroupCalls.length, 1);
      expect(ctx.ws.sendGroupCalls.single[0], 'conv-group');
      expect(ctx.ws.sendGroupCalls.single[1], 'team announcement');
      // The 1:1 path MUST NOT run for a group.
      expect(ctx.ws.sendCalls, isEmpty);
    });

    testWidgets('whitespace-only message does not send', (tester) async {
      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), '   ');
      await _pressEnter(tester);

      expect(ctx.chat.addOptimisticCalls, isEmpty);
      expect(ctx.ws.sendCalls, isEmpty);
    });

    testWidgets('typing fires WS sendTyping in compose mode but NOT in edit '
        'mode', (tester) async {
      final ctx = buildOverrides();
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmEncrypted,
          onMessageSent: () {},
        ),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'is alice typing?');
      await tester.pump();
      expect(
        ctx.ws.typingCalls,
        greaterThanOrEqualTo(1),
        reason: '_onInputChanged must broadcast typing while composing',
      );

      // Enter edit mode and confirm typing is NOT broadcast.
      const editMsg = ChatMessage(
        id: 'm1',
        fromUserId: 'test-user-id',
        fromUsername: 'testuser',
        conversationId: 'conv-dm-enc',
        content: 'old',
        timestamp: '2026-01-15T10:00:00Z',
        isMine: true,
      );
      key.currentState!.enterEditMode(editMsg);
      await tester.pump();

      final before = ctx.ws.typingCalls;
      await tester.enterText(find.byType(TextField), 'editing now');
      await tester.pump();
      expect(
        ctx.ws.typingCalls,
        before,
        reason: 'edit mode must NOT broadcast typing (#582 behaviour)',
      );
    });
  });

  // -------------------------------------------------------------------------
  // draft_persistence.dart
  // -------------------------------------------------------------------------
  group('draft_persistence part', () {
    testWidgets('seeded draft is restored into the field on first mount', (
      tester,
    ) async {
      // Pre-seed the SharedPreferences draft key for this conversation.
      // _loadDraft reads it in initState.
      SharedPreferences.setMockInitialValues(<String, Object>{
        'chat_draft_${_dmEncrypted.id}': 'restored draft body',
      });

      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      // Two pumps: one to mount, one to flush the awaited prefs read in
      // _loadDraft so the controller text + setState propagate.
      await tester.pump();
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      expect(
        field.controller!.text,
        'restored draft body',
        reason: 'draft must be restored from SharedPreferences on mount',
      );
    });

    testWidgets(
      'sending a message clears the persisted draft so the next mount '
      'is empty',
      (tester) async {
        final ctx = buildOverrides();
        await tester.pumpApp(
          ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
          overrides: ctx.overrides,
        );
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'will send');
        await _pressEnter(tester);
        await tester.pump();

        // Check the prefs key directly — easier than remounting and far
        // less prone to dispose-order issues.
        final prefs = await SharedPreferences.getInstance();
        expect(
          prefs.getString('chat_draft_${_dmEncrypted.id}'),
          isNull,
          reason: '_saveDraftImmediate(\'\') must remove the key',
        );
      },
    );

    testWidgets(
      'typing toggles _isTextEmpty so the send icon swaps from mic to send',
      (tester) async {
        // Hits the `_onTextChanged` setState branch in draft_persistence.dart.
        final ctx = buildOverrides();
        await tester.pumpApp(
          ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
          overrides: ctx.overrides,
        );
        await tester.pump();

        expect(find.byIcon(Icons.mic_outlined), findsOneWidget);

        await tester.enterText(find.byType(TextField), 'x');
        // SendButton uses AnimatedSwitcher between mic / send-arrow / check;
        // pumpAndSettle drains the cross-fade so we don't false-positive
        // on the outgoing mic glyph.
        await tester.pumpAndSettle();
        expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
        expect(find.byIcon(Icons.mic_outlined), findsNothing);
      },
    );
  });

  // -------------------------------------------------------------------------
  // edit_mode.dart
  // -------------------------------------------------------------------------
  group('edit_mode part', () {
    const editMsgPlain = ChatMessage(
      id: 'msg-plain-1',
      fromUserId: 'test-user-id',
      fromUsername: 'testuser',
      conversationId: 'conv-dm-plain',
      content: 'Original content',
      timestamp: '2026-01-15T10:00:00Z',
      isMine: true,
    );

    testWidgets('submitting an edit on a plaintext conv calls editMessage (NOT '
        'sendMessage)', (tester) async {
      final ctx = buildOverrides();
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(key: key, conversation: _dmPlain, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();

      key.currentState!.enterEditMode(editMsgPlain);
      await tester.pump();

      await tester.enterText(find.byType(TextField), 'edited content');
      await tester.pump();
      // Press Enter on the focused field — _handleEnterSubmit routes
      // to _submitEdit in edit mode.
      await _pressEnter(tester);

      expect(
        ctx.chat.editMessageCalls.length,
        1,
        reason: '_submitEdit must call chatProvider.editMessage',
      );
      expect(ctx.chat.editMessageCalls.single[0], 'conv-dm-plain');
      expect(ctx.chat.editMessageCalls.single[1], 'msg-plain-1');
      expect(ctx.chat.editMessageCalls.single[2], 'edited content');

      // The text-message send path MUST NOT be invoked from edit submit.
      expect(ctx.chat.addOptimisticCalls, isEmpty);
      expect(ctx.ws.sendCalls, isEmpty);
      // Drain the 600ms draft-save Timer + the 2.5s toast auto-hide
      // Timer before tear-down so the framework's pending-timer guard
      // doesn't fail the test.
      await tester.pump(const Duration(milliseconds: 700));
      await tester.pump(const Duration(seconds: 3));
    });

    testWidgets(
      'submitting an edit on an encrypted conv refuses and exits edit '
      'mode (#582)',
      (tester) async {
        final ctx = buildOverrides();
        final key = GlobalKey<ChatInputBarState>();
        await tester.pumpApp(
          ChatInputBar(
            key: key,
            conversation: _dmEncrypted,
            onMessageSent: () {},
          ),
          overrides: ctx.overrides,
        );
        await tester.pump();

        const encMsg = ChatMessage(
          id: 'enc-1',
          fromUserId: 'test-user-id',
          fromUsername: 'testuser',
          conversationId: 'conv-dm-enc',
          content: 'secret',
          timestamp: '2026-01-15T10:00:00Z',
          isMine: true,
        );
        key.currentState!.enterEditMode(encMsg);
        await tester.pump();

        await tester.enterText(find.byType(TextField), 'attempted edit');
        await _pressEnter(tester);
        await tester.pump();

        // No edit was performed and the UI returned to compose mode.
        expect(ctx.chat.editMessageCalls, isEmpty);
        expect(find.byIcon(Icons.check_rounded), findsNothing);
        // Drain the 600ms draft-save Timer + the 2.5s toast auto-hide Timer.
        await tester.pump(const Duration(milliseconds: 700));
        await tester.pump(const Duration(seconds: 3));
      },
    );
  });

  // -------------------------------------------------------------------------
  // media_picker.dart
  // -------------------------------------------------------------------------
  group('media_picker part', () {
    testWidgets(
      'tapping emoji toggle flips showMediaPicker and swaps the icon',
      (tester) async {
        final ctx = buildOverrides();
        final key = GlobalKey<ChatInputBarState>();
        await tester.pumpApp(
          ChatInputBar(
            key: key,
            conversation: _dmEncrypted,
            onMessageSent: () {},
          ),
          overrides: ctx.overrides,
        );
        await tester.pump();

        expect(key.currentState!.showMediaPicker, isFalse);
        expect(
          find.byIcon(Icons.sentiment_satisfied_alt_outlined),
          findsOneWidget,
        );

        await tester.tap(
          find.byIcon(Icons.sentiment_satisfied_alt_outlined),
          warnIfMissed: false,
        );
        await tester.pump();

        expect(key.currentState!.showMediaPicker, isTrue);
        // Icon flips to keyboard when picker is open.
        expect(find.byIcon(Icons.keyboard_outlined), findsOneWidget);
        expect(
          find.byIcon(Icons.sentiment_satisfied_alt_outlined),
          findsNothing,
        );

        await tester.tap(
          find.byIcon(Icons.keyboard_outlined),
          warnIfMissed: false,
        );
        await tester.pump();
        expect(key.currentState!.showMediaPicker, isFalse);
      },
    );

    testWidgets('onMediaPickerChanged callback fires on toggle', (
      tester,
    ) async {
      final ctx = buildOverrides();
      var changedCalls = 0;
      await tester.pumpApp(
        ChatInputBar(
          conversation: _dmEncrypted,
          onMessageSent: () {},
          onMediaPickerChanged: () => changedCalls++,
        ),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.tap(
        find.byIcon(Icons.sentiment_satisfied_alt_outlined),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(changedCalls, 1);

      await tester.tap(
        find.byIcon(Icons.keyboard_outlined),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(changedCalls, 2);
    });

    testWidgets('emoji toggle is rendered alongside the input in compose '
        'mode (sanity check)', (tester) async {
      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _dmPlain, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();
      expect(
        find.byIcon(Icons.sentiment_satisfied_alt_outlined),
        findsOneWidget,
      );
      // The picker panel itself is not rendered inside the input bar —
      // ChatPanel composes it. So we only check the toggle entrypoint.
      expect(find.byIcon(Icons.keyboard_outlined), findsNothing);
    });
  });

  // -------------------------------------------------------------------------
  // build_helpers.dart
  // -------------------------------------------------------------------------
  group('build_helpers part', () {
    testWidgets('send button state tracks text presence and edit mode (mic → '
        'arrow → check)', (tester) async {
      final ctx = buildOverrides();
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmEncrypted,
          onMessageSent: () {},
        ),
        overrides: ctx.overrides,
      );
      await tester.pump();

      // Empty + compose: mic shown.
      expect(find.byIcon(Icons.mic_outlined), findsOneWidget);

      // Type text: arrow appears (cross-fade settles via pumpAndSettle).
      await tester.enterText(find.byType(TextField), 'x');
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      expect(find.byIcon(Icons.mic_outlined), findsNothing);

      // Enter edit mode: check icon replaces send-arrow.
      const editMsg = ChatMessage(
        id: 'b-1',
        fromUserId: 'test-user-id',
        fromUsername: 'testuser',
        conversationId: 'conv-dm-enc',
        content: 'old',
        timestamp: '2026-01-15T10:00:00Z',
        isMine: true,
      );
      key.currentState!.enterEditMode(editMsg);
      await tester.pumpAndSettle();
      expect(find.byIcon(Icons.check_rounded), findsOneWidget);
      expect(find.byIcon(Icons.arrow_upward_rounded), findsNothing);
    });

    testWidgets(
      'preFillText pre-fills the field and the send button becomes enabled',
      (tester) async {
        final ctx = buildOverrides();
        final key = GlobalKey<ChatInputBarState>();
        await tester.pumpApp(
          ChatInputBar(
            key: key,
            conversation: _dmEncrypted,
            onMessageSent: () {},
          ),
          overrides: ctx.overrides,
        );
        await tester.pump();

        key.currentState!.preFillText('hey there');
        await tester.pump();

        final field = tester.widget<TextField>(find.byType(TextField));
        expect(field.controller!.text, 'hey there');
        expect(find.byIcon(Icons.arrow_upward_rounded), findsOneWidget);
      },
    );
  });

  // -------------------------------------------------------------------------
  // keyboard_handling.dart
  // -------------------------------------------------------------------------
  group('keyboard_handling part', () {
    testWidgets('Escape with no modals open is a no-op (does not crash)', (
      tester,
    ) async {
      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(tester.takeException(), isNull);
    });

    testWidgets('Escape closes the media picker before any other modal', (
      tester,
    ) async {
      // Priority chain in `_handleEscapeKey`:
      //   mention > inline > media > attachments > edit > reply.
      final ctx = buildOverrides();
      final key = GlobalKey<ChatInputBarState>();
      await tester.pumpApp(
        ChatInputBar(
          key: key,
          conversation: _dmEncrypted,
          onMessageSent: () {},
        ),
        overrides: ctx.overrides,
      );
      await tester.pump();

      await tester.tap(
        find.byIcon(Icons.sentiment_satisfied_alt_outlined),
        warnIfMissed: false,
      );
      await tester.pump();
      expect(key.currentState!.showMediaPicker, isTrue);

      await tester.tap(find.byType(TextField));
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();

      expect(key.currentState!.showMediaPicker, isFalse);
    });

    testWidgets('Ctrl+B wraps the current selection in markdown bold markers', (
      tester,
    ) async {
      // Hits _applyMarkdownWrap via _handleModifierShortcut in
      // keyboard_handling.dart — selection branch.
      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();

      final field = tester.widget<TextField>(find.byType(TextField));
      final controller = field.controller!;
      await tester.tap(find.byType(TextField));
      await tester.pump();
      controller.text = 'hello world';
      controller.selection = const TextSelection(
        baseOffset: 0,
        extentOffset: 5,
      );
      await tester.pump();

      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      await tester.pump();

      expect(
        controller.text,
        '**hello** world',
        reason: 'Ctrl+B must wrap selection with **…**',
      );
    });

    testWidgets(
      'Ctrl+I wraps the cursor position in italic markers when nothing is '
      'selected',
      (tester) async {
        // Hits the `sel.isCollapsed` branch of _applyMarkdownWrap.
        final ctx = buildOverrides();
        await tester.pumpApp(
          ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
          overrides: ctx.overrides,
        );
        await tester.pump();

        final field = tester.widget<TextField>(find.byType(TextField));
        final controller = field.controller!;
        await tester.tap(find.byType(TextField));
        await tester.pump();
        controller.text = 'abc';
        controller.selection = const TextSelection.collapsed(offset: 3);
        await tester.pump();

        await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
        await tester.sendKeyEvent(LogicalKeyboardKey.keyI);
        await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
        await tester.pump();

        expect(controller.text, 'abc**');
        // Caret should land between the markers — offset 4 of "abc**".
        expect(controller.selection.baseOffset, 4);
      },
    );
  });

  // -------------------------------------------------------------------------
  // attachments.dart
  // -------------------------------------------------------------------------
  // Note: `attachments.dart`'s richer flows (file_picker, clipboard_image,
  // upload-with-auth-retry, annotate) all require real plugin / disk IO and
  // are exercised by the existing `chat_input_bar_test.dart` +
  // `chat_input_bar_attachments_test.dart` files. We don't duplicate that
  // here.

  // -------------------------------------------------------------------------
  // recording_handling.dart  (smoke — `record` plugin needs native platform)
  // -------------------------------------------------------------------------
  group('recording_handling part (smoke)', () {
    testWidgets('mic button renders when the composer is empty (entrypoint to '
        '_startRecording)', (tester) async {
      // Just smoke-tests that the wiring is present. Tapping the mic
      // would invoke the `record` plugin which is platform-bound.
      final ctx = buildOverrides();
      await tester.pumpApp(
        ChatInputBar(conversation: _dmEncrypted, onMessageSent: () {}),
        overrides: ctx.overrides,
      );
      await tester.pump();

      expect(find.byIcon(Icons.mic_outlined), findsOneWidget);
    });
  });
}
